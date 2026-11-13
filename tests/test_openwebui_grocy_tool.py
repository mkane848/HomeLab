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
DAY = (TODAY - dt.timedelta(days=1)).isoformat()  # a recent past purchase date (the date guard refuses old ones)
US_DAY = (TODAY - dt.timedelta(days=1)).strftime("%m/%d/%Y")  # the same day as a US receipt prints it


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
            "product_barcodes": [{"id": 50, "product_id": 10, "barcode": "1111111", "shopping_location_id": 1},
                                 {"id": 51, "product_id": 14, "barcode": "2222222", "shopping_location_id": 2},
                                 {"id": 52, "product_id": 11, "barcode": "3333333", "shopping_location_id": None}],
            "stock_log": [],  # filled by purchases, as Grocy does; tests may seed rows
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
                    log = fake.objects["stock_log"]
                    row = {"id": 700 + len(log), "product_id": int(path.split("/")[3]), "amount": body["amount"],
                           "transaction_type": "purchase", "undone": 0, "price": body.get("price"),
                           "purchased_date": body.get("purchased_date", TODAY.isoformat()),
                           "shopping_location_id": body.get("shopping_location_id"), "location_id": body.get("location_id", 1)}
                    log.append(row)
                    return self._send(200, [row])
                if path.startswith("/stock/bookings/") and path.endswith("/undo"):
                    bid = int(path.split("/")[3])
                    for r in fake.objects["stock_log"]:
                        if r["id"] == bid:
                            r["undone"] = 1
                            return self._send(204, None)
                    return self._send(400, {"error_message": "Booking does not exist"})
                if path.startswith("/chores/") and path.endswith("/execute"):
                    return self._send(200, {"id": 1})
                if path.startswith("/objects/"):
                    entity = path.split("/")[2]
                    new = dict(body, id=900 + len(fake.objects.setdefault(entity, [])))
                    fake.objects[entity].append(new)
                    return self._send(200, {"created_object_id": new["id"]})
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

    def test_only_the_thirteen_tools_are_public(self):
        public = sorted(n for n in dir(tool.Tools) if not n.startswith("_") and callable(getattr(tool.Tools, n)) and n != "Valves")
        self.assertEqual(public, sorted(["find_products", "shopping_list", "add_to_shopping_list", "remove_from_shopping_list",
                                         "record_purchase", "stock", "chores_due", "complete_chore",
                                         "find_by_receipt_code", "save_receipt_code", "record_receipt",
                                         "last_purchases", "undo_last_purchase"]))

    # --- receipts: item numbers per store, and purchases with price, place and date

    def test_receipt_codes_known_and_unknown(self):
        out = run(self.t.find_by_receipt_code("1111111, 9999999", "Store A"))
        self.assertIn("- 1111111: Test mangoes", out)
        self.assertIn("- 9999999: unknown at Store A", out)

    def test_a_code_saved_for_one_store_does_not_match_another(self):
        self.assertIn("- 2222222: unknown at Store A", run(self.t.find_by_receipt_code("2222222", "Store A")))
        self.assertIn("- 2222222: Test milk", run(self.t.find_by_receipt_code("2222222", "Store B")))

    def test_a_code_saved_without_a_store_does_not_match(self):
        self.assertIn("- 3333333: unknown at Store A", run(self.t.find_by_receipt_code("3333333", "Store A")))

    def test_save_code_then_it_matches(self):
        self.assertEqual(run(self.t.save_receipt_code("bread", " 4444444 ", "Store A")), "Saved: 4444444 at Store A is Test bread.")
        (_, path, body, _), = self.g.posts("/objects/product_barcodes")
        self.assertEqual(body, {"product_id": 11, "barcode": "4444444", "shopping_location_id": 1, "note": "receipt item number"})
        self.assertIn("- 4444444: Test bread", run(self.t.find_by_receipt_code("4444444", "Store A")))

    def test_save_code_will_not_overwrite_another_products_code(self):
        out = run(self.t.save_receipt_code("bread", "1111111", "Store A"))
        self.assertIn("already saved as Test mangoes", out)
        self.assertEqual(self.g.posts("/objects/product_barcodes"), [])
        self.assertIn("already saved as Test mangoes", run(self.t.save_receipt_code("mangoes", "1111111", "Store A")))
        self.assertEqual(self.g.posts("/objects/product_barcodes"), [])

    def test_purchase_with_price_location_and_date(self):
        out = run(self.t.record_purchase("mangoes", 2, "Store A", 17.98, "Fridge", DAY))
        self.assertEqual(out, f"Recorded 2 x Test mangoes bought {DAY} at Store A for 17.98, put in Fridge.")
        body = self.g.posts("/stock/products/")[0][2]
        self.assertEqual(body["price"], 8.99)  # per unit
        self.assertEqual(body["location_id"], 2)
        self.assertEqual(body["purchased_date"], DAY)

    def test_purchase_today_sends_no_date_and_no_price_when_unknown(self):
        run(self.t.record_purchase("mangoes"))
        body = self.g.posts("/stock/products/")[0][2]
        self.assertNotIn("purchased_date", body)
        self.assertNotIn("price", body)
        self.assertNotIn("location_id", body)

    def test_purchase_rejects_a_bad_date_or_amount(self):
        self.assertIn("is not a date", run(self.t.record_purchase("mangoes", 1, "", 0, "", "yesterday")))
        self.assertIn("more than 0", run(self.t.record_purchase("mangoes", 0)))
        self.assertEqual(self.g.posts(), [])

    def test_purchase_date_guard(self):
        ago = lambda n: (TODAY - dt.timedelta(days=n)).isoformat()
        self.assertIn("looks wrong", run(self.t.record_purchase("mangoes", 1, "", 0, "", ago(-1))))  # tomorrow
        self.assertIn("looks wrong", run(self.t.record_purchase("mangoes", 1, "", 0, "", ago(61))))
        self.assertIn("looks wrong", run(self.t.record_purchase("mangoes", 1, "", 0, "", "2023-10-15")))  # the invented one
        self.assertEqual(self.g.posts(), [])
        self.assertIn(f"bought {ago(60)}", run(self.t.record_purchase("mangoes", 1, "", 0, "", ago(60))))
        self.assertIn(f"bought {DAY}", run(self.t.record_purchase("mangoes", 1, "", 0, "", US_DAY)))

    # --- names: a plural finds the singular

    def test_plural_falls_back_to_the_singular(self):
        out = run(self.t.record_purchase("cheeses"))
        self.assertIn("matches 2 products", out)  # asks, as for "cheese"
        self.assertIn("Test mangoes", run(self.t.find_products("mangoess")))  # "es" then "s"
        self.assertEqual(run(self.t.stock("milks")), "Test milk: 0 in stock.")
        self.assertIn("no product is called 'caviars'", run(self.t.stock("caviars")))

    # --- purchase history and undo

    def seed_log(self):
        self.g.objects["stock_log"] += [
            {"id": 1, "product_id": 11, "amount": 1, "transaction_type": "purchase", "undone": 0, "price": 3.5,
             "purchased_date": "2026-10-01", "shopping_location_id": 1, "location_id": 1},
            {"id": 2, "product_id": 11, "amount": 2, "transaction_type": "purchase", "undone": 0, "price": 4.0,
             "purchased_date": "2026-10-20", "shopping_location_id": 2, "location_id": 2},
            {"id": 3, "product_id": 11, "amount": 1, "transaction_type": "purchase", "undone": 1, "price": 9.0,
             "purchased_date": "2026-10-30", "shopping_location_id": 1, "location_id": 1},
            {"id": 4, "product_id": 11, "amount": 1, "transaction_type": "consume", "undone": 0, "price": None,
             "purchased_date": "2026-10-31", "shopping_location_id": None, "location_id": 1},
        ]

    def test_last_purchases_reads_the_log_and_skips_undone(self):
        self.seed_log()
        out = run(self.t.last_purchases("bread"))
        self.assertTrue(out.startswith("Test bread, the last 2 of 2 purchase(s):"), out)
        lines = out.splitlines()[1:]
        self.assertEqual(lines[0], "- bought 2026-10-20 at Store B for 8.00 (2), put in Fridge")
        self.assertEqual(lines[1], "- bought 2026-10-01 at Store A for 3.50 (1), put in Pantry")
        self.assertEqual(run(self.t.last_purchases("milk")), "No purchase of Test milk is recorded.")

    def test_undo_shows_first_then_undoes_only_the_latest(self):
        self.seed_log()
        out = run(self.t.undo_last_purchase("bread"))
        self.assertIn("This would undo: Test bread bought 2026-10-20 at Store B", out)
        self.assertEqual(self.g.posts(), [])
        out = run(self.t.undo_last_purchase("bread", True))
        self.assertTrue(out.startswith("Undid: Test bread bought 2026-10-20"), out)
        (_, path, _, _), = self.g.posts()
        self.assertEqual(path, "/api/stock/bookings/2/undo")
        self.assertIn("2026-10-01", run(self.t.undo_last_purchase("bread")))  # the next one down, not the undone #3
        self.assertIn("nothing to undo", run(self.t.undo_last_purchase("milk", True)))

    def test_undo_needs_the_users_ok(self):
        self.seed_log()
        out = run(self.t.undo_last_purchase("bread", True, [{"role": "user", "content": "change the price instead"}]))
        self.assertIn("nothing was undone", out)
        self.assertEqual(self.g.posts(), [])
        out = run(self.t.undo_last_purchase("bread", True, [{"role": "user", "content": "confirmed."}]))
        self.assertTrue(out.startswith("Undid: Test bread"), out)

    # --- record_receipt: the model copies lines, the code does the bookkeeping

    RECEIPT = "\n".join([
        "E 1111111 TEST MANGO 8.99 A",
        "5555555 **TEST LOAF** 12.00",
        "0000000001 / 5555555 2.50-",
        "6666666 TEST GAME 59.99 A",
        "0000000002 / 6666666 5.00-",
        "7777777 TEST CHEESE 6.49",
        "8888888 TEST MILK 4.00",
        "0000000003 1.00-",
    ])

    def receipt(self, **kw):
        args = dict(store="Store A", date=US_DAY, lines=self.RECEIPT, items_sold=5, skip="6666666",
                    matches="5555555=Test bread; 6666666=Test cheese, blueberry; 7777777=Test cheese, herby; 8888888=Test milk")
        args.update(kw)
        return run(self.t.record_receipt(**args))

    def purchases(self):
        return [(int(c[1].split("/")[4]), c[2].get("price"), c[2].get("purchased_date"), c[2].get("shopping_location_id"))
                for c in self.g.posts("/stock/products/")]

    def test_receipt_preview_applies_discounts_and_writes_nothing(self):
        out = self.receipt()
        self.assertIn(f"Receipt: Store A, {DAY}. Item lines read: 5 (Items Sold printed: 5).", out)
        self.assertIn("1. 1111111 TEST MANGO -> Test mangoes, 1, 8.99\n", out)
        self.assertIn("2. 5555555 TEST LOAF -> Test bread, 1, 9.50 (after a 2.50 discount)", out)
        self.assertIn("3. 7777777 TEST CHEESE -> Test cheese, herby, 1, 6.49", out)
        self.assertIn("4. 8888888 TEST MILK -> Test milk, 1, 3.00 (after a 1.00 discount)", out)  # unnamed: the line above
        self.assertIn("Skipped: 6666666 TEST GAME", out)
        self.assertIn("Total paid for these 4: 27.98", out)
        self.assertTrue(out.endswith("Nothing written yet. Show this list to the user and wait for OK."), out)
        self.assertEqual(self.g.posts(), [])

    def test_receipt_skip_by_text_drops_the_line_and_its_discount(self):
        out = self.receipt(skip="game, loaf")
        self.assertIn("Skipped: 5555555 TEST LOAF; 6666666 TEST GAME", out)
        self.assertIn("Total paid for these 3: 18.48", out)

    def test_receipt_discount_named_out_of_order(self):
        lines = "5555555 TEST LOAF 12.00\n7777777 TEST CHEESE 6.49\n0000000001 / 5555555 2.50-"
        out = self.receipt(lines=lines, items_sold=0, skip="")
        self.assertIn("TEST LOAF -> Test bread, 1, 9.50 (after a 2.50 discount)", out)
        self.assertIn("TEST CHEESE -> Test cheese, herby, 1, 6.49\n", out)

    def test_receipt_tax_flag_touching_the_price(self):
        # 2026-11-10: Costco prints a discount as "2.50-A"; 0.3.0 could not read it and the chat offered to skip it.
        lines = "5555555 TEST LOAF 12.00A\n0000000001 / 5555555 2.50-A\n8888888 TEST MILK 4.00\n0000000003 -1.00N"
        out = self.receipt(lines=lines, items_sold=2, skip="")
        self.assertIn("TEST LOAF -> Test bread, 1, 9.50 (after a 2.50 discount)", out)
        self.assertIn("TEST MILK -> Test milk, 1, 3.00 (after a 1.00 discount)", out)
        self.assertIn("cannot read the receipt line", self.receipt(lines="5555555 TEST LOAF 12.00AB", skip=""))

    def test_receipt_discount_with_a_lost_leading_digit(self):
        # 2026-11-10: the chat dropped the first digit of the item a discount names; the one item above ending in those digits takes it.
        lines = "5555555 TEST LOAF 12.00\n7777777 TEST CHEESE 6.49\n0000000001 / 555555 2.50-"
        out = self.receipt(lines=lines, items_sold=0, skip="")
        self.assertIn("TEST LOAF -> Test bread, 1, 9.50 (after a 2.50 discount)", out)
        two = "1555555 TEST LOAF 12.00\n2555555 TEST CHEESE 6.49\n0000000001 / 555555 2.50-"
        self.assertIn("names item 555555", self.receipt(lines=two, items_sold=0, skip=""))  # two candidates
        short = "5555555 TEST LOAF 12.00\n0000000001 / 5555 2.50-"
        self.assertIn("names item 5555", self.receipt(lines=short, items_sold=0, skip=""))  # too short to trust

    def test_receipt_bad_discounts_are_errors(self):
        self.assertIn("has no item line above it", self.receipt(lines="0000000001 2.50-\n1111111 TEST MANGO 8.99", confirm=True))
        self.assertIn("names item 9999999", self.receipt(lines="1111111 TEST MANGO 8.99\n0000000001 / 9999999 2.50-", confirm=True))
        self.assertIn("more than its price", self.receipt(lines="1111111 TEST MANGO 1.99\n0000000001 / 1111111 2.50-", confirm=True))
        self.assertIn("cannot read the receipt line 'TEST MANGO 8.99'", self.receipt(lines="TEST MANGO 8.99", confirm=True))
        self.assertEqual(self.g.posts(), [])

    def test_receipt_unknown_line_blocks_confirm(self):
        out = self.receipt(matches="5555555=Test bread; 7777777=Test cheese, herby", confirm=True)
        self.assertIn("4. 8888888 TEST MILK -> UNKNOWN: ask the user which product", out)
        self.assertIn("1 line(s) unknown", out)
        self.assertTrue(out.endswith("Nothing written yet."), out)
        self.assertEqual(self.g.posts(), [])

    def test_receipt_counts_that_differ_are_flagged(self):
        self.assertIn("The counts differ: ask the user", self.receipt(items_sold=6))

    def test_receipt_skip_naming_a_line_left_out_still_counts(self):
        # 2026-11-10: the chat put "<code> <text>" of a line in skip but left the line out of lines; 12 read of 13.
        lines = "\n".join(l for l in self.RECEIPT.splitlines() if "GAME" not in l and "/ 6666666" not in l)
        out = self.receipt(lines=lines, skip="9999999 TEST TOY")
        self.assertIn("Item lines read: 5 (Items Sold printed: 5).", out)
        self.assertIn("Skipped: 9999999 TEST TOY", out)
        out = self.receipt(skip="6666666 TEST GAME")  # code and words: matches the line itself, counted once
        self.assertIn("Item lines read: 5 (Items Sold printed: 5).", out)
        self.assertIn("Skipped: 6666666 TEST GAME\n", out)
        self.assertNotIn("The counts differ", self.receipt(skip="game"))

    def test_receipt_whole_pasted_receipt_with_footer_and_literal_breaks(self):
        # 2026-11-12: the chat sent the receipt as one string with backslash-n breaks, footer included.
        lines = ("5555555 TEST LOAF 12.00A\\n0000000001 / 5555555 2.50-A\\n8888888 TEST MILK 4.00\\nSUBTOTAL 17.50\\n"
                 "TAX 0.27\\n**** TOTAL 17.77\\nA 6.625% Tax 0.27\\n11/08/2026 09:15 739 2 15 79\\n"
                 "21073900200152611080915\\nOP#: 79 Name: SANDY K\\nTotal BOB Item Count = 2")
        out = self.receipt(lines=lines, items_sold=2, skip="", matches="5555555=Test bread; 8888888=Test milk")
        self.assertIn("Item lines read: 2 (Items Sold printed: 2).", out)
        self.assertIn("TEST LOAF -> Test bread, 1, 9.50 (after a 2.50 discount)", out)
        self.assertNotIn("cannot read", out)

    def test_receipt_messages_say_what_to_do_next(self):
        # 2026-11-12: "skip BOOK" matched nothing and the model did not notice; unknown lines did not say what to call.
        out = self.receipt(matches="1111111=Test mangoes; 6666666=Test cheese, blueberry; 7777777=Test cheese, herby; "
                                   "8888888=Test milk", skip="book, 2076209", lines=self.RECEIPT.replace("TEST LOAF", "BK GARTEN"))
        self.assertIn("Skip matched no line: 'book'", out)
        self.assertIn("1 line(s) unknown (5555555). Ask the user", out)
        self.assertIn("skip='<code>'", out)
        out = self.receipt(matches="5555555=Nonexistent thing", confirm=False)
        self.assertIn("For 5555555: ask the user for the product's exact name", out)
        self.assertIn("put 5555555 in skip", out)
        self.assertEqual(self.g.posts(), [])

    def test_receipt_confirm_needs_the_users_ok(self):
        # 2026-11-10: confirm=true right after "skip the book". The tool reads the user's last message itself.
        ok = "5555555=Test bread; 7777777=Test cheese, herby; 8888888=Test milk; 1111111=Test mangoes"
        for said in ["Skip the book.", "Yes, but skip the milk", "no", "OK, wait", "Record this receipt"]:
            out = self.receipt(matches=ok, confirm=True, __messages__=[{"role": "user", "content": "OK"},
                                                                       {"role": "assistant", "content": "list"},
                                                                       {"role": "user", "content": said}])
            self.assertIn("Not written: the user's last message is not an OK", out, said)
            self.assertEqual(self.g.posts(), [], said)
        parts = [{"type": "text", "text": "Looks good"}, {"type": "image_url", "image_url": {"url": "data:"}}]
        out = self.receipt(matches=ok, confirm=True, __messages__=[{"role": "user", "content": parts},
                                                                   {"role": "assistant", "content": "tool call"}])
        self.assertTrue(out.startswith("Recorded 4 purchase(s)"), out)

    def test_receipt_confirm_records_net_prices_and_saves_only_new_codes(self):
        out = self.receipt(confirm=True)
        self.assertTrue(out.startswith(f"Recorded 4 purchase(s) at Store A dated {DAY}:"), out)
        self.assertEqual(self.purchases(), [(10, 8.99, DAY, 1), (11, 9.5, DAY, 1), (12, 6.49, DAY, 1), (14, 3.0, DAY, 1)])
        saved = sorted((c[2]["barcode"], c[2]["product_id"], c[2]["shopping_location_id"]) for c in self.g.posts("/objects/product_barcodes"))
        self.assertEqual(saved, [("5555555", 11, 1), ("7777777", 12, 1), ("8888888", 14, 1)])  # not the known 1111111, not the skipped game
        self.assertIn("- 5555555: Test bread", run(self.t.find_by_receipt_code("5555555", "Store A")))

    def test_receipt_second_ok_writes_nothing_twice(self):
        self.receipt(confirm=True)
        before = len(self.g.posts())
        out = self.receipt(confirm=True)
        self.assertEqual(len(self.g.posts()), before, out)
        self.assertIn("Recorded 0 purchase(s)", out)
        self.assertIn("Already recorded, so not written again: Test mangoes, Test bread, Test cheese, herby, Test milk.", out)

    def test_receipt_two_identical_lines_are_two_purchases(self):
        lines = "1111111 TEST MANGO 8.99\n1111111 TEST MANGO 8.99"
        self.receipt(lines=lines, items_sold=2, skip="", matches="", confirm=True)
        self.assertEqual(len(self.purchases()), 2)
        self.receipt(lines=lines, items_sold=2, skip="", matches="", confirm=True)
        self.assertEqual(len(self.purchases()), 2)

    def test_receipt_will_not_resave_a_code_to_another_product(self):
        out = self.receipt(matches="1111111=Test bread", confirm=True)
        self.assertIn("already saved as Test mangoes", out)
        self.assertEqual(self.g.posts(), [])

    def test_receipt_date_as_printed_or_iso_and_guarded(self):
        self.assertIn(f"Receipt: Store A, {DAY}.", self.receipt(date=DAY))
        self.assertIn("looks wrong", self.receipt(date="08/11/2025"))
        self.assertIn("is not a date", self.receipt(date="13/45/2026"))


if __name__ == "__main__":
    unittest.main()
