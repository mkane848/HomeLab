#!/usr/bin/env python3
"""Offline drift check between the repo's sources of truth (standard library only).

Compares, with no host and no network:
  * desktop/scripts/startup.ps1 $contextModels / $derivedModels
  * models/server-seats.tsv            (what the server bakes)
  * server/llamacpp/models.ini         (llama-server `c` per section)
  * opencode/global/opencode.jsonc     (registered models and limit.context)
  * models/catalog.tsv                 (every model we can run)
  * profiles/*.sh                      (live profiles: OPENCODE_*MODEL, DEV_*_MODELS)
  * profiles/README.md                 (live / parked profile counts)

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


def parse_context_models(ps1):
    ctx = {}
    for m in re.finditer(r'@\{\s*Base\s*=\s*"([^"]+)";\s*Ctx\s*=\s*(\d+)', ps1):
        ctx[m.group(1)] = int(m.group(2))
    derived = {}
    for m in re.finditer(r'@\{\s*Name\s*=\s*"([^"]+)";\s*From\s*=\s*"([^"]+)";\s*Ctx\s*=\s*(\d+)', ps1):
        derived[m.group(1)] = int(m.group(3))
    return ctx, derived


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


def profile_exports(text):
    env = {}
    for m in re.finditer(r'^\s*export\s+([A-Z_0-9]+)="([^"$]*)"', text, re.M):
        env[m.group(1)] = m.group(2)
    return env


def profile_all_exports(text, name):
    return re.findall(r'^\s*export\s+%s="([^"$]*)"' % re.escape(name), text, re.M)


def check(root):
    problems = []   # (check, key, message)

    def bad(check_name, key, msg):
        problems.append((check_name, key, msg))

    ctx_models, derived = parse_context_models(read(root, "desktop/scripts/startup.ps1"))
    if not ctx_models:
        raise RuntimeError("no $contextModels entries parsed from startup.ps1")

    seats = {}
    for r in tsv_rows(read(root, "models/server-seats.tsv")):
        if r[0] == "tag":
            continue
        seats[r[0]] = (None if r[1] == "-" else int(r[1]), r[5])

    ini = parse_models_ini(read(root, "server/llamacpp/models.ini"))
    jsonc = json.loads(strip_jsonc(read(root, "opencode/global/opencode.jsonc")))
    providers = jsonc.get("provider", {})

    catalog = {}
    for r in tsv_rows(read(root, "models/catalog.tsv")):
        if r[0] == "tag":
            continue
        catalog[r[0]] = {"ctx": r[3], "groups": r[4].split(","), "hosts": r[5].split(",")}

    def limits(provider):
        out = {}
        for tag, m in providers.get(provider, {}).get("models", {}).items():
            out[tag] = (m.get("limit") or {}).get("context")
        return out

    desk, srv, llsrv = limits("ollama-desktop"), limits("ollama-server"), limits("llamacpp-server")

    # 1. startup.ps1 <-> server-seats.tsv (same tag, same baked context)
    for tag, (n, _src) in seats.items():
        base = derived if tag in derived else ctx_models
        if tag in base and n is not None and base[tag] != n:
            bad("seat-ctx", tag, "server-seats.tsv bakes %d, startup.ps1 bakes %d" % (n, base[tag]))
        if tag not in base and n is not None:
            bad("seat-not-on-desktop", tag, "in server-seats.tsv but not in startup.ps1 ($contextModels/$derivedModels)")

    # 2. opencode.jsonc ollama-desktop limit.context <-> startup.ps1
    for tag, n in ctx_models.items():
        if tag in desk and desk[tag] != n:
            bad("desktop-limit", tag, "opencode.jsonc ollama-desktop limit.context %s, startup.ps1 bakes %d" % (desk[tag], n))
    for tag, n in derived.items():
        if tag in desk and desk[tag] != n:
            bad("desktop-limit", tag, "opencode.jsonc ollama-desktop limit.context %s, startup.ps1 derives %d" % (desk[tag], n))

    # 3. opencode.jsonc ollama-server limit.context <-> server-seats.tsv; unbaked tags serve 16384
    for tag, n in srv.items():
        if tag in seats and seats[tag][0] is not None:
            if n != seats[tag][0]:
                bad("server-limit", tag, "opencode.jsonc ollama-server limit.context %s, server-seats.tsv bakes %d" % (n, seats[tag][0]))
        elif n is not None and n > 16384:
            bad("server-limit", tag, "limit.context %s but the tag is not baked (serves OLLAMA_CONTEXT_LENGTH, 16384)" % n)

    # 4. llamacpp-server: models.ini `c` <-> limit.context <-> server-seats.tsv
    for tag, sec in ini.items():
        if tag == "*":
            continue
        c = sec.get("c")
        if c is None:
            bad("llamacpp-ctx", tag, "models.ini section has no explicit `c`")
            continue
        if tag in seats and seats[tag][0] is not None and int(c) != seats[tag][0]:
            bad("llamacpp-ctx", tag, "models.ini c=%s, server-seats.tsv num_ctx %d" % (c, seats[tag][0]))
        if tag in llsrv and llsrv[tag] != int(c):
            bad("llamacpp-limit", tag, "opencode.jsonc llamacpp-server limit.context %s, models.ini c=%s" % (llsrv[tag], c))
    for tag in llsrv:
        if tag not in ini:
            bad("llamacpp-orphan", tag, "registered under llamacpp-server but has no models.ini section")

    # 5. every ollama-server / ollama-desktop key is a catalog tag, or says why not
    for prov, keys in (("ollama-server", srv), ("ollama-desktop", desk)):
        for tag in keys:
            if tag not in catalog:
                bad("uncatalogued", "%s/%s" % (prov, tag), "registered in opencode.jsonc but has no catalog.tsv row")

    # 6. catalog rows eligible for the server/desktop that are not registered there
    for tag, row in catalog.items():
        if "embed" in row["groups"]:
            continue    # embedding models have no chat endpoint; never registered
        for host, keys, prov in (("server", srv, "ollama-server"), ("desktop", desk, "ollama-desktop")):
            if (host in row["hosts"] or "all" in row["hosts"]) and tag not in keys:
                bad("unregistered", "%s/%s" % (prov, tag), "catalog.tsv says %s may run it but opencode.jsonc does not register it" % host)

    # 7. live profiles: seats registered, model lists catalogued
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
        for var in ("DEV_SERVER_MODELS", "DEV_DESKTOP_MODELS", "DEV_NODE3_MODELS"):
            for val in profile_all_exports(text, var):
                groups = {g for row in catalog.values() for g in row["groups"]}
                for tok in val.split():
                    if tok not in catalog and tok not in groups:
                        bad("profile-models", "%s %s" % (name, tok), "not a catalog tag or install group")

    # 8. profiles/README.md counts
    readme = read(root, "profiles/README.md")
    parked = glob.glob(os.path.join(root, "profiles", "parked", "*.sh"))
    m = re.search(r"Live profiles \((\d+)\)", readme)
    if not m or int(m.group(1)) != len(live):
        bad("profile-count", "profiles/README.md", "says %s live, %d profiles/dev-*.sh exist" % (m.group(1) if m else "nothing", len(live)))
    m = re.search(r"Seven|(\d+|[A-Za-z]+) server profiles are parked", readme)
    words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9}
    if m:
        word = (m.group(1) or "seven").lower()
        n = int(word) if word.isdigit() else words.get(word)
        if n != len(parked):
            bad("parked-count", "profiles/README.md", "says %s parked, profiles/parked has %d" % (word, len(parked)))
    else:
        bad("parked-count", "profiles/README.md", "no 'N server profiles are parked' sentence found")

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
