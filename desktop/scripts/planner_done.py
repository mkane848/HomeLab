#!/usr/bin/env python3
"""planner_done.py - experiment 3's confirmation checkpoint (docs/planner-tests-experiment.md, "Confirmation checkpoint").

For a plain-language request the planner first writes DONE.md, its reading of what "done" means, as a checklist.
The owner keeps, strikes or rewords each line before any test is written; the tests phase runs only on a list that
was confirmed and has not changed since (desktop/scripts/run-planner.ps1 -Phase tests calls `verify`).

DONE.md format, version 2 (2026-11-01, the owner's answers: accept and ideal are different bars; items with
sub-items, like work items on a board). Anything else in the file is kept as is.

    Size: 2-minute read                      optional: how long the owner needs to review it

    ## Gate                                  what the owner would accept: the tests that decide merge or retry
    - [x] G1: <a top-level item>
      - [x] G1.1: <a sub-item>              struck parent = every sub-item struck, whatever its own tick
    ## Ideal                                 what the owner would ideally want: tracked per attempt, never gating
    - [x] I1: <an item>
    ## Out of scope                          noted, not tested; an item here may not be ticked
    - [ ] O1: <an item>

Ids are a capital letter and a number, with `.n` for each level down (G1.2.1); unique; a sub-item's parent comes
before it. The tier is the section an item sits in (`## Gate`, `## Ideal`, `## Out of scope`; version 1's
`Must do` / `Must keep` read as Gate and `Could do` as Out of scope; items before any section are Gate). The planner
pre-ticks; the owner changes ticks, rewords, moves lines between sections. `confirm` appends one line,

    <!-- confirmed by <who> at <time>, items sha256 <hash> -->

where the hash covers every item (tier, tick, id, text) in order, so a later edit, tick or move voids it.

  python -I planner_done.py show    DONE.md
  python -I planner_done.py set     DONE.md G2=off I1=on          tick or strike items
  python -I planner_done.py confirm DONE.md --by owner
  python -I planner_done.py verify  DONE.md                       exit 0 and the kept ids by tier, or exit 1 and why

Exit 2 on a malformed file. Standard library only.
"""
import argparse
import collections
import datetime
import hashlib
import re
import sys

ITEM = re.compile(r"^(\s*)- \[([ xX])\] ([A-Z][0-9]+(?:\.[0-9]+)*): (\S.*)$")
LOOSE_ITEM = re.compile(r"^\s*[-*] \[")
HEADING = re.compile(r"^#{2,6}\s+(.*?)\s*$")
SIZE = re.compile(r"^Size:\s*(\S.*)$", re.I)
CONFIRM = re.compile(r"^<!-- confirmed by (.+?) at (\S+), items sha256 ([0-9a-f]{64}) -->$")
TIERS = ("gate", "ideal", "out")

Item = collections.namedtuple("Item", "ticked id text tier kept")
Done = collections.namedtuple("Done", "items confirmations size")


class Malformed(Exception):
    pass


def tier_of(heading):
    h = heading.lower()
    if "ideal" in h:
        return "ideal"
    if "out of scope" in h or "could do" in h or "not asked" in h or "not clearly asked" in h:
        return "out"
    if "gate" in h or "must" in h:
        return "gate"
    return None


def parse(text):
    """-> Done(items [Item], confirmations [(who, when, hash)], size). Raises Malformed.
    Item.kept is the effective verdict: ticked, and every ancestor ticked."""
    raw, confs, seen, size, tier = [], [], {}, None, "gate"
    for n, line in enumerate(text.splitlines(), 1):
        line = line.rstrip()
        m = ITEM.match(line)
        if m:
            ticked, iid, txt = m.group(2) != " ", m.group(3), m.group(4).strip()
            if iid in seen:
                raise Malformed("line %d: id %s is used twice" % (n, iid))
            parent = iid.rsplit(".", 1)[0] if "." in iid else None
            if parent and parent not in seen:
                raise Malformed("line %d: %s has no parent %s above it" % (n, iid, parent))
            if parent and seen[parent] != tier:
                raise Malformed("line %d: %s is under %s but in a different section" % (n, iid, parent))
            if tier == "out" and ticked:
                raise Malformed("line %d: %s is ticked under Out of scope: move it to Gate or Ideal, or untick it" % (n, iid))
            seen[iid] = tier
            raw.append((ticked, iid, txt, tier, parent))
            continue
        if LOOSE_ITEM.match(line):
            raise Malformed("line %d: a checklist line must read '- [x] G1: text' (sub-items indented, 'G1.1'): %r" % (n, line))
        h = HEADING.match(line)
        if h:
            t = tier_of(h.group(1))
            if t:
                tier = t
            continue
        s = SIZE.match(line)
        if s and size is None:
            size = s.group(1).strip()
            continue
        c = CONFIRM.match(line)
        if c:
            confs.append((c.group(1), c.group(2), c.group(3)))
    if not raw:
        raise Malformed("no checklist items")
    kept = {}
    items = []
    for ticked, iid, txt, t, parent in raw:
        k = ticked and (parent is None or kept[parent])
        kept[iid] = k
        items.append(Item(ticked, iid, txt, t, k))
    return Done(items, confs, size)


