"""Unit tests for server/household/grocy_import.py against a fake Grocy (a local
HTTP server that records every call). Synthetic data only: no household data here.

Run:  python3 -m unittest -v tests/test_grocy_import.py   (standard library only)
"""
import datetime as dt
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "household"))
import grocy_import as gi  # noqa: E402

KEY = "test-key-0123456789"


class FakeGrocy:
    """Holds objects per entity and logs (method, path, body, key header)."""

    def __init__(self, users=(("alex", 1), ("sam", 2))):
        self.objects = {"users": [{"id": i, "username": u} for u, i in users]}
        self.values = {}  # (entity ref, object id) -> {field: value}
        self.calls = []
        self.next_id = 100
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                fake.calls.append(("GET", self.path, None, self.headers.get("GROCY-API-KEY")))
                path = self.path[len("/api"):]
                if path == "/users":
                    return self._send(200, fake.objects["users"])
                if path.startswith("/objects/"):
                    return self._send(200, fake.objects.get(path.split("/")[2], []))
                if path.startswith("/userfields/"):
                    _, _, ref, oid = path.split("/")
                    return self._send(200, fake.values.get((ref, int(oid)), {}))
                self._send(404, {"error_message": "no route"})

            def do_PUT(self):
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"null")
                fake.calls.append(("PUT", self.path, body, self.headers.get("GROCY-API-KEY")))
                path = self.path[len("/api"):]
                if path.startswith("/userfields/"):
                    _, _, ref, oid = path.split("/")
                    fake.values[(ref, int(oid))] = body
                    self.send_response(204)
                    self.end_headers()
                    return
                self._send(404, {"error_message": "no route"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"null")
                fake.calls.append(("POST", self.path, body, self.headers.get("GROCY-API-KEY")))
                path = self.path[len("/api"):]
                if path.startswith("/objects/"):
                    entity = path.split("/")[2]
                    fake.next_id += 1
                    fake.objects.setdefault(entity, []).append(dict(body, id=fake.next_id))
                    return self._send(200, {"created_object_id": fake.next_id})
                if path.startswith("/chores/") and path.endswith("/execute"):
                    return self._send(200, {"id": 1})
                self._send(404, {"error_message": "no route"})

        self.server = HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def posts(self, prefix=""):
        return [c for c in self.calls if c[0] == "POST" and c[1].startswith("/api" + prefix)]

    def puts(self):
        return [c for c in self.calls if c[0] == "PUT"]


def write_csvs(d, chores=None, products=None):
    if chores is not None:
        with open(os.path.join(d, "chores.csv"), "w", newline="") as f:
            f.write("name,cadence,last_done,assignee,description\n" + chores)
    if products is not None:
        with open(os.path.join(d, "products.csv"), "w", newline="") as f:
            f.write("name,stores,location,description\n" + products)


CHORES = ("Test task A,monthly,2026-03-17,,\n"
          "Test task B,every 2 weeks,2026-03-02,alex,\n"
          "Test task C,yearly,2026-10-01,rotate,\n"
          "Test task D,manual,,,\n")
PRODUCTS = ("Widget,Store One + Store Two,,a note\n"
            "Gadget,Store Two,Shelf,\n")


KINDS = ("person,kind,provider,how_to_book,notes,match_words\n"
         "Alex,dentist,Test Dental,phone 555-0100,,\"dentist, dental\"\n"
         "Sam,therapy,,portal,arrive early,\n")


class AppointmentKinds(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGrocy()
        self.dir = tempfile.TemporaryDirectory()
        with open(os.path.join(self.dir.name, "appointment_kinds.csv"), "w", newline="") as f:
            f.write(KINDS)

    def tearDown(self):
        self.fake.close()
        self.dir.cleanup()

    def run_it(self, apply):
        out = io.StringIO()
        n = gi.run(self.fake.url, KEY, self.dir.name, apply, out=out)
        return n, out.getvalue()

    def test_dry_run_writes_nothing(self):
        n, out = self.run_it(False)
        self.assertEqual(n, 0)
        self.assertEqual(self.fake.posts() + self.fake.puts(), [])
        self.assertIn("create  appointment_kinds: Alex dentist", out)
        self.assertIn("2 appointment kinds read", out)

    def test_apply_creates_entity_fields_and_objects_then_is_idempotent(self):
        n, _ = self.run_it(True)
        ents = self.fake.objects["userentities"]
        self.assertEqual([e["name"] for e in ents], ["appointment_kinds"])
        fields = self.fake.objects["userfields"]
        self.assertEqual({f["entity"] for f in fields}, {"userentity-appointment_kinds"})
        self.assertEqual([f["name"] for f in fields], list(gi.KINDS_FIELDS))
        objs = self.fake.objects["userobjects"]
        self.assertEqual({o["userentity_id"] for o in objs}, {ents[0]["id"]})
        vals = sorted(self.fake.values.values(), key=lambda v: v["person"])
        self.assertEqual(vals[0], {"person": "Alex", "kind": "dentist", "provider": "Test Dental",
                                   "how_to_book": "phone 555-0100", "notes": "", "match_words": "dentist, dental"})
        self.assertEqual(vals[1]["notes"], "arrive early")
        self.assertEqual(n, 1 + len(gi.KINDS_FIELDS) + 2 * 2)
        n2, out2 = self.run_it(True)
        self.assertEqual(n2, 0, out2)
        self.assertIn("keep    appointment_kinds: Sam therapy", out2)

    def test_existing_entity_and_a_new_row(self):
        self.run_it(True)
        with open(os.path.join(self.dir.name, "appointment_kinds.csv"), "a", newline="") as f:
            f.write("ALEX,Dentist,,,,\nSam,eye doctor,,,,\n")
        n, out = self.run_it(True)
        self.assertEqual(n, 2, out)  # one object + its values; the ALEX/Dentist row matches case-insensitively
        self.assertIn("create  appointment_kinds: Sam eye doctor", out)

    def test_missing_person_or_kind_is_refused(self):
        with open(os.path.join(self.dir.name, "appointment_kinds.csv"), "a", newline="") as f:
            f.write(",dentist,,,,\n")
        with self.assertRaisesRegex(gi.InputError, "line 4: missing person"):
            self.run_it(False)

    def test_fields_match_what_the_health_tool_reads(self):
        sys.modules.setdefault("pydantic", __import__("types").ModuleType("pydantic"))
        p = sys.modules["pydantic"]
        if not hasattr(p, "BaseModel"):
            p.BaseModel = type("BaseModel", (), {"__init__": lambda self, **kw: None})
            p.Field = lambda default=None, **_: default
        import openwebui_health_tool as ht
        self.assertEqual(tuple(gi.KINDS_FIELDS), ht.FIELDS)
        self.assertEqual(gi.KINDS_ENTITY, ht.ENTITY)


class Cadence(unittest.TestCase):
    def test_table(self):
        cases = {
            "weekly": ("weekly", 1), "every 2 weeks": ("weekly", 2), "biweekly": ("weekly", 2),
            "monthly": ("monthly", 1), "quarterly": ("monthly", 3), "every 6 months": ("monthly", 6),
            "yearly": ("yearly", 1), "every 2 years": ("yearly", 2),
            "adaptive": ("adaptive", 1), "manual": ("manually", 1), "": ("manually", 1),
            " Monthly ": ("monthly", 1),
        }
        for text, want in cases.items():
            with self.subTest(text=text):
                self.assertEqual(gi.parse_cadence(text), want)

    def test_unknown_and_zero_are_refused(self):
        for bad in ("sometimes", "every 0 weeks", "every two weeks"):
            with self.subTest(bad=bad), self.assertRaises(gi.InputError):
                gi.parse_cadence(bad)


class Payloads(unittest.TestCase):
    def test_monthly_uses_day_of_last_done(self):
        p, last = gi.chore_payload({"name": "x", "cadence": "every 3 months", "last_done": "2026-08-10"}, {})
        self.assertEqual((p["period_type"], p["period_interval"], p["period_days"]), ("monthly", 3, 10))
        self.assertEqual(last, dt.date(2026, 8, 10))

    def test_monthly_day_capped_at_28(self):
        p, _ = gi.chore_payload({"name": "x", "cadence": "monthly", "last_done": "2026-01-31"}, {})
        self.assertEqual(p["period_days"], 28)

    def test_weekly_uses_weekday_of_last_done(self):
        p, _ = gi.chore_payload({"name": "x", "cadence": "weekly", "last_done": "2026-11-09"}, {})  # a Monday
        self.assertEqual((p["period_type"], p["period_config"]), ("weekly", "monday"))

    def test_yearly_anchors_start_date(self):
        p, _ = gi.chore_payload({"name": "x", "cadence": "yearly", "last_done": "2026-10-26"}, {})
        self.assertEqual(p["start_date"], "2026-10-26 00:00:00")

    def test_assignees(self):
        users = {"alex": 1, "sam": 2}
        p, _ = gi.chore_payload({"name": "x", "cadence": "weekly", "assignee": "Sam"}, users)
        self.assertEqual((p["assignment_type"], p["assignment_config"]), ("in-alphabetical-order", "2"))
        p, _ = gi.chore_payload({"name": "x", "cadence": "weekly", "assignee": "rotate"}, users)
        self.assertEqual((p["assignment_type"], p["assignment_config"]), ("who-least-did-first", "1,2"))
        with self.assertRaises(gi.InputError):
            gi.chore_payload({"name": "x", "cadence": "weekly", "assignee": "nobody"}, users)

    def test_bad_date_refused(self):
        with self.assertRaises(gi.InputError):
            gi.chore_payload({"name": "x", "cadence": "weekly", "last_done": "11/09/2026"}, {})

    def test_product_first_store_others_in_description(self):
        p = gi.product_payload({"name": "Widget", "stores": "Store One + Store Two", "description": "a note"},
                               {"store one": 7, "store two": 8}, {"pantry": 3}, 5)
        self.assertEqual(p["shopping_location_id"], 7)
        self.assertEqual(p["location_id"], 3)
        self.assertEqual((p["qu_id_purchase"], p["qu_id_stock"]), (5, 5))
        self.assertEqual(p["description"], "a note\nAlso at: Store Two")


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGrocy()
        self.tmp = tempfile.TemporaryDirectory()
        write_csvs(self.tmp.name, CHORES, PRODUCTS)

    def tearDown(self):
        self.fake.close()
        self.tmp.cleanup()

    def run_import(self, apply):
        out = io.StringIO()
        writes = gi.run(self.fake.url, KEY, self.tmp.name, apply, out=out)
        return writes, out.getvalue()

    def test_dry_run_writes_nothing(self):
        writes, out = self.run_import(apply=False)
        self.assertEqual(writes, 0)
        self.assertEqual(self.fake.posts(), [])
        self.assertIn("DRY RUN", out)
        self.assertIn("create  chores: Test task A", out)

    def test_apply_creates_everything_once(self):
        writes, _ = self.run_import(apply=True)
        ents = sorted(c[1].split("/")[3] for c in self.fake.posts("/objects/"))
        self.assertEqual(ents.count("chores"), 4)
        self.assertEqual(ents.count("products"), 2)
        self.assertEqual(ents.count("shopping_locations"), 2)
        self.assertEqual(ents.count("locations"), 2)        # Pantry + Shelf
        self.assertEqual(ents.count("quantity_units"), 1)
        # three chores have a last_done date: one tracked execution each, at that date
        execs = self.fake.posts("/chores/")
        self.assertEqual(len(execs), 3)
        self.assertIn({"tracked_time": "2026-03-17 12:00:00"}, [c[2] for c in execs])
        self.assertEqual(writes, len(self.fake.posts()))

    def test_second_apply_is_idempotent(self):
        self.run_import(apply=True)
        before = len(self.fake.posts())
        writes, out = self.run_import(apply=True)
        self.assertEqual(writes, 0)
        self.assertEqual(len(self.fake.posts()), before)
        self.assertIn("keep    chores: Test task A", out)

    def test_key_sent_in_header_never_printed(self):
        _, out = self.run_import(apply=True)
        self.assertTrue(self.fake.calls)
        self.assertTrue(all(c[3] == KEY for c in self.fake.calls))
        self.assertNotIn(KEY, out)

    def test_missing_files_refused(self):
        with tempfile.TemporaryDirectory() as empty, self.assertRaises(gi.InputError):
            gi.run(self.fake.url, KEY, empty, False, out=io.StringIO())

    def test_missing_column_value_refused(self):
        write_csvs(self.tmp.name, chores="Nameless cadence,,,,\n")
        with self.assertRaises(gi.InputError) as cm:
            gi.run(self.fake.url, KEY, self.tmp.name, False, out=io.StringIO())
        self.assertIn("missing cadence", str(cm.exception))
        self.assertEqual(self.fake.posts(), [])


class Key(unittest.TestCase):
    def test_env_wins_then_file_then_refuse(self):
        with tempfile.TemporaryDirectory() as d:
            kf = os.path.join(d, "key")
            with open(kf, "w") as f:
                f.write("from-file\n")
            old = os.environ.pop("GROCY_API_KEY", None)
            try:
                self.assertEqual(gi.read_key(kf), "from-file")
                os.environ["GROCY_API_KEY"] = "from-env"
                self.assertEqual(gi.read_key(kf), "from-env")
                del os.environ["GROCY_API_KEY"]
                with self.assertRaises(gi.InputError):
                    gi.read_key(os.path.join(d, "absent"))
            finally:
                if old is not None:
                    os.environ["GROCY_API_KEY"] = old


if __name__ == "__main__":
    unittest.main()
