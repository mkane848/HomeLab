"""
title: Meals (recipes, meal plan, shopping)
author: household assistant (docs/household/meals-agent.md)
version: 0.1.0
description: What can we make with what is in the house, the week's meal plan, the shopping for it per store, when we last had a dish, and adding a recipe. Recipes, stock, the plan and the list all live in Grocy.
"""
# The Meals Homie (docs/homies.md, docs/household/meals-agent.md). One tool file, as Open WebUI loads it; it shares
# its patterns with the Health tool and the house tool, copied rather than imported because each tool is uploaded on
# its own. Grocy does the arithmetic (what is in stock, what a recipe is missing); the model only chooses and words.
#
# Grocy's tables, read in its source 2026-11-19 (docs/references.md, "Meals"): recipes (name, description, type,
# base_servings), recipes_pos (recipe_id, product_id, amount, note), meal_plan (day, type, recipe_id,
# recipe_servings, note), the view recipes_pos_resolved (per recipe and product: product_name, need_fulfilled,
# missing_amount, amount_on_shopping_list), and GET /recipes/fulfillment. Grocy also keeps hidden recipes for meal
# plan days and weeks (type mealplan-day, mealplan-week, mealplan-shadow): only type "normal" recipes are shown.
import datetime as dt
import json
import re
import urllib.error
import urllib.request

from pydantic import BaseModel, Field

SHOPPING_LIST_ID = 1  # Grocy's default list, as the house tool uses
NORMAL = ("", "normal")  # recipe types the household made; the rest are Grocy's own meal plan bookkeeping
NOTE_PREFIX = "Meals:"

# The user's own OK, checked by the tool (as in the house and Health tools).
APPROVE = re.compile(r"\b(ok|okay|yes|yep|yeah|confirm|confirmed|approve|approved|go ahead|looks good|sounds good"
                     r"|correct|do it|add it|add them|plan it|save it)\b", re.I)
HOLD = re.compile(r"\b(no|not|don'?t|wait|skip|wrong|change|instead|but|missing|except|stop)\b", re.I)
AMOUNT = re.compile(r"^\s*(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?|[½⅓⅔¼¾⅛])\s*")


class MealsError(Exception):
    """A problem worth telling the user about, as a plain sentence."""


def user_said_ok(messages):
    """True when the last user message approves and asks for nothing else. None means no chat (called directly)."""
    if messages is None:
        return True
    last = next((m for m in reversed(messages) if isinstance(m, dict) and m.get("role") == "user"), None)
    text = (last or {}).get("content") or ""
    if isinstance(text, list):
        text = " ".join(p.get("text", "") for p in text if isinstance(p, dict))
    return bool(APPROVE.search(text)) and not HOLD.search(text)


def ingredient_name(line):
    """'2 cups chopped onion' -> 'cups chopped onion'; the quantity stays in the line's own text."""
    return AMOUNT.sub("", (line or "").strip().lstrip("-•*").strip()).strip()


