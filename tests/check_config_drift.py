#!/usr/bin/env python3
"""Offline drift check between the repo's sources of truth (standard library only).

Compares, with no host and no network:
  * models/server-seats.tsv            (the server's seats: tag, context, pinned weights)
  * server/llamacpp/models.ini         (the server's llama-server `c` per section)
  * node3/llamacpp/models.ini          (node3's llama-server `c` per section)
  * opencode/global/opencode.jsonc     (llamacpp-server / llamacpp-node3 models and limit.context)
  * models/catalog.tsv                 (the ctx column, for tags that are seated)
  * profiles/*.sh                      (live profiles: OPENCODE_*MODEL)
  * profiles/README.md                 (live / parked profile counts)

llama.cpp is the only local engine since 2026-11-21 (Ollama removed; the desktop runs no
models), so every check is about what a llama-server actually serves.

Deliberate differences live in tests/config-drift-allow.tsv (check, key, reason).
An allowlist row that no longer matches anything is itself a failure, so the list
cannot rot. Exit 0 = no drift, 1 = drift, 2 = a source could not be read.

Run:  python3 -I tests/check_config_drift.py [--root <repo>]
"""
import argparse
import glob
import json
import os
import re
import sys


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8-sig", newline="") as f:
        return f.read().replace("\r\n", "\n")


def strip_jsonc(text):
    """Remove // and /* */ comments (not inside strings) and trailing commas."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def tsv_rows(text):
    rows = []
    for line in text.split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        rows.append(line.split("\t"))
    return rows


def parse_models_ini(text):
    sections, cur = {}, None
    for line in text.split("\n"):
        line = line.strip()
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            cur = m.group(1)
            sections[cur] = {}
        elif cur and "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            sections[cur][k.strip()] = v.strip()
    return sections


def profile_all_exports(text, name):
    return re.findall(r'^\s*export\s+%s="([^"$]*)"' % re.escape(name), text, re.M)


def check(root):
    problems = []   # (check, key, message)

    def bad(check_name, key, msg):
        problems.append((check_name, key, msg))

    seats = {}
    for r in tsv_rows(read(root, "models/server-seats.tsv")):
        if r[0] == "tag":
            continue
        seats[r[0]] = (None if r[1] == "-" else int(r[1]), r[5])

    jsonc = json.loads(strip_jsonc(read(root, "opencode/global/opencode.jsonc")))
    providers = jsonc.get("provider", {})

    catalog = {}
    for r in tsv_rows(read(root, "models/catalog.tsv")):
        if r[0] == "tag":
            continue
        catalog[r[0]] = {"ctx": r[3]}

    def limits(provider):
        out = {}
        for tag, m in providers.get(provider, {}).get("models", {}).items():
            out[tag] = (m.get("limit") or {}).get("context")
        return out

    # 1. per host: models.ini `c` <-> the provider's limit.context; every registered
    #    model is a section the host serves. The server's `c` also equals the seat table.
    for host, ini_rel, prov in (("server", "server/llamacpp/models.ini", "llamacpp-server"),
                                ("node3", "node3/llamacpp/models.ini", "llamacpp-node3")):
        ini = parse_models_ini(read(root, ini_rel))
        lim = limits(prov)
        for tag, sec in ini.items():
            if tag == "*":
                continue
            c = sec.get("c")
            if c is None:
                bad("llamacpp-ctx", "%s %s" % (host, tag), "%s section has no explicit `c`" % ini_rel)
                continue
            if host == "server" and tag in seats and seats[tag][0] is not None and int(c) != seats[tag][0]:
                bad("llamacpp-ctx", "%s %s" % (host, tag), "models.ini c=%s, server-seats.tsv num_ctx %d" % (c, seats[tag][0]))
            if tag in lim and lim[tag] != int(c):
                bad("llamacpp-limit", "%s %s" % (host, tag), "opencode.jsonc %s limit.context %s, models.ini c=%s" % (prov, lim[tag], c))
        for tag in lim:
            if tag not in ini:
                bad("llamacpp-orphan", "%s %s" % (host, tag), "registered under %s but %s has no section for it" % (prov, ini_rel))

    # 2. every seat of the server has a models.ini section (a seat nobody serves is stale)
    server_ini = parse_models_ini(read(root, "server/llamacpp/models.ini"))
    for tag in seats:
        if tag not in server_ini:
            bad("seat-unserved", tag, "in models/server-seats.tsv but server/llamacpp/models.ini has no section")

    # 3. catalog.tsv ctx <-> the seat table, for seated tags (the column is display-only,
    #    so nothing else would notice it going stale)
    for tag, (n, _src) in seats.items():
        if tag in catalog and n is not None and catalog[tag]["ctx"] != str(n):
            bad("catalog-ctx", tag, "catalog.tsv ctx %s, server-seats.tsv num_ctx %d" % (catalog[tag]["ctx"], n))

    # 4. live profiles: seats registered
    live = sorted(glob.glob(os.path.join(root, "profiles", "dev-*.sh")))
    for path in live:
        name = os.path.basename(path)[:-3]
        text = read(root, os.path.relpath(path, root))
        for var in ("OPENCODE_MODEL", "OPENCODE_SMALL_MODEL"):
            for val in profile_all_exports(text, var):
                prov, _, tag = val.partition("/")
                if prov not in providers:
                    bad("profile-seat", "%s %s" % (name, var), "provider '%s' is not in opencode.jsonc" % prov)
                elif tag not in providers[prov].get("models", {}):
                    bad("profile-seat", "%s %s" % (name, var), "%s is not registered under %s" % (tag, prov))

    # 5. profiles/README.md counts
    readme = read(root, "profiles/README.md")
    parked = glob.glob(os.path.join(root, "profiles", "parked", "*.sh"))
    m = re.search(r"Live profiles \((\d+)\)", readme)
    if not m or int(m.group(1)) != len(live):
        bad("profile-count", "profiles/README.md", "says %s live, %d profiles/dev-*.sh exist" % (m.group(1) if m else "nothing", len(live)))
    m = re.search(r"Parked profiles \((\d+)\)", readme)
    if not m or int(m.group(1)) != len(parked):
        bad("parked-count", "profiles/README.md", "says %s parked, profiles/parked has %d" % (m.group(1) if m else "nothing", len(parked)))

    return problems


def apply_allowlist(root, problems):
    path = os.path.join(root, "tests", "config-drift-allow.tsv")
    allow = []
    if os.path.exists(path):
        allow = [r for r in tsv_rows(read(root, "tests/config-drift-allow.tsv")) if r[0] != "check"]
    used, remaining = set(), []
    for p in problems:
        hit = next((i for i, a in enumerate(allow) if a[0] == p[0] and a[1] == p[1]), None)
        if hit is None:
            remaining.append(p)
        else:
            used.add(hit)
    for i, a in enumerate(allow):
        if i not in used:
            remaining.append(("stale-allowlist", "%s %s" % (a[0], a[1]), "allowlist row matches nothing; remove it (%s)" % (a[2] if len(a) > 2 else "")))
    return remaining


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    try:
        problems = apply_allowlist(root, check(root))
    except (OSError, ValueError, RuntimeError) as e:
        print("config drift: cannot read a source: %s" % e, file=sys.stderr)
        return 2
    for chk, key, msg in problems:
        print("DRIFT [%s] %s: %s" % (chk, key, msg))
    print("config drift: %d problem(s)" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
