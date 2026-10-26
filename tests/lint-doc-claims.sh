#!/usr/bin/env bash
# Fails when a public doc repeats a claim that docs/adversarial-review-2026-10-23.md
# ("What to stop claiming") retired, or quotes a p-value in a headline doc.
# Internal logs (roadmap, CHANGELOG, trials, reviews, archive) are not checked: they keep
# the history. Run from anywhere: bash tests/lint-doc-claims.sh
set -u
cd "$(dirname "$0")/.."

public=(README.md CONTRIBUTING.md docs/README.md docs/start-here.md docs/profiles.md
  docs/hardware.md docs/network-topology.md docs/costs.md docs/troubleshooting.md
  docs/tool-calling.md docs/glossary.md docs/vscode.md docs/target-setup.md
  docs/methodology-caveats.md)

phrases='98% vs 89%|28 of 28|host does not matter|host doesn.t matter|27% more output|1\.02 attempts'
pvalue='\bp ?[=<≈] ?0\.[0-9]+|p-value'

bad=0
for f in "${public[@]}"; do
  [ -f "$f" ] || continue
  # the caveats page names the retired phrases and p-values on purpose
  [ "$f" = docs/methodology-caveats.md ] && continue
  if hits=$(grep -nEi "$phrases" "$f"); then
    echo "$hits" | sed "s|^|$f:|; s|\$|   <- retired claim|"; bad=1
  fi
  if hits=$(grep -nE "$pvalue" "$f"); then
    echo "$hits" | sed "s|^|$f:|; s|\$|   <- p-value in a headline doc|"; bad=1
  fi
done

if [ "$bad" -ne 0 ]; then
  echo "lint-doc-claims: FAIL (see docs/adversarial-review-2026-10-23.md, 'What to stop claiming')"
  exit 1
fi
echo "lint-doc-claims: OK (${#public[@]} public docs)"
