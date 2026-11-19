"""Unit tests for server/household/openwebui_meals_tool.py (the Meals Homie, docs/household/meals-agent.md) against a
fake Grocy, a local HTTP server. Synthetic data only: no household data here.

What they hold the tool to: Grocy's own stock numbers decide what can be made and what is missing; Grocy's hidden
meal-plan recipes are never shown; a store's shopping takes only its products (and those sold anywhere), minus what is
already on the list; nothing is written without the user's own OK; an ingredient with no single matching product is
kept as text and named, never invented as a product.

Run:  python3 -m unittest -v tests/test_openwebui_meals_tool.py   (standard library only; pydantic is stubbed when
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
import openwebui_meals_tool as tool  # noqa: E402

KEY = "test-grocy-key-meals-0123"
TODAY = dt.date.today()


def d(days):
    return (TODAY + dt.timedelta(days=days)).isoformat()


class Fake:
    """Grocy with three stores, six products, three of the household's recipes and two hidden meal-plan recipes."""

    def __init__(self):
        self.objects = {
            "shopping_locations": [{"id": 1, "name": "Aldi"}, {"id": 2, "name": "Costco"},
                                   {"id": 3, "name": "Trader Joe's"}],
            "products": [{"id": 1, "name": "Onion", "shopping_location_id": 1},
                         {"id": 2, "name": "Green onion", "shopping_location_id": 3},
                         {"id": 3, "name": "Chicken breast", "shopping_location_id": 1},
                         {"id": 4, "name": "Rice", "shopping_location_id": 2},
                         {"id": 5, "name": "Tortillas", "shopping_location_id": None},
                         {"id": 6, "name": "Cheese", "shopping_location_id": 1}],
            "recipes": [{"id": 10, "name": "Tacos", "type": "normal", "base_servings": 4},
                        {"id": 11, "name": "Chicken and rice", "type": "normal", "base_servings": 2},
                        {"id": 12, "name": "Fried rice", "type": "normal", "base_servings": 1},
                        {"id": 90, "name": d(1), "type": "mealplan-day"},
                        {"id": 91, "name": "2026-47", "type": "mealplan-week"}],
            "recipes_pos_resolved": [
                {"recipe_id": 10, "product_id": 5, "product_name": "Tortillas", "need_fulfilled": 1,
                 "missing_amount": 0, "amount_on_shopping_list": 0},
                {"recipe_id": 11, "product_id": 4, "product_name": "Rice", "need_fulfilled": 0,
                 "missing_amount": 1, "amount_on_shopping_list": 0},
                {"recipe_id": 12, "product_id": 1, "product_name": "Onion", "need_fulfilled": 0,
                 "missing_amount": 1, "amount_on_shopping_list": 0},
                {"recipe_id": 12, "product_id": 2, "product_name": "Green onion", "need_fulfilled": 0,
                 "missing_amount": 2, "amount_on_shopping_list": 0},
                {"recipe_id": 12, "product_id": 6, "product_name": "Cheese", "need_fulfilled": 0,
                 "missing_amount": 1, "amount_on_shopping_list": 1},
                {"recipe_id": 12, "product_id": 5, "product_name": "Tortillas", "need_fulfilled": 0,
                 "missing_amount": 2, "amount_on_shopping_list": 0},
                {"recipe_id": 90, "product_id": 4, "product_name": "Rice", "need_fulfilled": 0,
                 "missing_amount": 9, "amount_on_shopping_list": 0}],
            "meal_plan": [{"id": 1, "day": d(1), "type": "recipe", "recipe_id": 11},
                          {"id": 2, "day": d(2), "type": "recipe", "recipe_id": 12},
                          {"id": 3, "day": d(3), "type": "note", "note": "Eat out"},
                          {"id": 4, "day": d(-7), "type": "recipe", "recipe_id": 10},
                          {"id": 5, "day": d(-14), "type": "recipe", "recipe_id": 10},
                          {"id": 6, "day": d(10), "type": "recipe", "recipe_id": 11}],
        }
        self.fulfillment = [
            {"recipe_id": 10, "need_fulfilled": 1, "missing_products_count": 0},
            {"recipe_id": 11, "need_fulfilled": 0, "missing_products_count": 1},
            {"recipe_id": 12, "need_fulfilled": 0, "missing_products_count": 4},
            {"recipe_id": 90, "need_fulfilled": 1, "missing_products_count": 0},
        ]
        self.calls, self.next_id = [], 200
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
                fake.calls.append(("GET", self.path, None))
                if self.headers.get("GROCY-API-KEY") != KEY:
                    return self._send(401, {"error_message": "bad key"})
                if self.path == "/api/recipes/fulfillment":
                    return self._send(200, fake.fulfillment)
                if self.path.startswith("/api/objects/"):
                    return self._send(200, fake.objects.get(self.path.split("/")[3], []))
                return self._send(404, {"error_message": "no route"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"null")
                fake.calls.append(("POST", self.path, body))
                if self.path.startswith("/api/objects/"):
                    fake.next_id += 1
                    fake.objects.setdefault(self.path.split("/")[3], []).append(dict(body, id=fake.next_id))
                    return self._send(200, {"created_object_id": fake.next_id})
                if self.path == "/api/stock/shoppinglist/add-product":
                    return self._send(204, {})
                return self._send(404, {"error_message": "no route"})

        self.server = HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def writes(self):
        return [c for c in self.calls if c[0] == "POST"]


def run(coro):
    return asyncio.run(coro)


def said(text):
    return [{"role": "user", "content": text}]


class Base(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.t = tool.Tools()
        self.t.valves.grocy_url, self.t.valves.api_key = self.fake.url, KEY

    def tearDown(self):
        self.fake.close()


class WhatCanWeMake(Base):
    def test_ready_then_nearly_ready_with_missing_names(self):
        out = run(self.t.what_can_we_make())
        self.assertIn("Ready to make now: Tacos", out)
        self.assertIn("- Chicken and rice: missing Rice", out)
        self.assertNotIn("Fried rice", out)  # missing 4, over the default of 2
        self.assertNotIn(d(1), out)          # Grocy's hidden meal-plan recipe
        self.assertEqual(self.fake.writes(), [])

    def test_more_missing_allowed(self):
        out = run(self.t.what_can_we_make(max_missing=5))
        self.assertIn("- Fried rice: missing Onion, Green onion, Tortillas", out)  # cheese is already on the list
        self.assertLess(out.index("Chicken and rice"), out.index("Fried rice"))     # fewest missing first

    def test_no_recipes(self):
        self.fake.objects["recipes"] = [r for r in self.fake.objects["recipes"] if r["type"] != "normal"]
        self.assertIn("no recipes in Grocy yet", run(self.t.what_can_we_make()))


class WeekPlan(Base):
    def test_seven_days_from_today_with_notes(self):
        out = run(self.t.week_plan())
        self.assertIn(f"{d(1)} (", out)
        self.assertIn("Chicken and rice", out)
        self.assertIn("Fried rice", out)
        self.assertIn("Eat out", out)
        self.assertNotIn(d(10), out)
        self.assertNotIn("Tacos", out)  # past

    def test_empty_week(self):
        self.assertIn("Nothing is planned", run(self.t.week_plan(start=d(20))))

    def test_bad_date(self):
        self.assertIn("is not a start date", run(self.t.week_plan(start="next friday")))


class PlanMeal(Base):
    def test_preview_then_ok(self):
        out = run(self.t.plan_meal("tacos", "tomorrow"))
        self.assertIn(f"Ready to plan Tacos on {d(1)}", out)
        self.assertEqual(self.fake.writes(), [])
        out = run(self.t.plan_meal("tacos", "tomorrow", confirm=True, __messages__=said("yes, plan it")))
        self.assertIn("Planned Tacos", out)
        self.assertEqual(self.fake.writes(), [("POST", "/api/objects/meal_plan",
                                               {"day": d(1), "type": "recipe", "recipe_id": 10,
                                                "recipe_servings": 4})])

    def test_confirm_without_ok_writes_nothing(self):
        for msg in ("tacos, but on friday", "wait", "what else is there?"):
            with self.subTest(msg=msg):
                out = run(self.t.plan_meal("tacos", "tomorrow", confirm=True, __messages__=said(msg)))
                self.assertIn("Nothing is written", out)
        self.assertEqual(self.fake.writes(), [])

    def test_past_day_refused(self):
        out = run(self.t.plan_meal("tacos", d(-1), confirm=True, __messages__=said("ok")))
        self.assertIn("is in the past", out)
        self.assertEqual(self.fake.writes(), [])

    def test_ambiguous_recipe_asks(self):
        out = run(self.t.plan_meal("rice", "tomorrow"))
        self.assertIn("matches 2 recipes", out)
        self.assertIn("Ask which one is meant", out)

    def test_hidden_meal_plan_recipe_is_not_a_recipe(self):
        self.assertIn("no recipe is called", run(self.t.plan_meal(d(1), "tomorrow")))


class ShoppingFor(Base):
    def test_store_items_and_any_store_items_minus_the_list(self):
        out = run(self.t.shopping_for("aldi"))
        self.assertIn("- 1 x Onion (for Fried rice)", out)
        self.assertIn("- 2 x Tortillas (for Fried rice)", out)       # sold anywhere
        for other in ("Rice", "Green onion", "Cheese"):                # Costco, Trader Joe's, already on the list
            self.assertNotIn(f"x {other} ", out)
        self.assertIn("Nothing is written", out)
        self.assertEqual(self.fake.writes(), [])

    def test_ok_adds_to_the_list_with_a_note(self):
        out = run(self.t.shopping_for("Aldi", confirm=True, __messages__=said("yes, add them")))
        self.assertIn("Added 2 items", out)
        self.assertEqual(self.fake.writes(), [
            ("POST", "/api/stock/shoppinglist/add-product",
             {"product_id": 1, "list_id": 1, "product_amount": 1, "note": "Meals: Fried rice"}),
            ("POST", "/api/stock/shoppinglist/add-product",
             {"product_id": 5, "list_id": 1, "product_amount": 2, "note": "Meals: Fried rice"})])

    def test_other_store(self):
        out = run(self.t.shopping_for("costco"))
        self.assertIn("- 1 x Rice (for Chicken and rice)", out)
        self.assertNotIn("Onion", out)

    def test_nothing_planned(self):
        self.assertIn("so nothing to buy", run(self.t.shopping_for("aldi", start=d(20))))

    def test_unknown_store_asks(self):
        self.assertIn("no store is called 'Walmart'", run(self.t.shopping_for("Walmart")))


class LastHad(Base):
    def test_last_and_count(self):
        out = run(self.t.last_had("Tacos"))
        self.assertIn(f"last on the meal plan on {d(-7)} (7 days ago); 2 times", out)

    def test_future_plans_do_not_count(self):
        self.assertIn("has not been on the meal plan before", run(self.t.last_had("chicken and rice")))


class AddRecipe(Base):
    LINES = "2 cups chopped onion\n1 lb chicken breast\n½ cup green onion\n1 tsp smoked paprika\n"

    def test_preview_links_only_clear_matches(self):
        out = run(self.t.add_recipe("Skillet chicken", self.LINES, "Cook it.", "https://example.com/r"))
        self.assertIn("- 2 cups chopped onion -> Onion", out)
        self.assertIn("- 1 lb chicken breast -> Chicken breast", out)
        self.assertIn("- ½ cup green onion -> Green onion", out)
        self.assertIn("- 1 tsp smoked paprika -> no single matching product", out)
        self.assertEqual(self.fake.writes(), [])

    def test_ok_writes_recipe_and_linked_lines_only(self):
        out = run(self.t.add_recipe("Skillet chicken", self.LINES, "Cook it.", "https://example.com/r",
                                    confirm=True, __messages__=said("looks good, add it")))
        self.assertIn("Added 'Skillet chicken' with 3 linked ingredients. 1 not linked: 1 tsp smoked paprika", out)
        w = self.fake.writes()
        self.assertEqual(w[0][1], "/api/objects/recipes")
        self.assertEqual(w[0][2]["type"], "normal")
        self.assertIn("Not linked to a product:\n1 tsp smoked paprika", w[0][2]["description"])
        self.assertIn("Source: https://example.com/r", w[0][2]["description"])
        rid = self.fake.next_id - 3
        self.assertEqual([(c[1], c[2]["recipe_id"], c[2]["product_id"], c[2]["note"]) for c in w[1:]], [
            ("/api/objects/recipes_pos", rid, 1, "2 cups chopped onion"),
            ("/api/objects/recipes_pos", rid, 3, "1 lb chicken breast"),
            ("/api/objects/recipes_pos", rid, 2, "½ cup green onion")])
        self.assertFalse(any(c[1] == "/api/objects/products" for c in w))  # never invents a product

    def test_duplicate_and_empty_refused(self):
        self.assertIn("already exists", run(self.t.add_recipe("tacos", "1 tortillas")))
        self.assertIn("has no ingredients", run(self.t.add_recipe("New", "  \n ")))
        self.assertEqual(self.fake.writes(), [])

    def test_confirm_without_ok_writes_nothing(self):
        out = run(self.t.add_recipe("Skillet chicken", self.LINES, confirm=True, __messages__=said("not yet")))
        self.assertIn("Nothing is written", out)
        self.assertEqual(self.fake.writes(), [])


class Failures(Base):
    def test_no_key(self):
        self.t.valves.api_key = ""
        self.assertIn("API key is not set", run(self.t.week_plan()))

    def test_key_never_in_errors(self):
        self.t.valves.api_key = "wrong-SECRET-key"
        out = run(self.t.week_plan())
        self.assertIn("HTTP 401", out)
        self.assertNotIn("SECRET", out)

    def test_ingredient_name(self):
        self.assertEqual(tool.ingredient_name("1 1/2 cups rice"), "cups rice")
        self.assertEqual(tool.ingredient_name("½ onion"), "onion")
        self.assertEqual(tool.ingredient_name("- 2.5 lb chicken"), "lb chicken")
        self.assertEqual(tool.ingredient_name("• 3 eggs"), "eggs")
        self.assertEqual(tool.ingredient_name("salt to taste"), "salt to taste")

    def test_two_products_in_one_line_stay_unlinked(self):
        t = self.t
        out = run(t.add_recipe("Rice bowl", "1 cup rice with chicken breast"))
        self.assertIn("-> no single matching product", out)  # rice and chicken breast: never pick one


if __name__ == "__main__":
    unittest.main()
