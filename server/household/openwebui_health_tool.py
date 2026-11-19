"""
title: Health (appointments)
author: HomeLab
version: 0.2.0
description: The household's appointments: what is due to book, what is coming up, when someone was last seen, clashes.
"""
# The Health agent: docs/household/health-agent.md. Requirement 5 of docs/household-assistant.md.
#
# An Open WebUI Tool, separate from the household's Grocy tool, so the house chat never sees health and this one sees
# only appointments. It prepares and reminds; it never books (providers book by phone or portal).
#
# Where things live:
#   - how often each kind repeats, and when it is due to book: Grocy chores named "Book: <person> <kind>";
#   - one record per person and kind (provider, how to book, visit notes, the words that find it in the calendar):
#     Grocy's user entity `appointment_kinds` (custom fields), created by server/household/grocy_import.py;
#   - booked and past appointments: the family calendar's private feeds (one per adult), read-only. Only events that
#     match a kind's words are ever returned; the rest of the calendar never reaches the chat.
# Writes (logging a visit, adding a kind) happen only after the user's own plain OK, checked here from __messages__,
# as the Grocy tool's receipts do. The Grocy key and the feed URLs are Valves (encrypted at rest) and never put in a
# result. Standard library HTTP; pydantic only for the Valves, which Open WebUI provides.
import datetime as dt
import json
import re
import urllib.error
import urllib.request
import zoneinfo

from pydantic import BaseModel, Field

ENTITY = "appointment_kinds"
FIELDS = ("person", "kind", "provider", "how_to_book", "notes", "match_words")
BOOK_PREFIX = "Book:"

APPROVE = re.compile(r"\b(ok|okay|yes|yep|yeah|confirm|confirmed|approve|approved|go ahead|looks good|sounds good"
                     r"|correct|log it|add it|do it)\b", re.I)
HOLD = re.compile(r"\b(no|not|don'?t|wait|skip|wrong|change|instead|but|missing|except|stop)\b", re.I)


class HealthError(Exception):
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


def parse_ics(text, tz=None):
    """iCalendar text -> [{start: date, time: 'HH:MM' or '', summary}]. Unfolds continuation lines; reads DTSTART with
    or without VALUE=DATE / TZID, and SUMMARY with its escapes undone. A UTC time (trailing Z) is moved to tz (a
    tzinfo; None = this machine's zone), its date with it; a TZID time is taken as written, the feed's own local time.
    Repeats come as separate events in the family calendar's feed, so no RRULE expansion."""
    lines, out, ev = [], [], None
    for raw in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    for line in lines:
        if line == "BEGIN:VEVENT":
            ev = {}
        elif line == "END:VEVENT":
            if ev is not None and ev.get("start"):
                out.append({"start": ev["start"], "time": ev.get("time", ""), "summary": ev.get("summary", "")})
            ev = None
        elif ev is not None and ":" in line:
            key, value = line.split(":", 1)
            name = key.split(";", 1)[0].upper()
            if name == "DTSTART":
                m = re.match(r"(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})\d{0,2}(Z?))?", value.strip())
                if m:
                    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
                    if m.group(4) and m.group(6):
                        at = dt.datetime(y, mo, d, int(m.group(4)), int(m.group(5)), tzinfo=dt.timezone.utc)
                        at = at.astimezone(tz) if tz else at.astimezone()
                        ev["start"], ev["time"] = at.date(), at.strftime("%H:%M")
                    else:
                        ev["start"] = dt.date(y, mo, d)
                        ev["time"] = f"{m.group(4)}:{m.group(5)}" if m.group(4) else ""
            elif name == "SUMMARY":
                ev["summary"] = (value.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",")
                                 .replace("\\;", ";").replace("\\\\", "\\").strip())
    return out


def words_of(kind_record):
    """The match words of a kind: its own words, else the kind's name, lower case."""
    raw = (kind_record.get("match_words") or kind_record.get("kind") or "")
    return [w.strip().lower() for w in re.split(r"[,;]", raw) if w.strip()]


def matches(summary, words):
    s = (summary or "").lower()
    return any(re.search(r"(?<![a-z])" + re.escape(w) + r"(?![a-z])", s) for w in words)


