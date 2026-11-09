"""
title: Grocy (household tracker)
author: HomeLab
version: 0.2.0
description: Read and change the household's Grocy: products, stock, the shopping list and chores.
"""
# Phase 2 of docs/household-assistant.md; runbook docs/household/phase2-chat.md.
#
# An Open WebUI Tool: Open WebUI exposes every public method of `Tools` to the model, with the text above the first
# `:param` as the tool's description (docs.openwebui.com -> Tools -> Development). The Grocy calls are plain helpers
# (the `_` methods), so they can move into an MCP server later without changing what they do.
#
# Deliberately small. It answers from Grocy and changes only what it is asked to change; it holds no opinions about
# meals, budgets or chores. Standard library HTTP (as in grocy_import.py); pydantic only for the Valves, which Open
# WebUI provides. The API key lives in the Valve and is never put in a result.
import datetime as dt
import json
import urllib.error
import urllib.request

from pydantic import BaseModel, Field

SHOPPING_LIST_ID = 1  # Grocy's default list
NEVER_DUE = "2999-12-31"  # Grocy's own "never overdue" best-before date


class GrocyError(Exception):
    """A problem worth telling the user about, as a plain sentence."""


class Tools:
    class Valves(BaseModel):
        grocy_url: str = Field(default="http://grocy:80", description="Grocy's base URL, as seen from Open WebUI")
        api_key: str = Field(default="", description="A Grocy API key made for the chat",
                             json_schema_extra={"input": {"type": "password"}})

    def __init__(self):
        self.valves = self.Valves()

    # ------------------------------------------------------------ helpers (not tools)

    def _call(self, method, path, body=None):
        if not self.valves.api_key:
            raise GrocyError("the Grocy API key is not set (Workspace > Tools > this tool > Valves)")
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
            detail = str(detail).replace(self.valves.api_key, "[key]")
            raise GrocyError(f"Grocy refused {method} {path} (HTTP {e.code}): {detail}") from None
        except (urllib.error.URLError, OSError) as e:
            raise GrocyError(f"cannot reach Grocy at {self.valves.grocy_url}: {getattr(e, 'reason', e)}") from None
        return json.loads(raw) if raw.strip() else None

    def _objects(self, entity):
        return self._call("GET", f"/objects/{entity}") or []

    def _names(self, entity):
        return {int(o["id"]): o["name"] for o in self._objects(entity)}

    def _resolve(self, entity, name, label):
        """One object by name: exact (ignoring case), else the only one containing it. Else a GrocyError listing
        the candidates, so the model asks instead of guessing."""
        want = (name or "").strip().lower()
        if not want:
            raise GrocyError(f"which {label}? No name was given")
        objs = self._objects(entity)
        exact = [o for o in objs if o["name"].strip().lower() == want]
        if len(exact) == 1:
            return exact[0]
        part = [o for o in objs if want in o["name"].lower()]
        if len(part) == 1:
            return part[0]
        if not part:
            raise GrocyError(f"no {label} is called '{name}'")
        names = ", ".join(sorted(o["name"] for o in part)[:15])
        raise GrocyError(f"'{name}' matches {len(part)} {label}s: {names}. Which one?")

    def _store_label(self, product, stores):
        sid = product.get("shopping_location_id")
        return stores.get(int(sid), "?") if sid not in (None, "") else "any store"

    def _stock_amounts(self):
        return {int(s["product_id"]): float(s["amount"]) for s in (self._call("GET", "/stock") or [])}

    def _codes(self, store_id):
        """Receipt item numbers saved for one store: {code: product id}. Codes are per store (Costco's 1767102 is
        not another store's), so one saved without a store does not count."""
        return {str(b["barcode"]).strip(): int(b["product_id"]) for b in self._objects("product_barcodes")
                if b.get("shopping_location_id") not in (None, "") and int(b["shopping_location_id"]) == store_id}

    @staticmethod
    def _date(text):
        if not (text or "").strip():
            return dt.date.today()
        try:
            return dt.date.fromisoformat(text.strip())
        except ValueError:
            raise GrocyError(f"'{text}' is not a date like 2026-11-08") from None

    @staticmethod
    def _num(x):
        x = float(x)
        return str(int(x)) if x == int(x) else str(x)

    def _run(self, fn):
        try:
            return fn()
        except GrocyError as e:
            msg = str(e)
            return f"Could not do that: {msg}" + ("" if msg.endswith(("?", ".")) else ".")

    # ------------------------------------------------------------ tools

    async def find_products(self, query: str) -> str:
        """
        Look up products by name, with their store, where they are kept, and how many are in stock.
        :param query: all or part of a product name, e.g. "cheese"
        """
        def go():
            want = query.strip().lower()
            prods = [p for p in self._objects("products") if want in p["name"].lower()]
            if not prods:
                return f"No product name contains '{query}'."
            stores, locs, stock = self._names("shopping_locations"), self._names("locations"), self._stock_amounts()
            lines = [f"- {p['name']}: store {self._store_label(p, stores)}; kept in {locs.get(int(p['location_id']), '?')}; "
                     f"in stock {self._num(stock.get(int(p['id']), 0))}" for p in sorted(prods, key=lambda p: p["name"])]
            return f"{len(prods)} product(s):\n" + "\n".join(lines)
        return self._run(go)

    async def shopping_list(self, store: str = "") -> str:
        """
        Show the shopping list. With a store, show only what to get there: that store's items plus the items any store sells.
        :param store: optional store name, e.g. "Costco"; empty for the whole list
        """
        def go():
            stores = self._names("shopping_locations")
            only = None
            if store.strip():
                only = int(self._resolve("shopping_locations", store, "store")["id"])
            prods = {int(p["id"]): p for p in self._objects("products")}
            items = [i for i in self._objects("shopping_list")
                     if int(i.get("shopping_list_id") or SHOPPING_LIST_ID) == SHOPPING_LIST_ID and not int(i.get("done") or 0)]
            lines = []
            for i in items:
                p = prods.get(int(i["product_id"])) if i.get("product_id") not in (None, "") else None
                sid = p.get("shopping_location_id") if p else None
                if only is not None and sid not in (None, "") and int(sid) != only:
                    continue
                name = p["name"] if p else (i.get("note") or "(no product)")
                note = f" ({i['note']})" if p and i.get("note") else ""
                lines.append(f"- {name} x{self._num(i.get('amount') or 1)}{note} [{self._store_label(p, stores) if p else 'any store'}]")
            where = f" for {stores[only]}" if only is not None else ""
            if not lines:
                return f"The shopping list{where} is empty."
            return f"Shopping list{where}, {len(lines)} item(s):\n" + "\n".join(sorted(lines, key=str.lower))
        return self._run(go)

    async def add_to_shopping_list(self, product: str, amount: float = 1, note: str = "") -> str:
        """
        Add a product to the shopping list.
        :param product: the product's name
        :param amount: how many, default 1
        :param note: optional note, e.g. "the big tub"
        """
        def go():
            p = self._resolve("products", product, "product")
            self._call("POST", "/stock/shoppinglist/add-product",
                       {"product_id": int(p["id"]), "list_id": SHOPPING_LIST_ID, "product_amount": float(amount), "note": note})
            return f"Added {self._num(amount)} x {p['name']} to the shopping list."
        return self._run(go)

    async def remove_from_shopping_list(self, product: str) -> str:
        """
        Take a product off the shopping list.
        :param product: the product's name
        """
        def go():
            p = self._resolve("products", product, "product")
            on = [i for i in self._objects("shopping_list") if str(i.get("product_id")) == str(p["id"])
                  and int(i.get("shopping_list_id") or SHOPPING_LIST_ID) == SHOPPING_LIST_ID]
            if not on:
                return f"{p['name']} is not on the shopping list."
            amount = sum(float(i.get("amount") or 0) for i in on) or 1
            self._call("POST", "/stock/shoppinglist/remove-product",
                       {"product_id": int(p["id"]), "list_id": SHOPPING_LIST_ID, "product_amount": amount})
            return f"Took {p['name']} off the shopping list."
        return self._run(go)

    async def record_purchase(self, product: str, amount: float = 1, store: str = "", total_paid: float = 0,
                              location: str = "", date: str = "") -> str:
        """
        Record that a product was bought: it goes into stock with the date, the store, what was paid and where it is kept. It does not change the shopping list.
        :param product: the product's name
        :param amount: how many were bought, default 1
        :param store: where it was bought, e.g. "Costco"; empty means the product's usual store, if it has one
        :param total_paid: what the receipt line cost in total, after any discount on it; 0 if unknown
        :param location: where it was put away, e.g. "Garage Freezer"; empty means the product's usual place
        :param date: the purchase date, YYYY-MM-DD (e.g. the receipt's date); empty means today
        """
        def go():
            p = self._resolve("products", product, "product")
            if float(amount) <= 0:
                raise GrocyError(f"the amount must be more than 0, not {amount}")
            # Grocy's "never overdue" date. Without one it uses the product's default best-before days, 0 for every
            # imported product, so each purchase was due the day it was bought (seen live, 2026-11-08). Real dates come
            # later, per product, once anyone wants them.
            body = {"amount": float(amount), "transaction_type": "purchase", "best_before_date": NEVER_DUE}
            where = ""
            if store.strip():
                s = self._resolve("shopping_locations", store, "store")
                body["shopping_location_id"] = int(s["id"])
                where = f" at {s['name']}"
            elif p.get("shopping_location_id") not in (None, ""):
                body["shopping_location_id"] = int(p["shopping_location_id"])
                where = f" at {self._names('shopping_locations').get(int(p['shopping_location_id']), '?')}"
            if float(total_paid) > 0:
                body["price"] = round(float(total_paid) / float(amount), 4)  # Grocy keeps a price per unit
            put = ""
            if location.strip():
                loc = self._resolve("locations", location, "location")
                body["location_id"] = int(loc["id"])
                put = f", put in {loc['name']}"
            day = self._date(date)
            if day != dt.date.today():
                body["purchased_date"] = day.isoformat()
            self._call("POST", f"/stock/products/{int(p['id'])}/add", body)
            paid = f" for {float(total_paid):.2f}" if float(total_paid) > 0 else ""
            when = "today" if day == dt.date.today() else day.isoformat()
            return f"Recorded {self._num(amount)} x {p['name']} bought {when}{where}{paid}{put}."
        return self._run(go)

    async def find_by_receipt_code(self, codes: str, store: str) -> str:
        """
        Look up receipt item numbers (the number printed before each item on a receipt) to find which products they are. A number is known only once it has been saved with save_receipt_code.
        :param codes: one or more item numbers, separated by commas, e.g. "1767102, 512599"
        :param store: the store the receipt is from, e.g. "Costco"
        """
        def go():
            s = self._resolve("shopping_locations", store, "store")
            known = self._codes(int(s["id"]))
            names = self._names("products")
            want = [c.strip() for c in codes.split(",") if c.strip()]
            if not want:
                raise GrocyError("no item numbers were given")
            lines = []
            for c in want:
                pid = known.get(c)
                lines.append(f"- {c}: {names.get(pid, f'product {pid}')}" if pid else f"- {c}: unknown at {s['name']}")
            return f"Item numbers at {s['name']}:\n" + "\n".join(lines)
        return self._run(go)

    async def save_receipt_code(self, product: str, code: str, store: str) -> str:
        """
        Remember that a receipt item number at a store is this product, so the next receipt matches it without asking. Use only after the user has confirmed the match.
        :param product: the product's name
        :param code: the item number printed on the receipt, e.g. "1767102"
        :param store: the store the receipt is from, e.g. "Costco"
        """
        def go():
            p = self._resolve("products", product, "product")
            s = self._resolve("shopping_locations", store, "store")
            c = code.strip()
            if not c:
                raise GrocyError("no item number was given")
            have = self._codes(int(s["id"])).get(c)
            if have == int(p["id"]):
                return f"{c} at {s['name']} is already saved as {p['name']}."
            if have:
                other = self._names("products").get(have, f"product {have}")
                raise GrocyError(f"{c} at {s['name']} is already saved as {other}; change it in Grocy if that is wrong")
            self._call("POST", "/objects/product_barcodes",
                       {"product_id": int(p["id"]), "barcode": c, "shopping_location_id": int(s["id"]), "note": "receipt item number"})
            return f"Saved: {c} at {s['name']} is {p['name']}."
        return self._run(go)

    async def stock(self, product: str = "") -> str:
        """
        Show what is in stock: one product, or everything with a stock amount above zero.
        :param product: optional product name; empty for everything in stock
        """
        def go():
            amounts = self._stock_amounts()
            if product.strip():
                p = self._resolve("products", product, "product")
                return f"{p['name']}: {self._num(amounts.get(int(p['id']), 0))} in stock."
            names = self._names("products")
            have = sorted((names.get(pid, f"product {pid}"), a) for pid, a in amounts.items() if a > 0)
            if not have:
                return "Nothing is recorded in stock yet."
            return f"{len(have)} product(s) in stock:\n" + "\n".join(f"- {n}: {self._num(a)}" for n, a in have)
        return self._run(go)

    async def chores_due(self, days: int = 7) -> str:
        """
        List chores that are overdue or due within the next few days, with when each was last done.
        :param days: how many days ahead to look, default 7
        """
        def go():
            names = self._names("chores")
            limit = dt.date.today() + dt.timedelta(days=int(days))
            rows = []
            for c in self._call("GET", "/chores") or []:
                nxt = (c.get("next_estimated_execution_time") or "")[:10]
                if not nxt or dt.date.fromisoformat(nxt) > limit:
                    continue
                last = (c.get("last_tracked_time") or "")[:10] or "never"
                name = c.get("chore_name") or names.get(int(c["chore_id"]), "?")
                rows.append((nxt, f"- {name}: due {nxt}; last done {last}"))
            if not rows:
                return f"No chores due in the next {days} days."
            return f"Due by {limit.isoformat()}:\n" + "\n".join(r for _, r in sorted(rows))
        return self._run(go)

    async def complete_chore(self, chore: str, date: str = "") -> str:
        """
        Record that a chore was done.
        :param chore: the chore's name
        :param date: the day it was done, YYYY-MM-DD; empty means today
        """
        def go():
            c = self._resolve("chores", chore, "chore")
            day = dt.date.today()
            if date.strip():
                try:
                    day = dt.date.fromisoformat(date.strip())
                except ValueError:
                    raise GrocyError(f"'{date}' is not a date like 2026-11-08") from None
            self._call("POST", f"/chores/{int(c['id'])}/execute", {"tracked_time": day.isoformat() + " 12:00:00"})
            return f"Recorded '{c['name']}' as done on {day.isoformat()}."
        return self._run(go)
