#!/usr/bin/env python3
"""planner_done.py - experiment 3's confirmation checkpoint (docs/planner-tests-experiment.md, "Confirmation checkpoint").

For a plain-language request the planner first writes DONE.md, its reading of what "done" means, as a checklist.
The owner keeps, strikes or rewords each line before any test is written; the tests phase runs only on a list that
was confirmed and has not changed since (desktop/scripts/run-planner.ps1 -Phase tests calls `verify`).

DONE.md format (anything else in the file is kept as is):

    - [x] D1: <a requirement>              kept: tests are written for it
    - [ ] N2: <something not asked for>    struck: no test, and no test may require it

Ids are a capital letter and a number, unique in the file. The planner pre-ticks what it believes the request
requires. `confirm` appends one line,

    <!-- confirmed by <who> at <time>, items sha256 <hash> -->

where the hash covers every item line (state, id, text) in order, so a later edit to any item, or a tick,
invalidates the confirmation.

  python -I planner_done.py show    DONE.md
  python -I planner_done.py set     DONE.md D1=off N2=on          tick or strike items
  python -I planner_done.py confirm DONE.md --by owner
  python -I planner_done.py verify  DONE.md                       exit 0 and the kept ids, or exit 1 and why

Exit 2 on a malformed file. Standard library only.
"""
import argparse
import datetime
import hashlib
import re
import sys

ITEM = re.compile(r"^- \[([ xX])\] ([A-Z][0-9]+): (\S.*)$")
LOOSE_ITEM = re.compile(r"^\s*[-*] \[")
CONFIRM = re.compile(r"^<!-- confirmed by (.+?) at (\S+), items sha256 ([0-9a-f]{64}) -->$")


class Malformed(Exception):
    pass


def parse(text):
    """-> (items [(kept, id, text)], confirmations [(who, when, hash)]). Raises Malformed."""
    items, confs, seen = [], [], set()
    for n, line in enumerate(text.splitlines(), 1):
        line = line.rstrip()
        m = ITEM.match(line)
        if m:
            iid = m.group(2)
            if iid in seen:
                raise Malformed("line %d: id %s is used twice" % (n, iid))
            seen.add(iid)
            items.append((m.group(1) != " ", iid, m.group(3).strip()))
            continue
        if LOOSE_ITEM.match(line):
            raise Malformed("line %d: a checklist line must read '- [x] D1: text' or '- [ ] D1: text': %r" % (n, line))
        c = CONFIRM.match(line)
        if c:
            confs.append((c.group(1), c.group(2), c.group(3)))
    if not items:
        raise Malformed("no checklist items")
    return items, confs


def items_hash(items):
    h = hashlib.sha256()
    for kept, iid, txt in items:
        h.update(("%s %s %s\n" % ("x" if kept else " ", iid, txt)).encode("utf-8"))
    return h.hexdigest()


def verify(text):
    """-> (ok, message, kept ids)."""
    items, confs = parse(text)
    kept = [i for k, i, _ in items if k]
    if not confs:
        return False, "not confirmed: run `planner_done.py confirm` after the owner has reviewed it", kept
    who, when, h = confs[-1]
    if h != items_hash(items):
        return False, "changed since it was confirmed by %s at %s: confirm it again" % (who, when), kept
    if not kept:
        return False, "confirmed, but every item is struck: nothing to test", kept
    return True, "confirmed by %s at %s; %d kept, %d struck" % (who, when, len(kept), len(items) - len(kept)), kept


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
    items, _ = parse(text)
    unknown = sorted(set(want) - {i for _, i, _ in items})
    if unknown:
        raise Malformed("no item %s" % ", ".join(unknown))
    out = []
    for line in text.splitlines(keepends=True):
        m = ITEM.match(line.rstrip())
        if m and m.group(2) in want:
            line = line.replace("- [%s]" % m.group(1), "- [%s]" % ("x" if want[m.group(2)] else " "), 1)
        out.append(line)
    return "".join(out)


def cmd_confirm(text, who, now=None):
    items, _ = parse(text)
    when = now or datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    nl = "\r\n" if "\r\n" in text else "\n"
    if not text.endswith(("\n", "\r")):
        text += nl
    return text + "<!-- confirmed by %s at %s, items sha256 %s -->%s" % (who, when, items_hash(items), nl)


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
            items, confs = parse(text)
            for kept, iid, txt in items:
                print("  [%s] %-4s %s" % ("x" if kept else " ", iid, txt))
            ok, msg, _ = verify(text)
            print("\n%s" % msg)
            return 0
        if a.cmd == "verify":
            ok, msg, kept = verify(text)
            print(msg)
            if ok:
                print("kept: " + " ".join(kept))
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
