"""Unit tests for server/household/openwebui_health_tool.py (the Health agent's tool, docs/household/health-agent.md)
against a fake Grocy and a fake calendar feed, both local HTTP servers. Synthetic data only: no household data here.

What they hold the tool to: the four answers are right; only calendar events that match an appointment kind are
named (anything else is "busy" at most, or absent); nothing is written without the user's own plain OK; the feed
reader copes with all-day dates, time zones and folded lines; secrets never appear in a result.

Run:  python3 -m unittest -v tests/test_openwebui_health_tool.py   (standard library only; pydantic is stubbed when
it is not installed, as in tests/test_openwebui_grocy_tool.py)
"""
import asyncio
import datetime as dt
import json
import os
import sys
import threading
import types
import unittest
import zoneinfo
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import pydantic  # noqa: F401
except ImportError:
    stub = types.ModuleType("pydantic")

    def Field(default=None, **_):
        return default

    class BaseModel:
        def __init__(self, **kw):
            for k in dir(type(self)):
                if not k.startswith("_"):
                    setattr(self, k, kw.get(k, getattr(type(self), k)))

    stub.Field, stub.BaseModel = Field, BaseModel
    sys.modules["pydantic"] = stub

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "household"))
import openwebui_health_tool as tool  # noqa: E402

KEY = "test-grocy-key-0123456789"
TODAY = dt.date.today()


def d(days):
    return TODAY + dt.timedelta(days=days)


def ics(events):
    """events: [(date, time or None, summary)] -> iCalendar text, CRLF, as a calendar app serves it."""
    out = ["BEGIN:VCALENDAR", "VERSION:2.0"]
    for day, time, summary in events:
        out.append("BEGIN:VEVENT")
        if time:
            out.append(f"DTSTART;TZID=America/New_York:{day.strftime('%Y%m%d')}T{time.replace(':', '')}00")
        else:
            out.append(f"DTSTART;VALUE=DATE:{day.strftime('%Y%m%d')}")
        out.append(f"SUMMARY:{summary}")
        out.append("END:VEVENT")
    out.append("END:VCALENDAR")
    return "\r\n".join(out) + "\r\n"


