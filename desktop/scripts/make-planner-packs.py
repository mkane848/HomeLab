#!/usr/bin/env python3
"""Build experiment 3's planner packs (docs/planner-tests-experiment.md, "The planner").

One folder per task under <out>/tasks/<id>/: TASK.md (the request, exactly as the executor gets it) and base.bundle (the
task's repository at its pinned base commit with its history and nothing later: no solution, no hidden tests, no other
branch). The planner container mounts the result read-only (desktop/scripts/run-planner.ps1).

  python -I desktop/scripts/make-planner-packs.py --manifest <HomeLab-private>/tasks/manifest.json --out <folder> \
      --tasks real-01,real-02,real-03,wp-1a,wp-5b,wp-6f

Two options for the confirmation checkpoint (run-planner.ps1 -Phase done|tests):
  --prompts DIR     copy PROMPT.md, DONE-PROMPT.md and TESTS-PROMPT.md from DIR (the private planner folder) into the
                    pack, whichever exist.
  --confirmed DIR   copy each DIR/<task>/<run>/DONE.md into the pack's planner/<task>/<run>/, for the tests phase.
                    Refuses a list the owner has not confirmed, or has changed since (planner_done.py verify).

The bundle is made from a short-lived ref (refs/homelab-planner/<id>) that is deleted again, and re-made from a throwaway
repository so its HEAD is a branch (`base`) a clone can check out.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import planner_done  # noqa: E402


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tasks", required=True)
    ap.add_argument("--prompts")
    ap.add_argument("--confirmed")
    a = ap.parse_args()
    manifest = json.load(open(a.manifest, encoding="utf-8"))
    by_id = {t["id"]: t for t in manifest["tasks"]}
    for tid in [x.strip() for x in a.tasks.split(",") if x.strip()]:
        t = by_id.get(tid)
        if not t:
            sys.exit(f"no task {tid} in the manifest")
        repo, base = t["repo"], t["benchBaseCommit"]
        d = os.path.join(a.out, "tasks", tid)
        os.makedirs(d, exist_ok=True)
        ref = f"refs/homelab-planner/{tid}"
        git("-C", repo, "update-ref", ref, base)
        stage = tempfile.mkdtemp(prefix="planner-stage-")
        try:
            # A bundle, not a fetch from the checkout: git upload-pack refuses a repository owned by another account
            # (LFCbot's .git on the desktop), whatever safe.directory says (AGENTS.md -> test-sealed-checkout.ps1).
            first = os.path.join(stage, "first.bundle")
            git("-C", repo, "bundle", "create", "-q", first, ref)
            work = os.path.join(stage, "repo")
            git("init", "-q", work)
            git("-C", work, "fetch", "-q", first, f"{ref}:refs/heads/base")
            git("-C", work, "symbolic-ref", "HEAD", "refs/heads/base")
            git("-C", work, "bundle", "create", "-q", os.path.join(d, "base.bundle"), "base", "HEAD")
        finally:
            git("-C", repo, "update-ref", "-d", ref)
            shutil.rmtree(stage, ignore_errors=True)
        with open(os.path.join(d, "TASK.md"), "w", encoding="utf-8", newline="\n") as f:
            f.write(t["prompt"].rstrip() + "\n")
        print(tid, base[:10], git("-C", repo, "rev-list", "--count", base), "commits")
        if a.confirmed:
            copy_confirmed(a.confirmed, a.out, tid)
    if a.prompts:
        for name in ("PROMPT.md", "DONE-PROMPT.md", "TESTS-PROMPT.md"):
            src = os.path.join(a.prompts, name)
            if os.path.isfile(src):
                shutil.copyfile(src, os.path.join(a.out, name))
                print("prompt", name)


def copy_confirmed(src_root, out, tid):
    """Each <src_root>/<tid>/<run>/DONE.md into <out>/planner/<tid>/<run>/, only if it is confirmed and unchanged."""
    task_dir = os.path.join(src_root, tid)
    runs = sorted(r for r in (os.listdir(task_dir) if os.path.isdir(task_dir) else [])
                  if os.path.isfile(os.path.join(task_dir, r, "DONE.md")))
    if not runs:
        sys.exit(f"--confirmed: no {tid}/<run>/DONE.md under {src_root}")
    for run in runs:
        src = os.path.join(task_dir, run, "DONE.md")
        text = planner_done.read(src)
        try:
            ok, msg, _ = planner_done.verify(text)
        except planner_done.Malformed as e:
            sys.exit(f"--confirmed: {src}: {e}")
        if not ok:
            sys.exit(f"--confirmed: {src}: {msg}")
        dst = os.path.join(out, "planner", tid, run)
        os.makedirs(dst, exist_ok=True)
        shutil.copyfile(src, os.path.join(dst, "DONE.md"))
        print(" ", tid, "run", run, "DONE.md", msg)


if __name__ == "__main__":
    main()
