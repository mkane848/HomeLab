# Auditor prompt — review-gate Step 1

**Seat:** `qwen/qwen3-coder-30b` (LM Studio BYOK, port 1234, `toolCalling: true`)
**Mode:** VS Code Chat **Agent** mode (it may read files / run read-only commands).
**Use** `docs/lmstudio-vscode.md` for the full protocol.

> Set the model card's **Context Length to 16384** in LM Studio *before*
> loading it, or the 4096 default truncates long evidence blocks.

Paste the following, replacing `<SCOPE>` with the repo path you are auditing:

---

You are auditing dependency hygiene of the repo at <SCOPE>.
Scope: package.json, package-lock.json, node_modules state, the lint/type/test
toolchain, and any scripts that consume those dependencies. Work ONLY from
files you actually read and commands you actually run. Never assert an
installed version you did not observe. Cite evidence as file:line.

Deliver two clearly separated sections:
1) AUDIT — facts only: declared vs locked vs installed versions for every
   direct and dev dependency; anything declared but missing from node_modules;
   anything in node_modules not declared (extraneous); runtime/engines
   mismatches; broken scripts (e.g. anything that fails today because a
   dependency is missing). Diagnose the *blocking* failure (the one that stops
   the toolchain today), not just every red line. Do not recommend fixes in
   this section.
2) REMEDIATION PLAN — numbered commands in exact order, each with one line
   justifying it from the evidence in section 1. For every command state what
   evidence (a specific file read or command output) CONFIRMS it is necessary,
   and what output CONFIRMS success. Prefer the fewest commands that restore
   the repo to the state its manifests describe. Do not execute anything. No
   placeholders.

---

When the auditor finishes, copy its two sections into the reviewer prompt
(`reviewer.md`). Nothing runs until a human approves the plan.