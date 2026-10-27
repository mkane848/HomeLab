#!/usr/bin/env python3
"""Numstat classification of every commit dated >= 2026-09-13 in the ASoHaV mirror clone.

Writes:
  commits-numstat.tsv : one row per non-merge commit in the window with src/test/other split
  window-all.tsv      : all commits (merge + non-merge) with a coarse type guess
"""
import re
import subprocess
import sys
from collections import Counter

REPO = "/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-asohav-new/repo"
OUT = "/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-asohav-new"
WINDOW_START = "2026-09-13"


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=True).stdout


def file_kind(path):
    p = path
    if re.search(r"(^|/)(__snapshots__)/|\.snap$", p):
        return "snap"
    if re.search(r"\.test\.(ts|tsx|mjs|js)$", p) or "/__tests__/" in p:
        return "test"
    if re.search(r"(smoke|harness)[^/]*\.(mjs|js|ts|html)$", p) and "/scripts/" in p:
        return "smoke"
    if p == "package-lock.json":
        return "lock"
    if p.endswith(".md") or p.startswith("docs/") or p.startswith("Planning Docs/"):
        return "docs"
    if p.endswith(".css"):
        return "css"
    if p.startswith("supabase/") or p.endswith(".sql"):
        return "sql"
    if p.endswith("package.json") or "tsconfig" in p or p.startswith(".github/") or p in (
        "render.yaml", "eslint.config.js", "skills-lock.json", ".gitignore"
    ) or p.startswith("scripts/") or p.endswith(".yml") or p.endswith(".yaml"):
        return "cfg"
    if re.search(r"\.(ts|tsx)$", p) and re.search(r"(^|/)src/", p):
        return "src"
    if re.search(r"\.(ts|tsx|mjs|js)$", p):
        return "srcother"
    return "other"


def parse_numstat(sha):
    out = git("show", "--numstat", "--format=", "--no-renames", sha)
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        a, d, path = line.split("\t", 2)
        a = 0 if a == "-" else int(a)
        d = 0 if d == "-" else int(d)
        rows.append((path, a, d, file_kind(path)))
    return rows


def coarse_type(subject, rows, nparents):
    s = subject.lower()
    if nparents > 1 or s.startswith("merge "):
        return "merge"
    kinds = Counter(r[3] for r in rows)
    if not rows:
        return "empty"
    non_doc = {k for k in kinds if k not in ("docs",)}
    if not non_doc:
        return "docs"
    if re.match(r"^(ship|release) \d", s):
        return "release"
    return "?"


def main():
    lines = git("log", "--format=%H%x09%P%x09%ad%x09%an%x09%s", "--date=iso").splitlines()
    commits = []
    for ln in lines:
        sha, parents, date, author, subject = ln.split("\t", 4)
        if date[:10] >= WINDOW_START:
            commits.append((sha, parents.split(), date, author, subject))
    print(f"{len(commits)} commits in window", file=sys.stderr)
    with open(f"{OUT}/commits-numstat.tsv", "w") as fh:
        fh.write("sha\tparent\tdate\tauthor\tnparents\tsubject\tn_src\tsrc_add\tsrc_del\tn_test\ttest_add\ttest_del\tn_css\tn_docs\tn_cfg\tn_sql\tn_smoke\tn_other\tsrc_files\ttest_files\ttype_guess\n")
        for sha, parents, date, author, subject in commits:
            rows = parse_numstat(sha) if len(parents) == 1 else []
            by = {}
            for path, a, d, k in rows:
                by.setdefault(k, []).append((path, a, d))

            def tot(k):
                return sum(x[1] for x in by.get(k, [])), sum(x[2] for x in by.get(k, []))

            sa, sd = tot("src")
            ta, td = tot("test")
            src_files = ";".join(f"{p}(+{a}/-{d})" for p, a, d in by.get("src", []))
            test_files = ";".join(f"{p}(+{a}/-{d})" for p, a, d in by.get("test", []))
            n_other = sum(len(by.get(k, [])) for k in ("other", "srcother", "snap", "lock"))
            fh.write("\t".join(map(str, [
                sha[:7], parents[0][:7] if parents else "", date[:16], author, len(parents), subject,
                len(by.get("src", [])), sa, sd, len(by.get("test", [])), ta, td,
                len(by.get("css", [])), len(by.get("docs", [])), len(by.get("cfg", [])), len(by.get("sql", [])),
                len(by.get("smoke", [])), n_other, src_files, test_files,
                coarse_type(subject, rows, len(parents)),
            ])) + "\n")


if __name__ == "__main__":
    main()
