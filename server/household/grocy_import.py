#!/usr/bin/env python3
"""Load the household's seed lists into Grocy through its REST API.

Phase 1 of docs/household-assistant.md; runbook: docs/household/phase1.md.

The data never lives in this repo. The CSVs sit in a folder on the server (default
~/household-data/), and this script only knows their columns:

  chores.csv    name, cadence, last_done, assignee, description
  products.csv  name, stores, location, description

cadence is one of: weekly | every N weeks | monthly | quarterly | every N months |
yearly | every N years | adaptive | manual. last_done is YYYY-MM-DD or empty.
assignee is a Grocy username, "rotate" (everyone, who did it least goes next) or empty.
stores is "Store A + Store B" (the first one is the product's store; the rest go in the
description). location is a Grocy location name, default "Pantry".

Dry run by default: it reads Grocy, prints what it would create, and writes nothing.
--apply writes. Matching is by name (case-insensitive), so a second --apply creates
nothing new. The API key comes from GROCY_API_KEY or --key-file and is never printed.

Standard library only:  python3 -I server/household/grocy_import.py --url http://localhost:9283
"""
import argparse
import csv
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_DATA = os.path.expanduser("~/household-data")
DEFAULT_KEY_FILE = os.path.expanduser("~/.config/household/grocy-api-key")
DEFAULT_LOCATION = "Pantry"
DEFAULT_UNIT = "Piece"
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


class InputError(Exception):
    """A problem with the input or the server, reported without a traceback."""


# ---------------------------------------------------------------- cadence → Grocy

def parse_cadence(text):
    """Return (period_type, period_interval) for a cadence phrase."""
    t = (text or "").strip().lower()
    fixed = {
        "weekly": ("weekly", 1), "biweekly": ("weekly", 2), "fortnightly": ("weekly", 2),
        "monthly": ("monthly", 1), "quarterly": ("monthly", 3),
        "yearly": ("yearly", 1), "annually": ("yearly", 1),
        "adaptive": ("adaptive", 1), "manual": ("manually", 1), "": ("manually", 1),
    }
    if t in fixed:
        return fixed[t]
    m = re.fullmatch(r"every (\d+) (week|month|year)s?", t)
    if m and int(m.group(1)) > 0:
        kind = {"week": "weekly", "month": "monthly", "year": "yearly"}[m.group(2)]
        return kind, int(m.group(1))
    raise InputError(f"unknown cadence {text!r}: use weekly, every N weeks, monthly, quarterly, "
                       "every N months, yearly, every N years, adaptive or manual")


def parse_date(text):
    t = (text or "").strip()
    if not t:
        return None
    try:
        return dt.date.fromisoformat(t)
    except ValueError:
        raise InputError(f"last_done {text!r} is not YYYY-MM-DD") from None


def chore_payload(row, users):
    """The Grocy chore object for one chores.csv row (no id)."""
    period_type, interval = parse_cadence(row.get("cadence"))
    last = parse_date(row.get("last_done"))
    anchor = last or dt.date.today()
    payload = {
        "name": row["name"].strip(),
        "description": (row.get("description") or "").strip(),
        "period_type": period_type,
        "period_interval": interval,
        "track_date_only": 1,
        "rollover": 0,
        "start_date": anchor.isoformat() + " 00:00:00",
        "assignment_type": "no-assignment",
    }
    if period_type == "weekly":
        # Grocy picks the next listed weekday after the last execution.
        payload["period_config"] = WEEKDAYS[anchor.weekday()]
    elif period_type == "monthly":
        # Day of the month; capped at 28 so short months don't push it into the next one.
        payload["period_days"] = min(anchor.day, 28)
    who = (row.get("assignee") or "").strip()
    if who:
        if who.lower() == "rotate":
            ids = sorted(users.values())
            payload["assignment_type"] = "who-least-did-first"
        else:
            if who.lower() not in users:
                raise InputError(f"assignee {who!r} for {payload['name']!r} is not a Grocy user "
                                   f"(known: {', '.join(sorted(users)) or 'none'})")
            ids = [users[who.lower()]]
            payload["assignment_type"] = "in-alphabetical-order"
        if not ids:
            raise InputError("assignee 'rotate' needs at least one Grocy user")
        payload["assignment_config"] = ",".join(str(i) for i in ids)
    return payload, last


def product_payload(row, store_ids, location_ids, unit_id):
    stores = [s.strip() for s in (row.get("stores") or "").split("+") if s.strip()]
    desc = (row.get("description") or "").strip()
    if len(stores) > 1:
        desc = (desc + "\n" if desc else "") + "Also at: " + ", ".join(stores[1:])
    location = (row.get("location") or "").strip() or DEFAULT_LOCATION
    payload = {
        "name": row["name"].strip(),
        "description": desc,
        "location_id": location_ids[location.lower()],
        "qu_id_purchase": unit_id,
        "qu_id_stock": unit_id,
    }
    if stores:
        payload["shopping_location_id"] = store_ids[stores[0].lower()]
    return payload


