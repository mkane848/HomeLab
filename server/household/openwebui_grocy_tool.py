"""
title: Grocy (household tracker)
author: HomeLab
version: 0.3.4
description: Read and change the household's Grocy: products, stock, purchases and receipts, the shopping list and chores.
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
import re
import urllib.error
import urllib.request

from pydantic import BaseModel, Field

SHOPPING_LIST_ID = 1  # Grocy's default list
NEVER_DUE = "2999-12-31"  # Grocy's own "never overdue" best-before date
MAX_BACK_DAYS = 60  # a purchase dated further back is refused as a likely wrong date


class GrocyError(Exception):
    """A problem worth telling the user about, as a plain sentence."""


PRICE = re.compile(r"^(-?)\$?(\d+\.\d{2})(-?)[A-Za-z]?$")  # a tax flag may touch the price: 2.50-A (Costco)

# Whether the user's last message is an OK. 2026-11-10: the chat called record_receipt with confirm=true right after the
# user said "skip the book", twice. Open WebUI passes the chat to a tool as __messages__, so the tool checks for itself.
APPROVE = re.compile(r"\b(ok|okay|yes|yep|yeah|confirm|confirmed|approve|approved|go ahead|looks good|sounds good"
                     r"|correct|record it|record them|do it)\b", re.I)
HOLD = re.compile(r"\b(no|not|don'?t|wait|skip|wrong|change|instead|but|missing|except|stop)\b", re.I)


def user_said_ok(messages):
    """True when the last user message approves and asks for nothing else. None means no chat (called directly)."""
    if messages is None:
        return True
    last = next((m for m in reversed(messages) if isinstance(m, dict) and m.get("role") == "user"), None)
    text = (last or {}).get("content") or ""
    if isinstance(text, list):
        text = " ".join(p.get("text", "") for p in text if isinstance(p, dict))
    return bool(APPROVE.search(text)) and not HOLD.search(text)


def parse_receipt(lines):
    """Receipt lines as printed -> item dicts {code, text, price, discount}, in order. A line's first number is its
    item number and its last number its price; one-letter tax flags after the price (apart, or touching it as in 2.50-A) and a leading "E" are dropped.
    A price marked negative (10.00- or -10.00) is a discount: taken off the item it names ("/ 1234567"), else off the
    nearest item line above it. The model only copies lines; this does the arithmetic (2026-11-09: the chat put a
    discount on the wrong line and kept discount lines as items)."""
    items = []
    for raw in (lines or "").splitlines():
        t = raw.replace("*", " ").split()
        if not t:
            continue
        if t[0].upper() == "E" and len(t) > 1:
            t = t[1:]
        while len(t) > 1 and len(t[-1]) == 1 and t[-1].isalpha():
            t = t[:-1]
        m = PRICE.match(t[-1]) if t else None
        if len(t) < 2 or not t[0].isdigit() or not m:
            raise GrocyError(f"cannot read the receipt line '{raw.strip()}': expected an item number first and a price "
                             "last, as printed. Do not skip or change the line yourself: show it to the user and ask")
        amount = float(m.group(2))
        text = " ".join(t[1:-1])
        if m.group(1) or m.group(3):
            ref = re.search(r"/\s*(\d+)", text)
            if ref:
                want = ref.group(1).lstrip("0")
                hits = [i for i in items if i["code"].lstrip("0") == want]
                if not hits and len(want) >= 5:
                    # A digit lost reading the photo ("/1234567" read as "/ 234567", 2026-11-10): accept the one
                    # item above whose number ends with it. Two such items is ambiguous and stays an error.
                    ends = [i for i in items if i["code"].lstrip("0").endswith(want)]
                    hits = ends if len(ends) == 1 else []
                if not hits:
                    raise GrocyError(f"the discount line '{raw.strip()}' names item {ref.group(1)}, which is not above it")
                target = hits[-1]
            elif items:
                target = items[-1]
            else:
                raise GrocyError(f"the discount line '{raw.strip()}' has no item line above it")
            target["discount"] = round(target["discount"] + amount, 2)
            continue
        items.append({"code": t[0], "text": text, "price": amount, "discount": 0.0})
    if not items:
        raise GrocyError("no receipt lines were given")
    for i in items:
        if i["discount"] > i["price"]:
            raise GrocyError(f"the discounts on {i['code']} {i['text']} add up to more than its price")
    return items


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
        part = self._containing(objs, want)
        if len(part) == 1:
            return part[0]
        if not part:
            raise GrocyError(f"no {label} is called '{name}'")
        names = ", ".join(sorted(o["name"] for o in part)[:15])
        raise GrocyError(f"'{name}' matches {len(part)} {label}s: {names}. Which one?")

    @staticmethod
    def _containing(objs, want):
        """Objects whose name contains `want`; if none, the same with a plural ending dropped ("yogurts" finds the
        yogurts, "cookies" the cookie, "tomatoes" the tomato)."""
        tries = [want] + [want[:-n] for n in (2, 1) if want.endswith("es"[-n:]) and len(want) > n + 2]
        for w in tries:
            found = [o for o in objs if w in o["name"].lower()]
            if found:
                return found
        return []

    def _store_label(self, product, stores):
        sid = product.get("shopping_location_id")
        return stores.get(int(sid), "?") if sid not in (None, "") else "any store"

    def _stock_amounts(self):
        return {int(s["product_id"]): float(s["amount"]) for s in (self._call("GET", "/stock") or [])}

    def _codes(self, store_id):
        """Receipt item numbers saved for one store: {code: product id}. Codes are per store (Costco's 1234567 is
        not another store's), so one saved without a store does not count."""
        return {str(b["barcode"]).strip(): int(b["product_id"]) for b in self._objects("product_barcodes")
                if b.get("shopping_location_id") not in (None, "") and int(b["shopping_location_id"]) == store_id}

    @staticmethod
    def _date(text):
        """A purchase date: empty is today; YYYY-MM-DD, or MM/DD/YYYY as US receipts print it. A date in the future
        or more than MAX_BACK_DAYS ago is refused: a chat once recorded a purchase with an invented date (2026-11-09)."""
        t = (text or "").strip()
        if not t:
            return dt.date.today()
        try:
            if "/" in t:
                m, d, y = (int(x) for x in t.split("/"))
                day = dt.date(y + 2000 if y < 100 else y, m, d)
            else:
                day = dt.date.fromisoformat(t)
        except ValueError:
            raise GrocyError(f"'{text}' is not a date like 2026-11-08 or 11/08/2026") from None
        today = dt.date.today()
        if day > today or (today - day).days > MAX_BACK_DAYS:
            raise GrocyError(f"{day.isoformat()} looks wrong for a purchase (in the future, or more than "
                             f"{MAX_BACK_DAYS} days ago). Ask the user for the date")
        return day

    def _purchase(self, p, amount, store, total_paid, location, day):
        """Put one purchase into stock. p, store and location are Grocy objects (store and location may be None);
        returns the sentence parts (store, paid, put) for the reply."""
        if float(amount) <= 0:
            raise GrocyError(f"the amount must be more than 0, not {amount}")
        # Grocy's "never overdue" date. Without one it uses the product's default best-before days, 0 for every
        # imported product, so each purchase was due the day it was bought (seen live, 2026-11-08). Real dates come
        # later, per product, once anyone wants them.
        body = {"amount": float(amount), "transaction_type": "purchase", "best_before_date": NEVER_DUE}
        where = ""
        if store is not None:
            body["shopping_location_id"] = int(store["id"])
            where = f" at {store['name']}"
        elif p.get("shopping_location_id") not in (None, ""):
            body["shopping_location_id"] = int(p["shopping_location_id"])
            where = f" at {self._names('shopping_locations').get(int(p['shopping_location_id']), '?')}"
        if float(total_paid) > 0:
            body["price"] = round(float(total_paid) / float(amount), 4)  # Grocy keeps a price per unit
        put = ""
        if location is not None:
            body["location_id"] = int(location["id"])
            put = f", put in {location['name']}"
        if day != dt.date.today():
            body["purchased_date"] = day.isoformat()
        self._call("POST", f"/stock/products/{int(p['id'])}/add", body)
        paid = f" for {float(total_paid):.2f}" if float(total_paid) > 0 else ""
        return where, paid, put

    def _purchases(self, product_id):
        """The product's purchases in the stock log that are not undone, newest recorded first."""
        rows = [r for r in self._objects("stock_log") if int(r["product_id"]) == product_id
                and r.get("transaction_type") == "purchase" and not int(r.get("undone") or 0)]
        return sorted(rows, key=lambda r: int(r["id"]), reverse=True)

    def _describe(self, r, stores, locs):
        sid, lid = r.get("shopping_location_id"), r.get("location_id")
        where = f"at {stores.get(int(sid), '?')}" if sid not in (None, "") else "store not recorded"
        price = f" for {float(r['price']) * float(r['amount']):.2f}" if r.get("price") not in (None, "") else ""
        put = f", put in {locs.get(int(lid), '?')}" if lid not in (None, "") else ""
        return f"bought {(r.get('purchased_date') or '?')[:10]} {where}{price} ({self._num(r['amount'])}){put}"

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
            prods = self._containing(self._objects("products"), query.strip().lower())
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
        :param date: the purchase date, YYYY-MM-DD (e.g. the receipt's date); empty means today. Never guess it
        """
        def go():
            p = self._resolve("products", product, "product")
            s = self._resolve("shopping_locations", store, "store") if store.strip() else None
            loc = self._resolve("locations", location, "location") if location.strip() else None
            day = self._date(date)
            where, paid, put = self._purchase(p, amount, s, total_paid, loc, day)
            when = "today" if day == dt.date.today() else day.isoformat()
            return f"Recorded {self._num(amount)} x {p['name']} bought {when}{where}{paid}{put}."
        return self._run(go)

    async def last_purchases(self, product: str, count: int = 3) -> str:
        """
        Show when, where and for how much a product was last bought, from the purchase history. Use this for any question about when or where something was bought.
        :param product: the product's name
        :param count: how many recent purchases to show, default 3
        """
        def go():
            p = self._resolve("products", product, "product")
            rows = self._purchases(int(p["id"]))
            if not rows:
                return f"No purchase of {p['name']} is recorded."
            stores, locs = self._names("shopping_locations"), self._names("locations")
            rows = sorted(rows, key=lambda r: ((r.get("purchased_date") or "")[:10], int(r["id"])), reverse=True)
            shown = rows[:max(1, int(count))]
            return (f"{p['name']}, the last {len(shown)} of {len(rows)} purchase(s):\n"
                    + "\n".join(f"- {self._describe(r, stores, locs)}" for r in shown))
        return self._run(go)

    async def undo_last_purchase(self, product: str, confirm: bool = False, __messages__: list = None) -> str:
        """
        Undo the most recently recorded purchase of a product, to correct a mistake. There is no edit: to fix a purchase, undo it and record it again. First call without confirm to see which purchase it would undo, tell the user, and call again with confirm=true only after they say OK.
        :param product: the product's name
        :param confirm: false shows which purchase would be undone and changes nothing; true undoes it
        """
        def go():
            p = self._resolve("products", product, "product")
            rows = self._purchases(int(p["id"]))
            if not rows:
                return f"No purchase of {p['name']} is recorded, so there is nothing to undo."
            r = rows[0]
            what = f"{p['name']} {self._describe(r, self._names('shopping_locations'), self._names('locations'))}"
            if not confirm or not user_said_ok(__messages__):
                held = "" if not confirm else " The user's last message is not an OK, so nothing was undone."
                return (f"This would undo: {what}. Nothing changed yet;{held} ask the user, and call again with "
                        "confirm=true after OK.")
            self._call("POST", f"/stock/bookings/{int(r['id'])}/undo")
            return f"Undid: {what}."
        return self._run(go)

    async def find_by_receipt_code(self, codes: str, store: str) -> str:
        """
        Look up receipt item numbers (the number printed before each item on a receipt) to find which products they are. A number is known only once it has been saved with save_receipt_code.
        :param codes: one or more item numbers, separated by commas, e.g. "1234567, 7654321"
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
        :param code: the item number printed on the receipt, e.g. "1234567"
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

    async def record_receipt(self, store: str, date: str, lines: str, items_sold: int = 0, skip: str = "",
                             matches: str = "", confirm: bool = False, __messages__: list = None) -> str:
        """
        Record a receipt. Copy every item line and every discount line exactly as printed, one per line; this tool matches the item numbers, applies each discount to its item, leaves out skipped lines and adds up the total. Without confirm it only shows the list: show that list to the user unchanged. Call again with confirm=true only after the user says OK.
        :param store: the store the receipt is from, e.g. "Costco"
        :param date: the date as printed on the receipt, e.g. "11/08/2026"
        :param lines: the item lines and discount lines, one per line, exactly as printed, e.g. "1234567 KS ITEM 9.99 A"
        :param items_sold: the "Items Sold" count printed on the receipt; 0 if there is none
        :param skip: item numbers or words of lines the user does not want recorded, separated by commas
        :param matches: products for item numbers that came back unknown, as the user named them: "1234567=Product name; 7654321=Other product"
        :param confirm: false shows the list and writes nothing; true records the purchases and saves the matched item numbers
        """
        def go():
            s = self._resolve("shopping_locations", store, "store")
            day = self._date(date)
            items = parse_receipt(lines)
            # A skip is an item number, words of the line, or both ("1234567 GAME"). One naming an item number that
            # is not among the lines (the chat left the line out) still counts as a line read, against Items Sold.
            def hit(w, i):
                code, _, words = w.partition(" ") if w.split()[0].isdigit() else ("", "", w)
                if code:
                    return code.lstrip("0") == i["code"].lstrip("0")
                return words.strip() in i["text"].lower()
            wants = [w.strip().lower() for w in skip.split(",") if w.strip()]
            skipped = [i for i in items if any(hit(w, i) for w in wants)]
            absent = [w for w in wants if w.split()[0].isdigit() and not any(hit(w, i) for i in items)]
            missed = [w for w in wants if not w.split()[0].isdigit() and not any(hit(w, i) for i in items)]
            keep = [i for i in items if i not in skipped]
            known = self._codes(int(s["id"]))
            names = {int(p["id"]): p for p in self._objects("products")}
            given = {}
            for pair in re.split(r"[;\n]", matches or ""):
                if pair.strip():
                    code, _, name = pair.partition("=")
                    if not name.strip():
                        raise GrocyError(f"'{pair.strip()}' is not like 1234567=Product name")
                    try:
                        p = self._resolve("products", name, "product")
                    except GrocyError as e:
                        raise GrocyError(f"{e} For {code.strip()}: ask the user for the product's exact name, or, if they "
                                         f"do not want that line recorded, put {code.strip()} in skip")
                    have = known.get(code.strip())
                    if have and have != int(p["id"]):
                        raise GrocyError(f"{code.strip()} at {s['name']} is already saved as "
                                         f"{names.get(have, {}).get('name', have)}; change it in Grocy if that is wrong")
                    given[code.strip()] = p
            for i in keep:
                p = given.get(i["code"]) or names.get(known.get(i["code"]))
                i["product"], i["paid"] = p, round(i["price"] - i["discount"], 2)
            unknown = [i for i in keep if i["product"] is None]

            def row(n, i):
                prod = i["product"]["name"] if i["product"] else "UNKNOWN: ask the user which product, or to skip it"
                disc = f" (after a {i['discount']:.2f} discount)" if i["discount"] else ""
                return f"{n}. {i['code']} {i['text']} -> {prod}, 1, {i['paid']:.2f}{disc}"

            read = len(items) + len(absent)
            head = f"Receipt: {s['name']}, {day.isoformat()}. Item lines read: {read}"
            head += f" (Items Sold printed: {items_sold})" if int(items_sold or 0) else ""
            head += "." if int(items_sold or 0) in (0, read) else ". The counts differ: ask the user whether a line is missing."
            body = [head] + [row(n, i) for n, i in enumerate(keep, 1)]
            if skipped or absent:
                body.append("Skipped: " + "; ".join([f"{i['code']} {i['text']}" for i in skipped] + [w.upper() for w in absent]))
            body.append(f"Total paid for these {len(keep)}: {sum(i['paid'] for i in keep):.2f}")
            held = confirm and not unknown and not user_said_ok(__messages__)
            if not confirm or unknown or held:
                if held:
                    body.append("Not written: the user's last message is not an OK. Show this list and wait for OK.")
                if missed:
                    body.append(f"Skip matched no line: {', '.join(repr(w) for w in missed)}. Skip takes the item number "
                                "as printed (e.g. 2076209) or words from the receipt text.")
                if unknown:
                    codes = ", ".join(i["code"] for i in unknown)
                    body.append(f"{len(unknown)} line(s) unknown ({codes}). Ask the user, for each one, which product it "
                                "is or whether to skip it. Then call again: matches='<code>=<product name>' for the ones "
                                "they name, and skip='<code>' for the ones they skip.")
                body.append("Nothing written yet." + ("" if unknown or held else " Show this list to the user and wait for OK."))
                return "\n".join(body)
            # The writes. A line already in Grocy (same product, date, store and price, not undone) is not written
            # again, so a second OK records nothing twice; two identical lines on one receipt still count as two.
            log = [r for r in self._objects("stock_log") if r.get("transaction_type") == "purchase" and not int(r.get("undone") or 0)]
            def same(r, i):
                return (int(r["product_id"]) == int(i["product"]["id"]) and (r.get("purchased_date") or "")[:10] == day.isoformat()
                        and str(r.get("shopping_location_id")) == str(s["id"])
                        and (abs(float(r["price"]) - i["paid"]) < 0.005 if r.get("price") not in (None, "") else not i["paid"]))
            done, already, saved = [], [], []
            try:
                for i in keep:
                    have = [r for r in log if same(r, i)]
                    if have:
                        log.remove(have[0])
                        already.append(i["product"]["name"])
                        continue
                    self._purchase(i["product"], 1, s, i["paid"], None, day)
                    done.append(f"{i['product']['name']} {i['paid']:.2f}")
                for code, p in given.items():
                    if known.get(code) != int(p["id"]) and any(i["code"] == code for i in keep):
                        self._call("POST", "/objects/product_barcodes", {"product_id": int(p["id"]), "barcode": code,
                                                                        "shopping_location_id": int(s["id"]), "note": "receipt item number"})
                        saved.append(f"{code}={p['name']}")
            except GrocyError as e:
                return (f"Stopped part way: {e}. Recorded before that: {'; '.join(done) or 'nothing'}. "
                        f"Saved item numbers: {', '.join(saved) or 'none'}.")
            out = [f"Recorded {len(done)} purchase(s) at {s['name']} dated {day.isoformat()}: {'; '.join(done) or 'none'}."]
            if already:
                out.append(f"Already recorded, so not written again: {', '.join(already)}.")
            out.append(f"Saved item numbers: {', '.join(saved) or 'none new'}.")
            return " ".join(out)
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
