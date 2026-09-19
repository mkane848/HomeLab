<!--
  PR title: one line, matches the repo convention, e.g.
    "docs: add CHANGELOG.md following Keep a Changelog 1.0.0"
-->
## What

<!-- One or two sentences: what this change does. No need to repeat the diff. -->

## Why

<!-- The problem this solves, or the decision this records. If it's a docs change,
     say who will read it and what it commits the repo to. -->

## Verification

<!-- How did you confirm this actually works? For code/scripts include the exact
     command(s) run. A green suite is necessary, not sufficient — see
     docs/review-gate/testing.md. Do not claim "verified" on a suite you never
     ran, or on a test that never entered the branch it names. -->

- [ ] Ran the relevant checks (`tests/test-profiles.ps1`, `tests/test-toolcalls.ps1`, syntax checks per AGENTS.md)
- [ ] Model-written change: audited every new test against the branch it claims to cover
- [ ] Changelog: added/updated the `[Unreleased]` entry in `CHANGELOG.md`, or confirmed one is not warranted

## Anything else

<!-- Deviation from protocol, stale docs that should be flagged, follow-ups. -->