def read_csv(path, required):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    for i, r in enumerate(rows, start=2):
        missing = [c for c in required if not (r.get(c) or "").strip()]
        if missing:
            raise InputError(f"{os.path.basename(path)} line {i}: missing {', '.join(missing)}")
    return rows


# ---------------------------------------------------------------- Grocy client

class Grocy:
    def __init__(self, url, key, apply):
        self.base = url.rstrip("/") + "/api"
        self.key = key
        self.apply = apply
        self.writes = 0
        self.next_fake_id = -1  # dry run: stand-in ids for objects not created

    def _call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("GROCY-API-KEY", self.key)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            raise InputError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
        except urllib.error.URLError as e:
            raise InputError(f"cannot reach Grocy at {self.base}: {e.reason}") from None
        return json.loads(raw) if raw.strip() else None

    def get(self, path):
        return self._call("GET", path)

    def write(self, path, body):
        if not self.apply:
            fake = self.next_fake_id
            self.next_fake_id -= 1
            return {"created_object_id": fake}
        self.writes += 1
        return self._call("POST", path, body)

    def by_name(self, entity):
        return {o["name"].strip().lower(): o["id"] for o in (self.get(f"/objects/{entity}") or [])}


def ensure(grocy, entity, existing, name, payload, log):
    key = name.strip().lower()
    if key in existing:
        log.append(f"  keep    {entity}: {name}")
        return existing[key], False
    res = grocy.write(f"/objects/{entity}", payload)
    existing[key] = int(res["created_object_id"])
    log.append(f"  create  {entity}: {name}")
    return existing[key], True


def run(url, key, data_dir, apply, out=sys.stdout):
    chores = read_csv(os.path.join(data_dir, "chores.csv"), ["name", "cadence"])
    products = read_csv(os.path.join(data_dir, "products.csv"), ["name"])
    if not chores and not products:
        raise InputError(f"no chores.csv or products.csv in {data_dir}")
    g = Grocy(url, key, apply)
    users = {}
    for u in g.get("/users") or []:
        users[u["username"].strip().lower()] = u["id"]
    log = []

    if products:
        stores = g.by_name("shopping_locations")
        locations = g.by_name("locations")
        units = g.by_name("quantity_units")
        unit_id, _ = ensure(g, "quantity_units", units, DEFAULT_UNIT,
                            {"name": DEFAULT_UNIT, "name_plural": DEFAULT_UNIT + "s"}, log)
        for r in products:
            for s in (r.get("stores") or "").split("+"):
                if s.strip():
                    ensure(g, "shopping_locations", stores, s.strip(), {"name": s.strip()}, log)
            loc = (r.get("location") or "").strip() or DEFAULT_LOCATION
            ensure(g, "locations", locations, loc, {"name": loc}, log)
        existing = g.by_name("products")
        for r in products:
            ensure(g, "products", existing, r["name"], product_payload(r, stores, locations, unit_id), log)

    if chores:
        existing = g.by_name("chores")
        for r in chores:
            payload, last = chore_payload(r, users)
            cid, created = ensure(g, "chores", existing, payload["name"], payload, log)
            if created and last:
                g.write(f"/chores/{cid}/execute", {"tracked_time": last.isoformat() + " 12:00:00"})
                log.append(f"  track   chore: {payload['name']} last done {last.isoformat()}")

    mode = "APPLY" if apply else "DRY RUN (nothing written; add --apply)"
    print(f"{mode}: {len(products)} products, {len(chores)} chores read", file=out)
    print("\n".join(log), file=out)
    print(f"writes: {g.writes}", file=out)
    return g.writes


def read_key(key_file):
    key = os.environ.get("GROCY_API_KEY", "").strip()
    if key:
        return key
    try:
        with open(key_file, encoding="utf-8") as f:
            key = f.read().strip()
    except OSError:
        key = ""
    if not key:
        raise InputError(f"no API key: set GROCY_API_KEY or put it in {key_file}")
    return key


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--url", default="http://localhost:9283", help="Grocy base URL")
    ap.add_argument("--data", default=DEFAULT_DATA, help="folder with chores.csv / products.csv")
    ap.add_argument("--key-file", default=DEFAULT_KEY_FILE)
    ap.add_argument("--apply", action="store_true", help="write to Grocy (default: dry run)")
    a = ap.parse_args(argv)
    try:
        run(a.url, read_key(a.key_file), a.data, a.apply)
    except InputError as e:
        print(f"grocy_import: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