class Tools:
    class Valves(BaseModel):
        grocy_url: str = Field(default="http://grocy:80", description="Grocy's base URL, as seen from Open WebUI")
        api_key: str = Field(default="", description="A Grocy API key made for the chat",
                             json_schema_extra={"input": {"type": "password"}})
        feed_1_person: str = Field(default="", description="Whose calendar feed 1 is (a name, as in the Book: chores)")
        feed_1_url: str = Field(default="", description="That person's private calendar feed (subscription) URL",
                                json_schema_extra={"input": {"type": "password"}})
        feed_2_person: str = Field(default="", description="Whose calendar feed 2 is")
        feed_2_url: str = Field(default="", description="That person's private calendar feed (subscription) URL",
                                json_schema_extra={"input": {"type": "password"}})
        time_zone: str = Field(default="", description="The household's time zone, e.g. America/Chicago, for feed "
                               "times given in UTC. Empty: the server's own zone")

    def __init__(self):
        self.valves = self.Valves()

    # ------------------------------------------------------------ helpers (not tools)

    def _secrets(self):
        return [s for s in (self.valves.api_key, self.valves.feed_1_url, self.valves.feed_2_url) if s]

    def _scrub(self, text):
        for s in self._secrets():
            text = text.replace(s, "[secret]")
        return text

    def _call(self, method, path, body=None):
        if not self.valves.api_key:
            raise HealthError("the Grocy API key is not set (Workspace > Tools > Health > Valves)")
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
            raise HealthError(self._scrub(f"Grocy refused {method} {path} (HTTP {e.code}): {detail}")) from None
        except (urllib.error.URLError, OSError) as e:
            raise HealthError(f"cannot reach Grocy at {self.valves.grocy_url}: {getattr(e, 'reason', e)}") from None
        return json.loads(raw) if raw.strip() else None

    def _kinds(self):
        """All appointment kinds: [{id, person, kind, provider, how_to_book, notes, match_words}]."""
        ent = next((e for e in (self._call("GET", "/objects/userentities") or []) if e.get("name") == ENTITY), None)
        if not ent:
            raise HealthError("there is no appointments list in Grocy yet: run grocy_import.py with "
                              "appointment_kinds.csv (docs/household/health-agent.md)")
        out = []
        for o in self._call("GET", "/objects/userobjects") or []:
            if int(o.get("userentity_id", -1)) != int(ent["id"]):
                continue
            vals = self._call("GET", f"/userfields/userentity-{ENTITY}/{int(o['id'])}") or {}
            rec = {"id": int(o["id"])}
            rec.update({f: (vals.get(f) or "").strip() for f in FIELDS})
            out.append(rec)
        return out

    def _kind(self, person, kind, kinds=None):
        kinds = self._kinds() if kinds is None else kinds
        p, k = person.strip().lower(), kind.strip().lower()
        hits = [r for r in kinds if r["person"].lower() == p and r["kind"].lower() == k]
        if not hits:
            hits = [r for r in kinds if r["person"].lower() == p and k and k in r["kind"].lower()]
        if len(hits) == 1:
            return hits[0]
        known = ", ".join(sorted(f"{r['person']} {r['kind']}" for r in kinds)) or "none"
        if not hits:
            raise HealthError(f"no appointment kind '{kind}' for '{person}'. Known: {known}. Ask which one is meant")
        raise HealthError(f"'{kind}' for '{person}' matches several: "
                          + ", ".join(f"{r['person']} {r['kind']}" for r in hits) + ". Ask which one is meant")

    def _book_chores(self):
        """{lower name: chore row from /chores} for the Book: chores."""
        names = {int(c["id"]): c["name"] for c in (self._call("GET", "/objects/chores") or [])}
        out = {}
        for c in self._call("GET", "/chores") or []:
            name = c.get("chore_name") or names.get(int(c["chore_id"]), "")
            if name.startswith(BOOK_PREFIX):
                out[name.lower()] = dict(c, chore_name=name)
        return out

    def _chore_for(self, rec, chores=None):
        chores = self._book_chores() if chores is None else chores
        return chores.get(f"{BOOK_PREFIX} {rec['person']} {rec['kind']}".lower())

    def _tz(self):
        name = (self.valves.time_zone or "").strip()
        if not name:
            return None
        try:
            return zoneinfo.ZoneInfo(name)
        except (zoneinfo.ZoneInfoNotFoundError, ValueError):
            raise HealthError(f"the time_zone Valve '{name}' is not a time zone name (e.g. America/Chicago)") from None

    def _feeds(self):
        """[(person, [events])] for each feed that is set. A feed that fails is named by its person, never its URL."""
        out = []
        for person, url in ((self.valves.feed_1_person, self.valves.feed_1_url),
                            (self.valves.feed_2_person, self.valves.feed_2_url)):
            if not url.strip():
                continue
            try:
                with urllib.request.urlopen(urllib.request.Request(url.strip()), timeout=20) as r:
                    text = r.read().decode("utf-8", "replace")
            except (urllib.error.URLError, OSError, ValueError) as e:
                raise HealthError(f"cannot read {person or 'a'}'s calendar feed: "
                                  f"{self._scrub(str(getattr(e, 'reason', e)))}") from None
            out.append((person.strip(), parse_ics(text, self._tz())))
        if not out:
            raise HealthError("no calendar feed is set (Workspace > Tools > Health > Valves)")
        return out

    @staticmethod
    def _date(text, label="date"):
        try:
            return dt.date.fromisoformat((text or "").strip())
        except ValueError:
            raise HealthError(f"'{text}' is not a {label} like 2026-11-08") from None

    def _run(self, fn):
        try:
            return fn()
        except HealthError as e:
            msg = str(e)
            return f"Could not do that: {msg}" + ("" if msg.endswith(("?", ".")) else ".")

    # ------------------------------------------------------------ tools

    async def appointments_due(self, days: int = 30) -> str:
        """
        List the appointments that are due to be booked (overdue, or due within the next days), with how to book each.
        :param days: how many days ahead to look, default 30
        """
        def go():
            limit = dt.date.today() + dt.timedelta(days=int(days))
            kinds = {f"{BOOK_PREFIX} {r['person']} {r['kind']}".lower(): r for r in self._kinds()}
            rows = []
            for name, c in self._book_chores().items():
                nxt = (c.get("next_estimated_execution_time") or "")[:10]
                if not nxt or dt.date.fromisoformat(nxt) > limit:
                    continue
                last = (c.get("last_tracked_time") or "")[:10] or "never"
                rec = kinds.get(name, {})
                how = f"; book via {rec['how_to_book']}" if rec.get("how_to_book") else ""
                who = f" ({rec['provider']})" if rec.get("provider") else ""
                late = " OVERDUE" if dt.date.fromisoformat(nxt) < dt.date.today() else ""
                rows.append((nxt, f"- {c['chore_name'][len(BOOK_PREFIX):].strip()}{who}: due {nxt}{late}; "
                                  f"last visit {last}{how}"))
            if not rows:
                return f"Nothing is due to book in the next {days} days."
            return f"Due to book by {limit.isoformat()}:\n" + "\n".join(r for _, r in sorted(rows))
        return self._run(go)

    async def upcoming(self, person: str = "", days: int = 60) -> str:
        """
        List booked appointments in the next days, from the family calendar. Only appointments are shown.
        :param person: whose appointments; empty means everyone's
        :param days: how many days ahead to look, default 60
        """
        def go():
            today = dt.date.today()
            limit = today + dt.timedelta(days=int(days))
            kinds = self._kinds()
            want = person.strip().lower()
            rows = []
            for who, events in self._feeds():
                if want and who.lower() != want:
                    continue
                mine = [r for r in kinds if r["person"].lower() == who.lower()]
                for e in events:
                    if not (today <= e["start"] <= limit):
                        continue
                    hit = next((r for r in mine if matches(e["summary"], words_of(r))), None)
                    if hit:
                        at = f" {e['time']}" if e["time"] else ""
                        rows.append((e["start"], e["time"], f"- {e['start'].isoformat()}{at}: {who}, {hit['kind']} "
                                                            f"({e['summary']})"
                                                            + (f"; notes: {hit['notes']}" if hit["notes"] else "")))
            if not rows:
                return f"No appointments in the calendar in the next {days} days" + (f" for {person}." if want else ".")
            return "\n".join(r for _, _, r in sorted(rows))
        return self._run(go)

    async def last_visit(self, person: str, kind: str) -> str:
        """
        Say when a person last had a kind of appointment, and when the next one is due to be booked.
        :param person: whose appointment
        :param kind: the kind, as in the appointments list (e.g. dentist)
        """
        def go():
            rec = self._kind(person, kind)
            c = self._chore_for(rec)
            if not c:
                return (f"{rec['person']}'s {rec['kind']} has no 'Book: {rec['person']} {rec['kind']}' chore in Grocy, "
                        "so no visits are recorded.")
            last = (c.get("last_tracked_time") or "")[:10] or "never recorded"
            nxt = (c.get("next_estimated_execution_time") or "")[:10] or "not scheduled"
            return f"{rec['person']}'s last {rec['kind']} visit: {last}. Next due to book: {nxt}."
        return self._run(go)

    async def log_visit(self, person: str, kind: str, date: str, confirm: bool = False,
                        __messages__: list = None) -> str:
        """
        Record that a person had an appointment on a day, which restarts its "due to book" clock. Call it first with
        confirm false and show the user what it will record; call it again with confirm true only after the user says OK.
        :param person: whose appointment
        :param kind: the kind, as in the appointments list
        :param date: the day of the visit, YYYY-MM-DD
        :param confirm: true only after the user has said OK to exactly this
        """
        def go():
            day = self._date(date, "visit date")
            if day > dt.date.today():
                raise HealthError(f"{day.isoformat()} is in the future: a visit is logged after it happens")
            rec = self._kind(person, kind)
            c = self._chore_for(rec)
            if not c:
                raise HealthError(f"there is no 'Book: {rec['person']} {rec['kind']}' chore in Grocy to record it on")
            what = f"{rec['person']}'s {rec['kind']} visit on {day.isoformat()}"
            if not confirm or not user_said_ok(__messages__):
                return f"Ready to record {what}. Nothing is written until the user says OK."
            self._call("POST", f"/chores/{int(c['chore_id'])}/execute", {"tracked_time": day.isoformat() + " 12:00:00"})
            return f"Recorded {what}."
        return self._run(go)

    async def check_clash(self, date: str) -> str:
        """
        Say what is already on the family calendar on a day, before booking. Appointments are named; anything else
        shows only as busy, with its time.
        :param date: the day to check, YYYY-MM-DD
        """
        def go():
            day = self._date(date)
            kinds = self._kinds()
            rows = []
            for who, events in self._feeds():
                mine = [r for r in kinds if r["person"].lower() == who.lower()]
                for e in events:
                    if e["start"] != day:
                        continue
                    hit = next((r for r in mine if matches(e["summary"], words_of(r))), None)
                    at = e["time"] or "all day"
                    rows.append((e["time"], f"- {at}: {who}, " + (f"{hit['kind']} appointment" if hit else "busy")))
            if not rows:
                return f"Nothing on the calendar on {day.isoformat()}."
            return f"On {day.isoformat()}:\n" + "\n".join(r for _, r in sorted(rows))
        return self._run(go)

    async def add_kind(self, person: str, kind: str, provider: str = "", how_to_book: str = "", notes: str = "",
                       match_words: str = "", confirm: bool = False, __messages__: list = None) -> str:
        """
        Add a kind of appointment for a person to the appointments list. Call it first with confirm false and show the
        user what it will add; call it again with confirm true only after the user says OK. It does not create the
        "Book:" chore that sets how often it repeats; that is added in Grocy (docs/household/health-agent.md).
        :param person: whose appointment
        :param kind: the kind, e.g. dentist
        :param provider: the practice or doctor, optional
        :param how_to_book: how it is booked (phone, portal), as text, optional
        :param notes: what to remember for a visit (fasting, arrive early), optional
        :param match_words: comma-separated words that find it in calendar titles; empty means the kind's name
        :param confirm: true only after the user has said OK to exactly this
        """
        def go():
            if not person.strip() or not kind.strip():
                raise HealthError("a kind needs a person and a kind name")
            kinds = self._kinds()
            if any(r["person"].lower() == person.strip().lower() and r["kind"].lower() == kind.strip().lower()
                   for r in kinds):
                raise HealthError(f"{person.strip()} already has a '{kind.strip()}' kind")
            vals = {"person": person.strip(), "kind": kind.strip(), "provider": provider.strip(),
                    "how_to_book": how_to_book.strip(), "notes": notes.strip(), "match_words": match_words.strip()}
            what = f"'{vals['kind']}' for {vals['person']}" + (f" ({vals['provider']})" if vals["provider"] else "")
            if not confirm or not user_said_ok(__messages__):
                return f"Ready to add {what}. Nothing is written until the user says OK."
            ent = next(e for e in (self._call("GET", "/objects/userentities") or []) if e.get("name") == ENTITY)
            res = self._call("POST", "/objects/userobjects", {"userentity_id": int(ent["id"])})
            oid = int(res["created_object_id"])
            self._call("PUT", f"/userfields/userentity-{ENTITY}/{oid}", vals)
            return f"Added {what}. Add a 'Book: {vals['person']} {vals['kind']}' chore in Grocy to set how often it repeats."
        return self._run(go)
