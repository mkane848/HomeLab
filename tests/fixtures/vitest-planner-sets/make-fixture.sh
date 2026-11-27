#!/usr/bin/env bash
# make-fixture.sh <project dir> <out file> <case>: resets src/ to the base, places the set for <case>, runs vitest, saves its output.
set -u
d=$1; out=$2; sc=$3
rm -rf "$d/src" && mkdir -p "$d/src"
printf 'export function sum(a, b) { return a + b }\n' > "$d/src/sum.js"
base_test='import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("adds", () => { expect(sum(1, 2)).toBe(3) })\n'
printf "$base_test" > "$d/src/sum.test.js"
cmd=(npx vitest run src/sum.test.js)
case $sc in
  ok)            printf 'import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("adds", () => { expect(sum(1, 2)).toBe(3) })\nit("G1 adds three", () => { expect(sum(1, 2, 3)).toBe(6) })\n' > "$d/src/sum.test.js" ;;
  passes)        printf 'import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("G1 adds", () => { expect(sum(2, 2)).toBe(4) })\n' > "$d/src/sum.test.js" ;;
  missing-import) printf 'import { expect, it } from "vitest"\nimport { mul } from "./mul.js"\nit("G1 multiplies", () => { expect(mul(2, 3)).toBe(6) })\n' > "$d/src/sum.test.js" ;;
  syntax)        printf 'import { expect, it } from "vitest"\nit("G1 broken", () => { expect(1).toBe(1) \n' > "$d/src/sum.test.js" ;;
  not-run)       printf 'import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("G1 adds three", () => { expect(sum(1, 2, 3)).toBe(6) })\n' > "$d/src/sum-three.test.js" ;;
  all-ok)        cmd=(npx vitest run); printf 'import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("G1 adds three", () => { expect(sum(1, 2, 3)).toBe(6) })\n' > "$d/src/sum-three.test.js" ;;
  all-missing)   cmd=(npx vitest run); printf 'import { expect, it } from "vitest"\nimport { mul } from "./mul.js"\nit("G1 multiplies", () => { expect(mul(2, 3)).toBe(6) })\n' > "$d/src/mul.test.js" ;;
  elsewhere)     cmd=(npx vitest run); printf 'import { expect, it } from "vitest"\nit("old", () => { expect(1).toBe(2) })\n' > "$d/src/old.test.js"; printf 'import { expect, it } from "vitest"\nimport { sum } from "./sum.js"\nit("G1 adds", () => { expect(sum(2, 2)).toBe(4) })\n' > "$d/src/sum-two.test.js" ;;
esac
(cd "$d" && CI=1 "${cmd[@]}" > "$out" 2>&1; echo "exit=$?" >> "$out")
