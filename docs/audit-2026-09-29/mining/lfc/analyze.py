#!/usr/bin/env python3
"""Classify every commit in the lfc-bot mirror and shortlist fix-type changes.

Reads the local working clone (read-only use of git) and writes:
  commits.tsv    - one row per commit (all 174), with class + file stats
  shortlist.tsv  - fix-type candidates touching 1-3 non-test src files + test files
"""
import subprocess, re, sys, os, csv, collections

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repo")
OUT = os.path.dirname(os.path.abspath(__file__))


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=True).stdout


def is_test(p):
    return p.startswith("tests/") or ".test." in p or ".spec." in p or "/__tests__/" in p


def is_doc(p):
    return p.endswith(".md") or p.startswith("docs/") or p in ("LICENSE",) or p.endswith(".html")


def is_lock(p):
    return p in ("package-lock.json",) or p.endswith("lock.json") or p.endswith(".lock")


def is_config(p):
    return (
        p.startswith(".github/")
        or p in ("package.json", "tsconfig.json", "tsconfig.eslint.json", "eslint.config.js", "drizzle.config.ts",
                 "Dockerfile", "docker-compose.yml", "docker-compose.prebuilt.yml", ".gitignore", ".dockerignore",
                 ".prettierrc", ".env.example")
        or p.startswith(".claude/")
        or p.startswith("scripts/")
        or p.startswith("drizzle/")
        or p.endswith(".yml") or p.endswith(".yaml")
    )


# ---- gather commits
fmt = "%H|%h|%P|%ad|%cd|%an|%s"
raw = git("log", "--reverse", "--date=short", f"--format={fmt}").strip().splitlines()
commits = []
for line in raw:
    H, h, P, ad, cd, an, s = line.split("|", 6)
    commits.append(dict(H=H, h=h, parents=P.split(), ad=ad, cd=cd, an=an, s=s))

# numstat for non-merge commits
stats = {}
cur = None
out = git("log", "--no-merges", "--numstat", "--format=@@%H").splitlines()
for line in out:
    if line.startswith("@@"):
        cur = line[2:]
        stats[cur] = []
    elif line.strip():
        a, d, f = line.split("\t", 2)
        stats[cur].append((f, a, d))

# for merge commits: diff against first parent (what the PR brought in)
merge_stats = {}
for c in commits:
    if len(c["parents"]) > 1:
        o = git("diff", "--numstat", c["parents"][0], c["H"])
        lst = []
        for line in o.splitlines():
            if line.strip():
                a, d, f = line.split("\t", 2)
                lst.append((f, a, d))
        merge_stats[c["H"]] = lst


def classify(c):
    s = c["s"]
    sl = s.lower()
    files = stats.get(c["H"], [])
    paths = [f for f, _, _ in files]
    if len(c["parents"]) > 1:
        return "merge"
    if re.match(r"^chore\(release\)|^release \d|^bump to \d|^bump version", sl) or re.match(r"^release \d", sl):
        return "release-bump"
    if sl.startswith("bump ") or sl.startswith("build(deps"):
        return "dep-bump"
    if paths and all(is_doc(p) for p in paths):
        return "docs"
    if sl.startswith("docs"):
        return "docs"
    if paths and all(is_test(p) for p in paths):
        return "test-only"
    if sl.startswith("test"):
        return "test-only"
    if sl.startswith("ci") or sl.startswith("chore") or sl.startswith("build"):
        return "chore"
    if sl.startswith("refactor") or "extract " in sl or "migrate " in sl:
        return "refactor"
    if re.match(r"^fix", sl) or " fix " in " " + sl + " " or sl.startswith("fix"):
        return "fix"
    if sl.startswith("feat") or sl.startswith("add "):
        return "feature"
    return "other"


rows = []
for c in commits:
    files = stats.get(c["H"], []) if len(c["parents"]) == 1 else merge_stats.get(c["H"], [])
    src = [(f, a, d) for f, a, d in files if not is_test(f) and not is_doc(f) and not is_lock(f) and not is_config(f)]
    tst = [(f, a, d) for f, a, d in files if is_test(f)]
    c["cls"] = classify(c)
    c["nfiles"] = len(files)
    c["src"] = src
    c["tst"] = tst
    c["files"] = files
    rows.append(c)