class Tools:
    class Valves(BaseModel):
        grocy_url: str = Field(default="http://grocy:80", description="Grocy's base URL, as seen from Open WebUI")
        api_key: str = Field(default="", description="A Grocy API key made for the chat",
                             json_schema_extra={"input": {"type": "password"}})

    def __init__(self):
        self.valves = self.Valves()

    # ------------------------------------------------------------ helpers (not tools)

    def _scrub(self, text):
        return str(text).replace(self.valves.api_key, "[secret]") if self.valves.api_key else str(text)

    def _call(self, method, path, body=None):
        if not self.valves.api_key:
            raise MealsError("the Grocy API key is not set (Workspace > Tools > Meals > Valves)")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.valves.grocy_url.rstrip("/") + "/api" + path, data=data, method=method)
        req.add_header("GROCY-API-KEY", self.valves.api_key)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:200]
            try:
                detail = json.loads(detail).get("error_message", detail)
            except (ValueError, AttributeError):
                pass
            raise MealsError(f"Grocy refused {method} {path} (HTTP {e.code}): {self._scrub(detail)}") from None
        except (urllib.error.URLError, OSError) as e:
            raise MealsError(f"cannot reach Grocy: {self._scrub(getattr(e, 'reason', e))}") from None
        return json.loads(raw) if raw.strip() else None

    def _objects(self, entity):
        return self._call("GET", f"/objects/{entity}") or []

    def _recipes(self):
        return [r for r in self._objects("recipes") if (r.get("type") or "") in NORMAL]

    @staticmethod
    def _match(objs, name, label):
        """One object by name: exact (ignoring case), else the only one containing it. Else a MealsError listing the
        candidates, so the model asks instead of guessing."""
        want = (name or "").strip().lower()
        if not want:
            raise MealsError(f"which {label}? No name was given")
        exact = [o for o in objs if o["name"].strip().lower() == want]
        if len(exact) == 1:
            return exact[0]
        part = [o for o in objs if want in o["name"].lower()]
        if len(part) == 1:
            return part[0]
        if not part:
            raise MealsError(f"no {label} is called '{name}'. Ask which one is meant")
        names = ", ".join(sorted(o["name"] for o in part)[:15])
        raise MealsError(f"'{name}' matches {len(part)} {label}s: {names}. Ask which one is meant")

    def _recipe(self, name):
        return self._match(self._recipes(), name, "recipe")

    def _store(self, name):
        return self._match(self._objects("shopping_locations"), name, "store")

    @staticmethod
    def _date(text, label="date"):
        text = (text or "").strip().lower()
        today = dt.date.today()
        if text in ("", "today", "tonight"):
            return today
        if text == "tomorrow":
            return today + dt.timedelta(days=1)
        try:
            return dt.date.fromisoformat(text)
        except ValueError:
            raise MealsError(f"'{text}' is not a {label}: use YYYY-MM-DD, today or tomorrow") from None

    @staticmethod
    def _num(x):
        x = float(x or 0)
        return str(int(x)) if x == int(x) else f"{x:g}"

    def _missing(self, recipe_ids):
        """{recipe_id: [(product_id, product_name, still_needed)]} for ingredients not in stock and not already on
        the shopping list (Grocy's own numbers)."""
        out = {}
        for p in self._objects("recipes_pos_resolved"):
            rid = int(p.get("recipe_id") or 0)
            if rid not in recipe_ids or int(p.get("need_fulfilled") or 0):
                continue
            need = float(p.get("missing_amount") or 0) - float(p.get("amount_on_shopping_list") or 0)
            if need > 0:
                out.setdefault(rid, []).append((int(p["product_id"]), p.get("product_name") or "?", need))
        return out

    def _week(self, start):
        first = self._date(start, "start date")
        last = first + dt.timedelta(days=6)
        rows = []
        for m in self._objects("meal_plan"):
            try:
                day = dt.date.fromisoformat(str(m.get("day"))[:10])
            except ValueError:
                continue
            if first <= day <= last:
                rows.append((day, m))
        return first, last, sorted(rows, key=lambda x: (x[0], int(x[1].get("id") or 0)))

    def _run(self, fn):
        try:
            return fn()
        except MealsError as e:
            msg = str(e)
            return f"Could not do that: {msg}" + ("" if msg.endswith(("?", ".")) else ".")

    # ------------------------------------------------------------ tools

    async def what_can_we_make(self, max_missing: int = 2) -> str:
        """
        List the household's recipes that can be made with what is in the house now, then those missing only a few
        ingredients, naming what is missing.
        :param max_missing: also list recipes missing up to this many ingredients, default 2
        """
        def go():
            recipes = {int(r["id"]): r for r in self._recipes()}
            if not recipes:
                return "There are no recipes in Grocy yet."
            ful = {int(f["recipe_id"]): f for f in self._call("GET", "/recipes/fulfillment") or []
                   if int(f.get("recipe_id") or 0) in recipes}
            ready = sorted(recipes[r]["name"] for r, f in ful.items() if int(f.get("need_fulfilled") or 0))
            near_ids = [r for r, f in ful.items() if not int(f.get("need_fulfilled") or 0)
                        and 0 < int(f.get("missing_products_count") or 0) <= int(max_missing)]
            missing = self._missing(set(near_ids))
            lines = ["Ready to make now: " + (", ".join(ready) if ready else "nothing, with what is in stock")]
            near = sorted(near_ids, key=lambda r: (int(ful[r]["missing_products_count"]), recipes[r]["name"]))
            for r in near:
                names = ", ".join(n for _, n, _ in missing.get(r, [])) or f"{ful[r]['missing_products_count']} items"
                lines.append(f"- {recipes[r]['name']}: missing {names}")
            if near:
                lines.insert(1, f"Missing up to {int(max_missing)}:")
            return "\n".join(lines)
        return self._run(go)

    async def week_plan(self, start: str = "") -> str:
        """
        Show the meal plan for seven days.
        :param start: the first day, YYYY-MM-DD, today or tomorrow; empty means today
        """
        def go():
            first, last, rows = self._week(start)
            if not rows:
                return f"Nothing is planned from {first.isoformat()} to {last.isoformat()}."
            names = {int(r["id"]): r["name"] for r in self._objects("recipes")}
            out = [f"Meal plan {first.isoformat()} to {last.isoformat()}:"]
            for day, m in rows:
                what = names.get(int(m.get("recipe_id") or 0)) if (m.get("type") or "recipe") == "recipe" else None
                out.append(f"- {day.isoformat()} ({day.strftime('%a')}): {what or m.get('note') or '(a note)'}")
            return "\n".join(out)
        return self._run(go)

    async def plan_meal(self, recipe: str, date: str = "today", confirm: bool = False,
                        __messages__: list = None) -> str:
        """
        Put a recipe on the meal plan for a day. Call it first with confirm false and show the user what it will plan;
        call it again with confirm true only after the user says OK.
        :param recipe: the recipe's name, as in the household's recipes
        :param date: the day, YYYY-MM-DD, today or tomorrow
        :param confirm: true only after the user said OK to this plan
        """
        def go():
            r = self._recipe(recipe)
            day = self._date(date)
            if day < dt.date.today():
                raise MealsError(f"{day.isoformat()} is in the past; plan today or later")
            what = f"{r['name']} on {day.isoformat()} ({day.strftime('%A')})"
            if not (confirm and user_said_ok(__messages__)):
                return f"Ready to plan {what}. Nothing is written until the user says OK."
            self._call("POST", "/objects/meal_plan", {"day": day.isoformat(), "type": "recipe",
                                                      "recipe_id": int(r["id"]),
                                                      "recipe_servings": int(r.get("base_servings") or 1)})
            return f"Planned {what}."
        return self._run(go)

    async def shopping_for(self, store: str, start: str = "", confirm: bool = False,
                           __messages__: list = None) -> str:
        """
        Work out what to buy at one store for the week's meal plan: the planned recipes' ingredients that are not in
        stock and not already on the shopping list, for products bought at that store or at any store. Call it first
        with confirm false and show the user the list; call it again with confirm true only after the user says OK,
        to put them on the shopping list.
        :param store: the store, as in Grocy's stores
        :param start: the plan's first day, YYYY-MM-DD; empty means today
        :param confirm: true only after the user said OK to this list
        """
        def go():
            s = self._store(store)
            first, last, rows = self._week(start)
            planned = {int(m["recipe_id"]) for _, m in rows if (m.get("type") or "recipe") == "recipe"
                       and m.get("recipe_id") not in (None, "")}
            if not planned:
                return f"Nothing is planned from {first.isoformat()} to {last.isoformat()}, so nothing to buy."
            names = {int(r["id"]): r["name"] for r in self._objects("recipes")}
            products = {int(p["id"]): p for p in self._objects("products")}
            want = {}
            for rid, items in self._missing(planned).items():
                for pid, pname, need in items:
                    sid = (products.get(pid) or {}).get("shopping_location_id")
                    if sid not in (None, "") and int(sid) != int(s["id"]):
                        continue
                    amount, used = want.get(pid, (0, pname, []))[0], want.get(pid, (0, pname, []))[2]
                    want[pid] = (amount + need, pname, used + [names.get(rid, "?")])
            if not want:
                return f"Nothing to buy at {s['name']} for {first.isoformat()} to {last.isoformat()}."
            lines = [f"- {self._num(a)} x {n} (for {', '.join(sorted(set(u)))})" for _, (a, n, u)
                     in sorted(want.items(), key=lambda x: x[1][1].lower())]
            head = f"For the plan {first.isoformat()} to {last.isoformat()}, at {s['name']}:"
            if not (confirm and user_said_ok(__messages__)):
                return head + "\n" + "\n".join(lines) + "\nReady to add these to the shopping list. Nothing is " \
                                                         "written until the user says OK."
            for pid, (amount, _, used) in sorted(want.items()):
                self._call("POST", "/stock/shoppinglist/add-product",
                           {"product_id": pid, "list_id": SHOPPING_LIST_ID, "product_amount": amount,
                            "note": f"{NOTE_PREFIX} {', '.join(sorted(set(used)))}"})
            return f"Added {len(want)} items to the shopping list for {s['name']}:\n" + "\n".join(lines)
        return self._run(go)

    async def last_had(self, recipe: str) -> str:
        """
        Say when a recipe was last on the meal plan, so meals do not repeat too often.
        :param recipe: the recipe's name
        """
        def go():
            r = self._recipe(recipe)
            today = dt.date.today()
            days = sorted(str(m.get("day"))[:10] for m in self._objects("meal_plan")
                          if str(m.get("recipe_id")) == str(r["id"]) and str(m.get("day"))[:10] <= today.isoformat())
            if not days:
                return f"{r['name']} has not been on the meal plan before."
            ago = (today - dt.date.fromisoformat(days[-1])).days
            return f"{r['name']} was last on the meal plan on {days[-1]} ({ago} days ago); {len(days)} times in all."
        return self._run(go)

    async def add_recipe(self, name: str, ingredients: str, steps: str = "", source: str = "",
                         confirm: bool = False, __messages__: list = None) -> str:
        """
        Add a recipe the user sent (a file or a link) to the household's recipes. Each ingredient is linked to a Grocy
        product only when one product clearly matches; the others are kept in the recipe's text and listed, never made
        up. Call it first with confirm false and show the user what it will add; call it again with confirm true only
        after the user says OK.
        :param name: the recipe's name
        :param ingredients: the ingredients, one per line, as written in the recipe
        :param steps: the method, as written
        :param source: where it came from (a link, or the file's name)
        :param confirm: true only after the user said OK to this recipe
        """
        def go():
            title = (name or "").strip()
            if not title:
                raise MealsError("the recipe needs a name")
            if any(r["name"].strip().lower() == title.lower() for r in self._recipes()):
                raise MealsError(f"a recipe called '{title}' already exists")
            lines = [ln.strip() for ln in re.split(r"[\r\n]+", ingredients or "") if ln.strip()]
            if not lines:
                raise MealsError("the recipe has no ingredients")
            products = self._objects("products")
            linked, loose = [], []
            for ln in lines:
                try:
                    p = self._match(products, ingredient_name(ln), "product")
                    linked.append((ln, p))
                except MealsError:
                    # the product's own name inside the line ("2 cups chopped onion" -> Onion), only if exactly one
                    hits = [p for p in products
                            if re.search(r"\b" + re.escape(p["name"].lower()) + r"s?\b", ln.lower())]
                    # the more specific name wins when one sits inside another ("green onion" over "onion")
                    hits = [p for p in hits if not any(p is not q and p["name"].lower() in q["name"].lower()
                                                       for q in hits)]
                    if len(hits) == 1:
                        linked.append((ln, hits[0]))
                    else:
                        loose.append(ln)
            preview = [f"Recipe '{title}'" + (f" from {source}" if source else "") + ":"]
            preview += [f"- {ln} -> {p['name']}" for ln, p in linked]
            preview += [f"- {ln} -> no single matching product; kept as text only" for ln in loose]
            if not (confirm and user_said_ok(__messages__)):
                return "\n".join(preview) + "\nReady to add it. Nothing is written until the user says OK."
            desc = (steps or "").strip()
            if loose:
                desc += "\n\nNot linked to a product:\n" + "\n".join(loose)
            if source:
                desc += f"\n\nSource: {source}"
            res = self._call("POST", "/objects/recipes", {"name": title, "description": desc.strip(),
                                                          "base_servings": 1, "desired_servings": 1,
                                                          "type": "normal"})
            rid = int(res["created_object_id"])
            for ln, p in linked:
                self._call("POST", "/objects/recipes_pos", {"recipe_id": rid, "product_id": int(p["id"]),
                                                            "amount": 1, "note": ln})
            tail = f" {len(loose)} not linked: {', '.join(loose)}." if loose else ""
            return f"Added '{title}' with {len(linked)} linked ingredients.{tail}"
        return self._run(go)