class Fake:
    """One HTTP server playing Grocy (/api/...) and two calendar feeds (/feed/a.ics, /feed/b.ics)."""

    def __init__(self):
        self.userentities = [{"id": 7, "name": "appointment_kinds"}, {"id": 8, "name": "something_else"}]
        self.userobjects = [{"id": 100, "userentity_id": 7}, {"id": 101, "userentity_id": 7},
                            {"id": 102, "userentity_id": 7}, {"id": 200, "userentity_id": 8}]
        self.values = {
            100: {"person": "Alex", "kind": "dentist", "provider": "Test Dental", "how_to_book": "phone 555-0100",
                  "notes": "", "match_words": "dentist, dental"},
            101: {"person": "Alex", "kind": "therapy", "provider": "", "how_to_book": "portal", "notes": "",
                  "match_words": ""},
            102: {"person": "Sam", "kind": "dentist", "provider": "Test Dental", "how_to_book": "phone 555-0100",
                  "notes": "arrive 15 min early", "match_words": "dentist"},
            200: {"person": "Alex", "kind": "NOT AN APPOINTMENT", "provider": "", "how_to_book": "", "notes": "",
                  "match_words": "party"},
        }
        self.chores_objects = [{"id": 40, "name": "Book: Alex dentist"}, {"id": 41, "name": "Book: Sam dentist"},
                               {"id": 42, "name": "Book: Alex therapy"}, {"id": 43, "name": "Replace filter"}]
        self.chores = [
            {"chore_id": 40, "chore_name": "Book: Alex dentist", "next_estimated_execution_time": d(-3).isoformat() + " 23:59:59",
             "last_tracked_time": "2026-04-01 12:00:00"},
            {"chore_id": 41, "chore_name": "Book: Sam dentist", "next_estimated_execution_time": d(10).isoformat() + " 23:59:59",
             "last_tracked_time": "2026-05-10 12:00:00"},
            {"chore_id": 42, "chore_name": "Book: Alex therapy", "next_estimated_execution_time": d(200).isoformat() + " 23:59:59",
             "last_tracked_time": None},
            {"chore_id": 43, "chore_name": "Replace filter", "next_estimated_execution_time": d(1).isoformat() + " 23:59:59",
             "last_tracked_time": "2026-10-25 00:00:00"},
        ]
        self.feeds = {
            "/feed/a.ics": ics([(d(5), "09:30", "Alex Dentist cleaning"), (d(5), "18:00", "Dinner with friends"),
                                (d(7), None, "Alex therapy"), (d(20), "14:00", "Birthday party"),
                                (d(-2), "10:00", "Alex dentist (past)"), (d(90), "10:00", "Alex dentist far away")]),
            "/feed/b.ics": ics([(d(5), "11:00", "Sam dentist"), (d(6), "08:00", "Work trip"),
                                (d(5), None, "Holiday")]),
        }
        self.calls = []
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj, ctype="application/json"):
                body = obj.encode() if isinstance(obj, str) else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"null")

            def do_GET(self):
                p = self.path
                fake.calls.append(("GET", p, None))
                if p in fake.feeds:
                    return self._send(200, fake.feeds[p], "text/calendar")
                if self.headers.get("GROCY-API-KEY") != KEY:
                    return self._send(401, {"error_message": "bad key"})
                if p == "/api/objects/userentities":
                    return self._send(200, fake.userentities)
                if p == "/api/objects/userobjects":
                    return self._send(200, fake.userobjects)
                if p.startswith("/api/userfields/userentity-appointment_kinds/"):
                    return self._send(200, fake.values.get(int(p.rsplit("/", 1)[1]), {}))
                if p == "/api/objects/chores":
                    return self._send(200, fake.chores_objects)
                if p == "/api/chores":
                    return self._send(200, fake.chores)
                return self._send(404, {"error_message": f"no route {p}"})

            def do_POST(self):
                body = self._body()
                fake.calls.append(("POST", self.path, body))
                if self.path == "/api/objects/userobjects":
                    new = max(o["id"] for o in fake.userobjects) + 1
                    fake.userobjects.append({"id": new, "userentity_id": body["userentity_id"]})
                    return self._send(200, {"created_object_id": new})
                if self.path.startswith("/api/chores/") and self.path.endswith("/execute"):
                    return self._send(200, {"id": 1})
                return self._send(404, {"error_message": "no route"})

            def do_PUT(self):
                body = self._body()
                fake.calls.append(("PUT", self.path, body))
                if self.path.startswith("/api/userfields/userentity-appointment_kinds/"):
                    fake.values[int(self.path.rsplit("/", 1)[1])] = body
                    return self._send(204, "")
                return self._send(404, {"error_message": "no route"})

        self.server = HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def writes(self):
        return [c for c in self.calls if c[0] in ("POST", "PUT")]


def run(coro):
    return asyncio.run(coro)