with open(os.path.join(OUT, "commits.tsv"), "w") as fh:
    w = csv.writer(fh, delimiter="\t")
    w.writerow(["n", "sha", "parents", "author_date", "commit_date", "class", "nfiles", "src_files", "test_files", "subject"])
    for i, c in enumerate(rows, 1):
        w.writerow([
            i, c["h"], " ".join(p[:7] for p in c["parents"]), c["ad"], c["cd"], c["cls"], c["nfiles"],
            ";".join(f"{f}(+{a}/-{d})" for f, a, d in c["src"]),
            ";".join(f"{f}(+{a}/-{d})" for f, a, d in c["tst"]),
            c["s"],
        ])

cnt = collections.Counter(c["cls"] for c in rows)
print("ALL:", dict(cnt), "total", len(rows))
new = [c for c in rows if c["ad"] >= "2026-09-13"]
print("NEW >=2026-09-13 (author date):", len(new), dict(collections.Counter(c["cls"] for c in new)))
new_cd = [c for c in rows if c["cd"] >= "2026-09-13"]
print("NEW >=2026-09-13 (commit date):", len(new_cd))
newer = [c for c in rows if c["ad"] >= "2026-09-21"]
print(">=2026-09-21 (author date):", len(newer), dict(collections.Counter(c["cls"] for c in newer)))


# ---------------------------------------------------------------- shortlist
def real_src(files):
    """non-test, non-doc, non-lock, non-config, non-migration/snapshot source files"""
    out = []
    for f, a, d in files:
        if is_test(f) or is_doc(f) or is_lock(f) or is_config(f):
            continue
        if f.startswith("src/db/migrations/"):
            continue
        out.append((f, a, d))
    return out


def fmt_files(lst):
    return ";".join(f"{f}(+{a}/-{d})" for f, a, d in lst)


short = []
for c in rows:
    if len(c["parents"]) != 1:
        continue
    if c["cls"] in ("dep-bump", "release-bump", "docs"):
        continue
    srcs = real_src(c["files"])
    tsts = [(f, a, d) for f, a, d in c["files"] if is_test(f)]
    if 1 <= len(srcs) <= 3 and len(tsts) >= 1:
        short.append((c, srcs, tsts))

with open(os.path.join(OUT, "shortlist-auto.tsv"), "w") as fh:
    w = csv.writer(fh, delimiter="\t")
    w.writerow(["sha", "parent", "date", "class(auto)", "subject", "src_files", "test_files", "n_src", "n_test"])
    for c, srcs, tsts in short:
        w.writerow([c["h"], c["parents"][0][:7], c["ad"], c["cls"], c["s"], fmt_files(srcs), fmt_files(tsts), len(srcs), len(tsts)])
print("auto-shortlist rows:", len(short))


# ------------------------------------------------ scoped-down (src,test) pairs
def mirror_test(src):
    # src/a/b.ts -> tests/a/b.test.ts
    m = re.match(r"src/(.+)\.ts$", src)
    return f"tests/{m.group(1)}.test.ts" if m else None


pairs = []
for c in rows:
    if len(c["parents"]) != 1 or c["cls"] in ("dep-bump", "release-bump", "docs"):
        continue
    fmap = {f: (a, d) for f, a, d in c["files"]}
    for f, (a, d) in fmap.items():
        if is_test(f) or is_doc(f) or is_lock(f) or is_config(f) or f.startswith("src/db/migrations/"):
            continue
        t = mirror_test(f)
        if t and t in fmap:
            pairs.append((c, f, (a, d), t, fmap[t]))

with open(os.path.join(OUT, "scoped-pairs-auto.tsv"), "w") as fh:
    w = csv.writer(fh, delimiter="\t")
    w.writerow(["sha", "parent", "date", "class(auto)", "subject", "src", "src+/-", "test", "test+/-", "total_files_in_commit"])
    for c, f, ad, t, td in pairs:
        w.writerow([c["h"], c["parents"][0][:7], c["ad"], c["cls"], c["s"], f, f"+{ad[0]}/-{ad[1]}", t, f"+{td[0]}/-{td[1]}", c["nfiles"]])
print("scoped pair rows:", len(pairs))
