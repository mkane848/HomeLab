#!/usr/bin/env python3
"""Numstat every non-merge commit in the window; bucket files; emit shortlist candidates.

Read-only against the working copy at ./repo (a `git clone --local` of the mirror).
"""
import re, subprocess, json, sys, os

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(S, "repo")

def git(*args):
    return subprocess.check_output(["git", "-C", REPO, *args], text=True, errors="replace")

TEST_RE = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$)|(/__tests__/)|(^tests?/)")
CODE_RE = re.compile(r"\.(ts|tsx|js|jsx|mjs|cjs)$")

def bucket(path):
    p = path
    if p == "package-lock.json" or p.endswith("/package-lock.json") or p.endswith("pnpm-lock.yaml"):
        return "lock"
    if TEST_RE.search(p):
        return "test"
    if p.endswith(".snap"):
        return "snap"
    if p.endswith(".css"):
        return "css"
    if p.endswith(".md") or p.startswith("docs/") or p.startswith("Planning Docs/") or p.startswith("skills/") or p.startswith(".claude/") or p.startswith(".agents/"):
        return "docs"
    if p.endswith(".sql"):
        return "sql"
    if p.endswith("package.json") or p.endswith(".json") or p.endswith(".yml") or p.endswith(".yaml") or p.endswith(".toml"):
        return "config"
    if p.startswith(".github/") or p.startswith("scripts/"):
        return "ci-script"
    if CODE_RE.search(p):
        if p.startswith("apps/") or p.startswith("packages/"):
            return "src"
        if p.startswith("scripts/"):
            return "ci-script"
        return "config"  # e.g. eslint.config.js at root
    return "other"

rows = []
for line in open(os.path.join(S, "window.tsv")):
    sha, npar, fp, date, subj = line.rstrip("\n").split("\t", 4)
    rows.append(dict(sha=sha, npar=int(npar), fp=fp, date=date, subj=subj))

out = []
for r in rows:
    if r["npar"] != 1 and r["npar"] != 0:
        r["kind"] = "merge"
        out.append(r)
        continue
    if r["npar"] == 0:
        r["files"] = []
        r["kind"] = "root"
        out.append(r)
        continue
    ns = git("show", "--numstat", "--format=", "--no-renames", r["sha"])
    files = []
    for l in ns.splitlines():
        if not l.strip():
            continue
        a, d, path = l.split("\t", 2)
        a = 0 if a == "-" else int(a)
        d = 0 if d == "-" else int(d)
        files.append((path, a, d, bucket(path)))
    r["files"] = files
    r["kind"] = "commit"
    r["parent"] = git("rev-parse", r["sha"] + "^").strip()
    out.append(r)

# persist raw
with open(os.path.join(S, "numstat.json"), "w") as f:
    json.dump(out, f)

# summary buckets per commit
def summ(r):
    c = {}
    for path, a, d, b in r.get("files", []):
        c.setdefault(b, []).append((path, a, d))
    return c

with open(os.path.join(S, "commit-table.tsv"), "w") as f:
    f.write("sha\tdate\tkind\tn_src\tn_test\tn_docs\tn_css\tn_cfg\tn_lock\tn_other\tsrc_pm\ttest_pm\tsubject\n")
    for r in out:
        if r["kind"] == "merge":
            f.write(f'{r["sha"][:7]}\t{r["date"][:10]}\tmerge\t\t\t\t\t\t\t\t\t\t{r["subj"]}\n')
            continue
        c = summ(r)
        def n(k): return len(c.get(k, []))
        def pm(k):
            a = sum(x[1] for x in c.get(k, [])); d = sum(x[2] for x in c.get(k, []))
            return f"+{a}/-{d}"
        f.write("\t".join([
            r["sha"][:7], r["date"][:10], r.get("kind", "commit"),
            str(n("src")), str(n("test")), str(n("docs")), str(n("css")),
            str(n("config") + n("sql") + n("ci-script")), str(n("lock")),
            str(n("other") + n("snap")), pm("src"), pm("test"), r["subj"]]) + "\n")
print("wrote numstat.json and commit-table.tsv;", len(out), "rows")