def items_hash(items):
    h = hashlib.sha256()
    for it in items:
        h.update(("%s %s %s %s\n" % (it.tier, "x" if it.ticked else " ", it.id, it.text)).encode("utf-8"))
    return h.hexdigest()


def kept_by_tier(items):
    return {t: [it.id for it in items if it.tier == t and it.kept] for t in ("gate", "ideal")}


def verify(text):
    """-> (ok, message, kept {gate: [ids], ideal: [ids]})."""
    d = parse(text)
    kept = kept_by_tier(d.items)
    if not d.confirmations:
        return False, "not confirmed: run `planner_done.py confirm` after the owner has reviewed it", kept
    who, when, h = d.confirmations[-1]
    if h != items_hash(d.items):
        return False, "changed since it was confirmed by %s at %s: confirm it again" % (who, when), kept
    if not kept["gate"]:
        return False, "confirmed, but no Gate item is kept: nothing decides merge or retry", kept
    struck = sum(1 for it in d.items if it.tier != "out" and not it.kept)
    return True, "confirmed by %s at %s; gate %d, ideal %d kept, %d struck" % (
        who, when, len(kept["gate"]), len(kept["ideal"]), struck), kept


def read(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def cmd_set(text, changes):
    want = {}
    for c in changes:
        iid, _, state = c.partition("=")
        if state not in ("on", "off"):
            raise Malformed("%s: use ID=on or ID=off" % c)
        want[iid] = state == "on"
    d = parse(text)
    unknown = sorted(set(want) - {it.id for it in d.items})
    if unknown:
        raise Malformed("no item %s" % ", ".join(unknown))
    out = []
    for line in text.splitlines(keepends=True):
        m = ITEM.match(line.rstrip("\r\n").rstrip())
        if m and m.group(3) in want:
            line = line.replace("- [%s]" % m.group(2), "- [%s]" % ("x" if want[m.group(3)] else " "), 1)
        out.append(line)
    result = "".join(out)
    parse(result)  # a tick under Out of scope is refused here, not at verify time
    return result


def cmd_confirm(text, who, now=None):
    d = parse(text)
    when = now or datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    nl = "\r\n" if "\r\n" in text else "\n"
    if not text.endswith(("\n", "\r")):
        text += nl
    return text + "<!-- confirmed by %s at %s, items sha256 %s -->%s" % (who, when, items_hash(d.items), nl)


def show(text):
    d = parse(text)
    lines = []
    if d.size:
        lines.append("Size: %s" % d.size)
    names = {"gate": "Gate (decides merge or retry)", "ideal": "Ideal (tracked, never gating)", "out": "Out of scope"}
    for t in TIERS:
        its = [it for it in d.items if it.tier == t]
        if not its:
            continue
        lines.append("%s:" % names[t])
        for it in its:
            mark = "x" if it.kept else ("-" if it.ticked else " ")  # "-": ticked, but its parent is struck
            lines.append("  %s[%s] %-7s %s" % ("  " * it.id.count("."), mark, it.id, it.text))
    lines.append("")
    lines.append(verify(text)[1])
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(description="Experiment 3's DONE.md confirmation checkpoint.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("show", "verify"):
        sub.add_parser(name).add_argument("file")
    s = sub.add_parser("set")
    s.add_argument("file")
    s.add_argument("changes", nargs="+")
    c = sub.add_parser("confirm")
    c.add_argument("file")
    c.add_argument("--by", required=True)
    a = ap.parse_args(argv)
    try:
        text = read(a.file)
        if a.cmd == "show":
            print(show(text))
            return 0
        if a.cmd == "verify":
            ok, msg, kept = verify(text)
            print(msg)
            if ok:
                print("gate: " + " ".join(kept["gate"]))
                print("ideal: " + " ".join(kept["ideal"]))
            return 0 if ok else 1
        if a.cmd == "set":
            write(a.file, cmd_set(text, a.changes))
            return 0
        if a.cmd == "confirm":
            if not re.match(r"^[\w.@-]{1,40}$", a.by):
                raise Malformed("--by: a short name (letters, digits, . _ @ -)")
            write(a.file, cmd_confirm(text, a.by))
            print(verify(read(a.file))[1])
            return 0
    except Malformed as e:
        print("planner_done: %s" % e, file=sys.stderr)
        return 2
    except OSError as e:
        print("planner_done: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
