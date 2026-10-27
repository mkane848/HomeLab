#!/usr/bin/env bash
# How does `git fetch origin <sha>` behave against a local bare origin?
set -u
W=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify/fbs
rm -rf "$W"; mkdir -p "$W"; cd "$W"
git --version
git init -q --bare origin.git
git init -q work && cd work
git config user.email t@e.invalid && git config user.name t
git symbolic-ref HEAD refs/heads/main
git remote add origin ../origin.git
c() { echo "$1" > f && git add -A && git commit -q -m "$1" && git rev-parse HEAD; }
A=$(c a); B=$(c b); git push -q origin main 2>/dev/null          # B is the tip of main, A an ancestor
git checkout -q -b topic; T=$(c topic-only); git push -q origin topic:refs/pull/1/head 2>/dev/null   # only on a PR-style ref
git checkout -q main; git checkout -q -b local; L=$(c local-only)  # never pushed
echo "A(ancestor of main)=$A"; echo "B(tip of main)=$B"; echo "T(only refs/pull/1/head)=$T"; echo "L(local only)=$L"

probe() {  # label sha
  rm -rf ../probe && git init -q ../probe && (cd ../probe && git remote add origin ../origin.git
    if git fetch -q origin "$2" 2>../probe.err; then echo "  $1: FETCHED"; else echo "  $1: refused -> $(tr '\n' ' ' < ../probe.err | cut -c1-90)"; fi)
}
for cfg in default allowReachable allowAny; do
  case $cfg in
    default) ;;
    allowReachable) git -C ../origin.git config uploadpack.allowReachableSHA1InWant true ;;
    allowAny) git -C ../origin.git config uploadpack.allowAnySHA1InWant true ;;
  esac
  echo "== origin config: $cfg"
  probe "tip of main   " $B
  probe "ancestor of main" $A
  probe "PR-ref-only    " $T
  probe "never pushed   " $L
done
