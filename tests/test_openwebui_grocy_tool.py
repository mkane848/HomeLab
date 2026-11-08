"""Unit tests for server/household/openwebui_grocy_tool.py (the chat's Grocy tool) against a fake Grocy: a local HTTP
server that keeps objects per entity and records every call. Synthetic data only: no household data here.

Run:  python3 -m unittest -v tests/test_openwebui_grocy_tool.py   (standard library only; pydantic is stubbed when
it is not installed, since Open WebUI provides it and the tests only need Field and BaseModel to construct the Valves)
"""
import asyncio
import datetime as dt
import json
import os
import sys
import threading
import types
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import pydantic  # noqa: F401
except ImportError:  # a minimal stand-in: class attributes with defaults, overridable by keyword
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
import openwebui_grocy_tool as tool  # noqa: E402

KEY = "test-key-0123456789"
TODAY = dt.date.today()


class FakeGrocy:
    def __init__(self):
        self.objects = {
            "shopping_locations": [{"id": 1, "name": "Store A"}, {"id": 2, "name": "Store B"}],
            "locations": [{"id": 1, "name": "Pantry"}, {"id": 2, "name": "Fridge"}],
            "products": [
                {"id": 10, "name": "Test mangoes", "shopping_location_id": 1, "location_id": 1},
                {"id": 11, "name": "Test bread", "shopping_location_id": None, "location_id": 1},
                {"id": 12, "name": "Test cheese, herby", "shopping_location_id": 2, "location_id": 2},
                {"id": 13, "name": "Test cheese, blueberry", "shopping_location_id": 2, "location_id": 2},
                {"id": 14, "name": "Test milk", "shopping_location_id": 2, "location_id": 2},
            ],
            "shopping_list": [],
            "chores": [{"id": 30, "name": "Test filter"}, {"id": 31, "name": "Test spigots"}],
        }
        self.stock = [{"product_id": 10, "amount": "2"}, {"product_id": 14, "amount": "0"}]
        self.chores = [
            {"chore_id": 30, "chore_name": "Test filter", "next_estimated_execution_time": (TODAY + dt.timedelta(days=2)).isoformat() + " 23:59:59",
             "last_tracked_time": "2026-10-25 00:00:00"},
            {"chore_id": 31, "chore_name": "Test spigots", "next_estimated_execution_time": (TODAY + dt.timedelta(days=300)).isoformat() + " 23:59:59",
             "last_tracked_time": "2026-10-26 00:00:00"},
        ]
        self.calls = []
        self.fail = None  # (code, message) to refuse every request
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

            def _guard(self, method, body=None):
                fake.calls.append((method, self.path, body, self.headers.get("GROCY-API-KEY")))
                if fake.fail:
                    self._send(fake.fail[0], {"error_message": fake.fail[1]})
                    return True
                return False

            def do_GET(self):
                if self._guard("GET"):
                    return
                path = self.path[len("/api"):]
                if path.startswith("/objects/"):
                    return self._send(200, fake.objects.get(path.split("/")[2], []))
                if path == "/stock":
                    return self._send(200, fake.stock)
                if path == "/chores":
                    return self._send(200, fake.chores)
                self._send(404, {"error_message": "no route"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"null")
                if self._guard("POST", body):
                    return
                path = self.path[len("/api"):]
                if path == "/stock/shoppinglist/add-product":
                    fake.objects["shopping_list"].append({"id": len(fake.objects["shopping_list"]) + 1, "shopping_list_id": body["list_id"],
                                                          "product_id": body["product_id"], "amount": body["product_amount"],
                                                          "note": body.get("note", ""), "done": 0})
                    return self._send(200, {})
                if path == "/stock/shoppinglist/remove-product":
                    fake.objects["shopping_list"] = [i for i in fake.objects["shopping_list"] if i["product_id"] != body["product_id"]]
                    return self._send(200, {})
                if path.startswith("/stock/products/") and path.endswith("/add"):
                    return self._send(200, [{"id": 1}])
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


def run(coro):
    return asyncio.run(coro)


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.g = FakeGrocy()
        self.t = tool.Tools()
        self.t.valves.grocy_url = self.g.url
        self.t.valves.api_key = KEY

    def tearDown(self):
        self.g.close()

    # --- name resolution: exact, then a single substring match, else ask

    def test_exact_name_wins_over_substring(self):
        self.g.objects["products"].append({"id": 15, "name": "Test milk powder", "shopping_location_id": None, "location_id": 1})
        out = run(self.t.add_to_shopping_list("test MILK"))
        self.assertEqual(out, "Added 1 x Test milk to the shopping list.")
        self.assertEqual(self.g.posts("/stock/shoppinglist/add-product")[0][2]["product_id"], 14)

    def test_single_substring_match_is_used(self):
        out = run(self.t.add_to_shopping_list("mango", 2))
        self.assertEqual(out, "Added 2 x Test mangoes to the shopping list.")

    def test_ambiguous_name_asks_and_writes_nothing(self):
        out = run(self.t.add_to_shopping_list("cheese"))
        self.assertIn("matches 2 products", out)
        self.assertIn("Test cheese, blueberry", out)
        self.assertTrue(out.endswith("Which one?"), out)
        self.assertEqual(self.g.posts(), [])

    def test_unknown_name_says_so_and_writes_nothing(self):
        out = run(self.t.record_purchase("caviar"))
        self.assertEqual(out, "Could not do that: no product is called 'caviar'.")
        self.assertEqual(self.g.posts(), [])

    # --- the shopping list, per store

    def test_store_list_has_its_items_and_any_store_items_only(self):
        for p in ("Test mangoes", "Test bread", "Test milk"):
            run(self.t.add_to_shopping_list(p))
        out = run(self.t.shopping_list("store a"))
        self.assertIn("Shopping list for Store A, 2 item(s)", out)
        self.assertIn("Test mangoes x1 [Store A]", out)
        self.assertIn("Test bread x1 [any store]", out)
        self.assertNotIn("Test milk", out)
        self.assertIn("Test milk x1 [Store B]", run(self.t.shopping_list()))

    def test_done_items_are_not_shown(self):
        run(self.t.add_to_shopping_list("Test bread"))
        self.g.objects["shopping_list"][0]["done"] = 1
        self.assertEqual(run(self.t.shopping_list()), "The shopping list is empty.")

    def test_remove_takes_it_off_and_reports_when_absent(self):
        run(self.t.add_to_shopping_list("Test bread", 3))
        self.assertEqual(run(self.t.remove_from_shopping_list("bread")), "Took Test bread off the shopping list.")
        self.assertEqual(self.g.posts("/stock/shoppinglist/remove-product")[0][2]["product_amount"], 3.0)
        self.assertEqual(run(self.t.remove_from_shopping_list("bread")), "Test bread is not on the shopping list.")

    # --- purchases: dated by Grocy, tied to a store, and the list left alone

    def test_purchase_posts_the_named_store(self):
        out = run(self.t.record_purchase("Test bread", 2, "Store B"))
        self.assertEqual(out, "Recorded 2 x Test bread bought today at Store B.")
        (_, path, body, _), = self.g.posts("/stock/products/")
        self.assertEqual(path, "/api/stock/products/11/add")
        self.assertEqual(body, {"amount": 2.0, "transaction_type": "purchase", "best_before_date": "2999-12-31",
                                "shopping_location_id": 2})

    def test_purchase_defaults_to_the_products_store(self):
        run(self.t.record_purchase("mangoes"))
        self.assertEqual(self.g.posts("/stock/products/")[0][2]["shopping_location_id"], 1)

    def test_purchase_of_an_any_store_product_with_no_store_sends_none(self):
        self.assertEqual(run(self.t.record_purchase("Test bread")), "Recorded 1 x Test bread bought today.")
        self.assertNotIn("shopping_location_id", self.g.posts("/stock/products/")[0][2])

    def test_purchase_does_not_touch_the_shopping_list(self):
        run(self.t.add_to_shopping_list("Test bread"))
        run(self.t.record_purchase("Test bread", 1, "Store A"))
        self.assertEqual(self.g.posts("/stock/shoppinglist/remove-product"), [])

    # --- stock and chores

    def test_stock_lists_only_positive_amounts(self):
        out = run(self.t.stock())
        self.assertIn("- Test mangoes: 2", out)
        self.assertNotIn("Test milk", out)
        self.assertEqual(run(self.t.stock("milk")), "Test milk: 0 in stock.")

    def test_find_products_shows_store_location_and_stock(self):
        out = run(self.t.find_products("bread"))
        self.assertIn("- Test bread: store any store; kept in Pantry; in stock 0", out)

    def test_chores_due_respects_the_window(self):
        out = run(self.t.chores_due(7))
        self.assertIn("Test filter: due", out)
        self.assertIn("last done 2026-10-25", out)
        self.assertNotIn("Test spigots", out)

    def test_complete_chore_today_and_on_a_date(self):
        self.assertEqual(run(self.t.complete_chore("filter")), f"Recorded 'Test filter' as done on {TODAY.isoformat()}.")
        run(self.t.complete_chore("Test spigots", "2026-11-01"))
        bodies = [c[2] for c in self.g.posts("/chores/")]
        self.assertEqual(bodies[1], {"tracked_time": "2026-11-01 12:00:00"})
        self.assertIn("is not a date", run(self.t.complete_chore("filter", "last tuesday")))

    # --- errors as sentences, and the key kept out of every result

    def test_grocy_refusal_comes_back_as_a_sentence(self):
        self.g.fail = (400, "Product does not exist")
        out = run(self.t.stock())
        self.assertTrue(out.startswith("Could not do that: Grocy refused GET /stock (HTTP 400): Product does not exist"), out)

    def test_unreachable_grocy_is_a_sentence(self):
        self.t.valves.grocy_url = "http://127.0.0.1:1"
        self.assertTrue(run(self.t.stock()).startswith("Could not do that: cannot reach Grocy"))

    def test_missing_key_is_reported_and_nothing_is_sent(self):
        self.t.valves.api_key = ""
        self.assertIn("API key is not set", run(self.t.shopping_list()))
        self.assertEqual(self.g.calls, [])

    def test_the_key_is_sent_as_a_header_and_never_returned(self):
        outs = [run(self.t.find_products("test")), run(self.t.shopping_list()), run(self.t.chores_due())]
        self.g.fail = (401, f"bad key {KEY}")  # even if Grocy echoes it back
        outs.append(run(self.t.stock()))
        self.assertTrue(all(c[3] == KEY for c in self.g.calls))
        self.assertFalse(any(KEY in o for o in outs), outs[-1])

    def test_only_the_eight_tools_are_public(self):
        public = sorted(n for n in dir(tool.Tools) if not n.startswith("_") and callable(getattr(tool.Tools, n)) and n != "Valves")
        self.assertEqual(public, sorted(["find_products", "shopping_list", "add_to_shopping_list", "remove_from_shopping_list",
                                         "record_purchase", "stock", "chores_due", "complete_chore"]))


if __name__ == "__main__":
    unittest.main()
