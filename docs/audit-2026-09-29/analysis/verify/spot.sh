#!/usr/bin/env bash
# Independent spot-check of four candidates reported by the mining agents.
# Each: fresh `git worktree add --detach` at the PARENT from the agent's own clone, install, baseline -> red -> green.
S=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad
V=$S/verify
export GIT_LFS_SKIP_SMUDGE=1
sum() { grep -E "^ +(Tests|Test Files) " | sed 's/^ *//' | tr '\n' ' '; echo; }

echo "##### 1. asohav-03 glossary depth flatten (packages/shared)"
R=$S/mine-asohav-old/repo; W=$V/glossary; PARENT=5c891936847a844bb23dd74b02aa1fa6f1525f84; FIX=3003542385e2e83a862ff648b69ea0a8f9873da6
rm -rf "$W"; git -C "$R" worktree prune; git -C "$R" worktree add -q --detach "$W" $PARENT || exit 1
( cd "$W" && npm ci --ignore-scripts >/dev/null 2>&1; echo "parent=$(git rev-parse --short HEAD)"
  cd packages/shared
  printf "BASELINE  "; npx vitest run src/glossary.test.ts 2>&1 | sum
  git checkout -q $FIX -- src/glossary.test.ts
  printf "RED       "; npx vitest run src/glossary.test.ts 2>&1 | sum
  git checkout -q $FIX -- src/glossary.ts
  printf "GREEN     "; npx vitest run src/glossary.test.ts 2>&1 | sum )

echo; echo "##### 2. lfc-bot admin permission bit (Manage Server vs Administrator)"
R=$S/mine-lfc/repo; W=$V/admin; PARENT=e644702a6ce9753b69ca3291e1bdc388e2d1a7d3; FIX=0e9d123
rm -rf "$W"; git -C "$R" worktree prune; git -C "$R" worktree add -q --detach "$W" $PARENT || exit 1
( cd "$W" && npm ci --ignore-scripts >/dev/null 2>&1; echo "parent=$(git rev-parse --short HEAD)"
  printf "BASELINE  "; env -u MANAPOOL_API_KEY npx vitest run tests/commands/admin/admin.test.ts 2>&1 | sum
  git checkout -q $FIX -- tests/commands/admin/admin.test.ts
  printf "RED       "; env -u MANAPOOL_API_KEY npx vitest run tests/commands/admin/admin.test.ts 2>&1 | sum
  git checkout -q $FIX -- src/commands/admin/admin.ts
  printf "GREEN     "; env -u MANAPOOL_API_KEY npx vitest run tests/commands/admin/admin.test.ts 2>&1 | sum )

echo; echo "##### 3. asohav contract->WP slice 9A: rollOdds (red-by-design baseline)"
R=$S/mine-asohav-new/repo; W=$V/odds; PARENT=44ead5d619bb1a26854c0d861aa75a89f14a8fd6; FIX=46e88f5
rm -rf "$W"; git -C "$R" worktree prune; git -C "$R" worktree add -q --detach "$W" $PARENT || exit 1
( cd "$W" && npm ci --ignore-scripts >/dev/null 2>&1; echo "parent=$(git rev-parse --short HEAD)"
  cd packages/shared
  printf "AT PARENT (tests given, stub source) "; npx vitest run src/odds.test.ts 2>&1 | sum
  git checkout -q $FIX -- src/odds.ts
  printf "WITH WP SOURCE                       "; npx vitest run src/odds.test.ts 2>&1 | sum
  echo "diff of test files vs parent after applying only the source: $(git diff --stat -- src/odds.test.ts | wc -l) lines" )

echo; echo "##### 4. KaneEnabler ComboPreferenceRow (javascript: permalink) - React + security"
R=$S/mine-kane/repo; W=$V/combo; PARENT=605a2e080cfddee855337f1b3d0b9cf7e48ddd6e; FIX=271636f41a6e31f24d88f2a8cd8101935b02e76e
rm -rf "$W"; git -C "$R" worktree prune; git -C "$R" worktree add -q --detach "$W" $PARENT || exit 1
( cd "$W"; SRC=$(git show --stat=200 --format= $FIX | grep -E "ComboPreferenceRow\.tsx" | awk '{print $1}'); TST=$(git show --stat=200 --format= $FIX | grep -E "Profile\.test\.tsx" | awk '{print $1}')
  echo "parent=$(git rev-parse --short HEAD) src=$SRC test=$TST"
  pnpm install --frozen-lockfile --ignore-scripts --store-dir "$S/mine-kane/pnpm-store" >/dev/null 2>&1
  cd apps/home
  printf "BASELINE  "; pnpm exec vitest run src/routes/Profile.test.tsx 2>&1 | sum
  cd "$W"; git checkout -q $FIX -- "$TST"; cd apps/home
  printf "RED       "; pnpm exec vitest run src/routes/Profile.test.tsx 2>&1 | sum
  cd "$W"; git checkout -q $FIX -- "$SRC"; cd apps/home
  printf "GREEN     "; pnpm exec vitest run src/routes/Profile.test.tsx 2>&1 | sum )
echo; echo "done"
