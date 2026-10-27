#!/usr/bin/env python3
"""Classify every commit in the window. Rules first, then a manual override table (short sha -> class, reason).
Classes: fix, feature, refactor, docs, chore, test-only, release-bump, merge-PR, merge-sync, root.
"""
import json, os, re, collections

S = os.path.dirname(os.path.abspath(__file__))
data = json.load(open(os.path.join(S, "numstat.json")))

# --- manual overrides after eyeballing the diffs/subjects (short sha -> (class, note)) ---
OVERRIDE = {
    # css-only / layout "fix" commits: still fixes, but CSS/layout only (not testable with unit tests)
    # keep class 'fix' and tag with '(css-only)' via bucket rule below
}

def buckets(r):
    c = collections.Counter()
    for path, a, d, b in r.get("files", []):
        c[b] += 1
    return c

def classify(r):
    subj = r["subj"]
    ls = subj.lower()
    if r["kind"] == "merge":
        if subj.startswith("Merge pull request"):
            return "merge-PR"
        return "merge-sync"
    if r["kind"] == "root":
        return "docs"
    b = buckets(r)
    nsrc, ntest = b["src"], b["test"]
    ncss, ndocs = b["css"], b["docs"]
    ncfg = b["config"] + b["sql"] + b["ci-script"] + b["other"] + b["snap"]
    nlock = b["lock"]
    total = sum(b.values())
    # release bumps / lockfile syncs
    if re.match(r"^(bump to|chore: (bump|sync)|fix: sync package-lock|refresh package-lock|cut 0\.)", ls):
        return "release-bump"
    if total == 0:
        return "chore"
    if ntest and not nsrc and not ndocs and not ncss:
        return "test-only"
    if nsrc == 0 and ntest == 0:
        # docs / css / config-only commits
        if ndocs and not ncss and not ncfg:
            return "docs"
        if ndocs and ncfg and not ncss and re.search(r"(document|docs|handoff|claude\.md|readme|work ?plan|audit|archive|record|note)", ls):
            return "docs"
        if ncss and not ncfg:
            return "fix-css" if re.match(r"^(fix|.*\bfix\b)", ls) else "style-css"
        if re.search(r"(^ci\b|\bci\b|github|render|dockerfile|migration|schema|rls|eslint|deps|dependency|lint)", ls):
            return "chore"
        if ncfg and not ndocs:
            return "fix-config" if re.match(r"^fix", ls) else "chore"
        return "docs" if ndocs else "chore"
    # touches source
    if re.match(r"^(refactor|convert|extract|split|move|rename|tokenise|put the stylesheets)", ls) or "css modules" in ls:
        return "refactor"
    if re.match(r"^(fix|hotfix)", ls) or re.match(r"^fix\(", ls) or re.search(r"\bfix(es)?\b|crash|regression|correct(ion)?\b|never written", ls):
        return "fix"
    if re.match(r"^(perf|a11y)", ls):
        return "chore" if nsrc == 0 else "refactor" if "refactor" in ls else "feature"
    if re.match(r"^(chore|ci|build)", ls):
        return "chore"
    if re.match(r"^docs", ls):
        return "docs"
    return "feature"

res = []
for r in data:
    cls = classify(r)
    short = r["sha"][:7]
    if short in OVERRIDE:
        cls, note = OVERRIDE[short]
    r["cls"] = cls
    res.append(r)

json.dump(res, open(os.path.join(S, "classified.json"), "w"))
with open(os.path.join(S, "classified.tsv"), "w") as f:
    f.write("sha\tdate\tfp\tcls\tn_src\tn_test\tn_docs\tn_css\tsubject\n")
    for r in res:
        b = buckets(r)
        f.write("\t".join([r["sha"][:7], r["date"][:10], r["fp"], r["cls"], str(b["src"]), str(b["test"]), str(b["docs"]), str(b["css"]), r["subj"]]) + "\n")

cnt = collections.Counter(r["cls"] for r in res)
print(cnt)
