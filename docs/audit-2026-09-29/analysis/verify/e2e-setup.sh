#!/usr/bin/env bash
# End-to-end: run the REAL run-tasks-batch.ps1 -SetupOnly against fixture repos.
set -u
SP=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify
W=$SP/e2e
rm -rf "$W" && mkdir -p "$W/tests/tasks" "$W/tests/results"
cp /home/user/HomeLab/tests/run-tasks-batch.ps1 /home/user/HomeLab/tests/test-tasks.ps1 "$W/tests/"

git init -q --bare "$W/origin.git"
mk() { git init -q "$1" && git -C "$1" symbolic-ref HEAD refs/heads/main && git -C "$1" config user.email t@example.invalid && git -C "$1" config user.name t; }
cm() { echo "$2" > "$1/f.txt" && git -C "$1" add -A && git -C "$1" commit -q -m "$2"; git -C "$1" rev-parse HEAD; }

# One repo with a real origin. main is pushed; then:
#   PUB  - a commit on main                       (published: silent)
#   PRO  - a commit only refs/pull/1/head reaches (published: silent - kane-01's shape)
#   LOC  - a commit only in this clone            (unpublished: WARN + push command)
#   ACC  - an acceptance commit only in this clone (unpublished: WARN + push command)
mk "$W/r1"; git -C "$W/r1" remote add origin "$W/origin.git"
PUB=$(cm "$W/r1" pub); git -C "$W/r1" push -q origin main 2>/dev/null
git -C "$W/r1" checkout -q -b prb; PRO=$(cm "$W/r1" pr-only); git -C "$W/r1" push -q origin prb:refs/pull/1/head 2>/dev/null
git -C "$W/r1" checkout -q main; git -C "$W/r1" checkout -q -b loc; LOC=$(cm "$W/r1" local-only)
git -C "$W/r1" checkout -q -b bench/acc; ACC=$(cm "$W/r1" acceptance); git -C "$W/r1" checkout -q main

cat > "$W/tests/tasks/manifest.json" <<EOF
{ "tasks": [
  { "id": "t-main",   "repo": "$W/r1", "branch": "bench/a", "benchBaseCommit": "$PUB" },
  { "id": "t-prref",  "repo": "$W/r1", "branch": "bench/b", "benchBaseCommit": "$PRO" },
  { "id": "t-local",  "repo": "$W/r1", "branch": "bench/c", "benchBaseCommit": "$LOC",
    "acceptance": { "ref": "bench/acc", "commit": "$ACC", "files": ["f.txt"] } },
  { "id": "t-noacc",  "repo": "$W/r1", "branch": "bench/d", "benchBaseCommit": "$PUB",
    "acceptance": { "ref": "bench/missing", "files": ["f.txt"] } }
] }
EOF

echo "=== run 1 (branches get created)"
pwsh -NoProfile -File "$W/tests/run-tasks-batch.ps1" -SetupOnly 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
echo "=== after publishing the local commit and the acceptance commit"
git -C "$W/r1" push -q origin "$LOC:refs/heads/bench/c" 2>/dev/null; git -C "$W/r1" push -q origin "$ACC:refs/heads/bench/acc" 2>/dev/null
pwsh -NoProfile -File "$W/tests/run-tasks-batch.ps1" -SetupOnly 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