class Base(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.t = tool.Tools()
        v = self.t.valves
        v.grocy_url, v.api_key = self.fake.url, KEY
        v.feed_1_person, v.feed_1_url = "Alex", self.fake.url + "/feed/a.ics"
        v.feed_2_person, v.feed_2_url = "Sam", self.fake.url + "/feed/b.ics"

    def tearDown(self):
        self.fake.close()


class ParseIcs(unittest.TestCase):
    def test_all_day_timed_tzid_and_utc(self):
        text = ("BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261201\r\nSUMMARY:All day\r\nEND:VEVENT\r\n"
                "BEGIN:VEVENT\r\nDTSTART;TZID=America/New_York:20261202T093000\r\nSUMMARY:Timed\r\nEND:VEVENT\r\n"
                "BEGIN:VEVENT\r\nDTSTART:20261203T150000Z\r\nSUMMARY:Utc\r\nEND:VEVENT\r\n"
                "BEGIN:VEVENT\r\nDTSTART:20261204T020000Z\r\nSUMMARY:Late\r\nEND:VEVENT\r\n")
        evs = tool.parse_ics(text, zoneinfo.ZoneInfo("America/Chicago"))
        self.assertEqual([(e["start"].isoformat(), e["time"], e["summary"]) for e in evs],
                         [("2026-12-01", "", "All day"), ("2026-12-02", "09:30", "Timed"),
                          ("2026-12-03", "09:00", "Utc"), ("2026-12-03", "20:00", "Late")])  # UTC moved, date too
        utc = tool.parse_ics(text, dt.timezone.utc)
        self.assertEqual((utc[2]["time"], utc[3]["start"].isoformat()), ("15:00", "2026-12-04"))

    def test_bad_time_zone_valve_is_named(self):
        t = tool.Tools()
        t.valves.time_zone = "Not/AZone"
        with self.assertRaisesRegex(tool.HealthError, "is not a time zone name"):
            t._tz()
        t.valves.time_zone = " America/Chicago "
        self.assertEqual(str(t._tz()), "America/Chicago")

    def test_folded_summary_and_escapes(self):
        text = ("BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261201\r\nSUMMARY:Dentist\\, check-up and \r\n"
                " cleaning\\; bring card\r\nEND:VEVENT\r\n")
        self.assertEqual(tool.parse_ics(text)[0]["summary"], "Dentist, check-up and cleaning; bring card")

    def test_event_without_start_is_dropped(self):
        self.assertEqual(tool.parse_ics("BEGIN:VEVENT\nSUMMARY:No date\nEND:VEVENT\n"), [])


class Matching(unittest.TestCase):
    def test_words_and_fallback_to_kind(self):
        self.assertEqual(tool.words_of({"kind": "dentist", "match_words": "dentist, dental"}), ["dentist", "dental"])
        self.assertEqual(tool.words_of({"kind": "Therapy", "match_words": ""}), ["therapy"])

    def test_whole_words_only(self):
        self.assertTrue(tool.matches("Alex Dentist cleaning", ["dentist"]))
        self.assertFalse(tool.matches("Dentistry conference", ["dentist"]))
        self.assertFalse(tool.matches("Dinner", ["dentist"]))


class AppointmentsDue(Base):
    def test_due_and_overdue_with_how_to_book_only_book_chores(self):
        out = run(self.t.appointments_due(days=30))
        self.assertIn("Alex dentist (Test Dental): due", out)
        self.assertIn("OVERDUE", out)
        self.assertIn("book via phone 555-0100", out)
        self.assertIn("Sam dentist", out)
        self.assertNotIn("therapy", out)       # due in 200 days
        self.assertNotIn("filter", out)        # not a Book: chore
        self.assertEqual(self.fake.writes(), [])

    def test_nothing_due(self):
        self.fake.chores = [c for c in self.fake.chores if not c["chore_name"].startswith("Book:")]
        self.assertIn("Nothing is due to book", run(self.t.appointments_due(days=30)))


class Upcoming(Base):
    def test_only_matching_events_are_named(self):
        out = run(self.t.upcoming(days=60))
        self.assertIn("Alex, dentist (Alex Dentist cleaning)", out)
        self.assertIn("Alex, therapy (Alex therapy)", out)
        self.assertIn("Sam, dentist (Sam dentist)", out)
        self.assertIn("arrive 15 min early", out)
        for private in ("Dinner", "party", "Work trip", "Holiday", "NOT AN APPOINTMENT"):
            self.assertNotIn(private, out)

    def test_window_excludes_past_and_far(self):
        out = run(self.t.upcoming(days=60))
        self.assertNotIn("(past)", out)
        self.assertNotIn("far away", out)

    def test_one_person(self):
        out = run(self.t.upcoming(person="sam", days=60))
        self.assertIn("Sam, dentist", out)
        self.assertNotIn("Alex", out)

    def test_a_kind_of_another_person_does_not_match_this_feed(self):
        # "Sam dentist" sits in Sam's feed; an identical title in Alex's feed would match Alex's own dentist kind,
        # but Sam's kinds never match Alex's feed and the other way round.
        self.fake.values[102]["match_words"] = "work trip"
        out = run(self.t.upcoming(person="alex", days=60))
        self.assertNotIn("Work trip", out)


class LastVisit(Base):
    def test_last_and_next(self):
        out = run(self.t.last_visit("Alex", "dentist"))
        self.assertIn("last dentist visit: 2026-04-01", out)
        self.assertIn(f"Next due to book: {d(-3).isoformat()}", out)

    def test_never_recorded(self):
        self.assertIn("never recorded", run(self.t.last_visit("alex", "THERAPY")))

    def test_unknown_asks(self):
        out = run(self.t.last_visit("Alex", "eye doctor"))
        self.assertIn("no appointment kind 'eye doctor' for 'Alex'", out)
        self.assertIn("Ask which one is meant", out)


class LogVisit(Base):
    def test_preview_writes_nothing(self):
        out = run(self.t.log_visit("Alex", "dentist", d(-1).isoformat()))
        self.assertIn("Ready to record Alex's dentist visit", out)
        self.assertEqual(self.fake.writes(), [])

    def test_confirm_without_the_users_ok_writes_nothing(self):
        for msg in ("log it but change the date", "wait", "no", "what about Sam?"):
            with self.subTest(msg=msg):
                out = run(self.t.log_visit("Alex", "dentist", d(-1).isoformat(), confirm=True,
                                           __messages__=[{"role": "user", "content": msg}]))
                self.assertIn("Nothing is written", out)
        self.assertEqual(self.fake.writes(), [])

    def test_confirm_with_ok_records_on_the_visit_day(self):
        out = run(self.t.log_visit("Alex", "dentist", d(-1).isoformat(), confirm=True,
                                   __messages__=[{"role": "user", "content": "yes, log it"}]))
        self.assertIn("Recorded Alex's dentist visit", out)
        self.assertEqual(self.fake.writes(), [("POST", "/api/chores/40/execute",
                                               {"tracked_time": d(-1).isoformat() + " 12:00:00"})])

    def test_future_date_refused(self):
        out = run(self.t.log_visit("Alex", "dentist", d(3).isoformat(), confirm=True,
                                   __messages__=[{"role": "user", "content": "ok"}]))
        self.assertIn("is in the future", out)
        self.assertEqual(self.fake.writes(), [])

    def test_bad_date_refused(self):
        self.assertIn("is not a visit date", run(self.t.log_visit("Alex", "dentist", "11/02/2026")))


class CheckClash(Base):
    def test_appointments_named_everything_else_busy_without_title(self):
        out = run(self.t.check_clash(d(5).isoformat()))
        self.assertIn("09:30: Alex, dentist appointment", out)
        self.assertIn("18:00: Alex, busy", out)
        self.assertIn("11:00: Sam, dentist appointment", out)
        self.assertIn("all day: Sam, busy", out)
        for private in ("Dinner", "friends", "Holiday", "cleaning"):
            self.assertNotIn(private, out)

    def test_free_day(self):
        self.assertIn("Nothing on the calendar", run(self.t.check_clash(d(40).isoformat())))


class AddKind(Base):
    def test_preview_then_ok(self):
        out = run(self.t.add_kind("Sam", "eye doctor", provider="Test Eyes", match_words="eye, optometrist"))
        self.assertIn("Ready to add 'eye doctor' for Sam (Test Eyes)", out)
        self.assertEqual(self.fake.writes(), [])
        out = run(self.t.add_kind("Sam", "eye doctor", provider="Test Eyes", match_words="eye, optometrist",
                                  confirm=True, __messages__=[{"role": "user", "content": "OK"}]))
        self.assertIn("Added 'eye doctor' for Sam", out)
        w = self.fake.writes()
        self.assertEqual(w[0], ("POST", "/api/objects/userobjects", {"userentity_id": 7}))
        self.assertEqual(w[1][0:2], ("PUT", "/api/userfields/userentity-appointment_kinds/201"))
        self.assertEqual(w[1][2]["match_words"], "eye, optometrist")

    def test_duplicate_refused(self):
        out = run(self.t.add_kind("alex", "Dentist", confirm=True, __messages__=[{"role": "user", "content": "ok"}]))
        self.assertIn("already has", out)
        self.assertEqual(self.fake.writes(), [])


class Failures(Base):
    def test_no_list_in_grocy_says_how_to_fix(self):
        self.fake.userentities = []
        self.assertIn("run grocy_import.py with appointment_kinds.csv", run(self.t.appointments_due()))

    def test_secrets_never_in_results(self):
        self.t.valves.feed_2_url = self.fake.url + "/feed/missing-SECRET-TOKEN.ics"
        out = run(self.t.upcoming())
        self.assertIn("cannot read Sam's calendar feed", out)
        self.assertNotIn("SECRET-TOKEN", out)
        self.t.valves.api_key = "wrong-key-SECRET"
        out = run(self.t.appointments_due())
        self.assertNotIn("SECRET", out)

    def test_no_feed_set(self):
        self.t.valves.feed_1_url = self.t.valves.feed_2_url = ""
        self.assertIn("no calendar feed is set", run(self.t.upcoming()))


if __name__ == "__main__":
    unittest.main()
