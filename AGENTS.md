# Agent Playbook for `octez-manager`

You maintain a **minimal, auditable installer** for Octez systemd services (node, baker, accuser, etc.). Keep scope tight: installers, service lifecycle, and snapshot bootstrap/refresh. Maximize reliability, clarity, compiler-checked safety, and type-driven design.

## Process guardrails
- Maintain a timestamped TODO/checklist; after each item run `dune build @all`, `dune test`, coverage target (if available), and `dune fmt`/`ocamlformat`. Do not proceed with warnings or failures.
- Commit per item (small, logical commits). Keep the tree clean between items; CI should fail on dirty trees. Never amend unless required.
- Preserve/raise coverage; if a change would drop coverage, add/adjust tests first.
- Keep docs/screenshots aligned with behavior in the same commit as changes. Avoid scope creep; stay installer-focused.

## OCaml type discipline (push hard)
- Prefer rich types over ad-hoc strings/booleans; encode state transitions with sum types, abstract types, and module boundaries. Lean on `result` for error-aware APIs; prefer `result`/`option` over exceptions for recoverable errors.
- Use phantom types/GADTs to make invalid states unrepresentable (e.g., privilege modes, service states, validated paths/networks).
- Expose minimal public signatures; keep concrete representations private. Let the compiler enforce invariants; avoid partial functions and unchecked exceptions.
- Use type-directed parsers/formatters instead of stringly-typed configs. Prefer `eio` over `lwt` for async/concurrency. Do not use `Obj.magic` (forbidden).

## Reuse from `octez-setup` (adapt, don’t copy blindly)
- Tests: port/slim `test/test_service_lifecycle.ml`, `test/test_system_capability.ml`, `test/service_manager_access.ml` for systemd/user start/stop/enable/permissions/error paths. Reuse snapshot simulators (`test/stream_sim.ml`, `test/download_snapshot.ml`, `test/json_stream_*`) to cover “import snapshot before start” and failure handling.
- UX wording: installer-first language, privilege badges (● SYSTEM / ● USER), concise prompts/non-root affordances; only what fits install wizards and service management.
- Docs/screenshots: short walkthrough + screenshot tour, trimmed to installs and instance management.
- Packaging/automation: slim Makefile + opam pinning (e.g., `miaou`), CI snippets (`dune build/test/fmt`, coverage), enforce clean worktree.
- Defensive patterns: privilege/capability checks around `systemctl`, permissions, and non-root operation in installer flows.

## Style/tooling defaults
- Pin OCaml/toolchain versions and `ocamlformat` version; document them in README/TODO.
- Prefer `-warn-error +A` (or equivalent) in dune for library code. Require `.mli` for public modules; keep concrete types abstract.
- Avoid global mutable state; pass capabilities explicitly.

## Security/permissions stance
- Default to least privilege; log and surface when falling back (e.g., missing `systemctl`). No secrets in logs; sanitize paths/URLs before printing.
- Treat network fetches (snapshots) as untrusted: checksum/size checks, timeouts, retries; surface errors clearly.

## Error/telemetry
- Standardize result/error reporting and logging format for CLI/TUI actions; no silent failures. Each external call should surface errors in a parseable/loggable way.

## Release/ops checklist
- Before release/branch cut: run full build/test/coverage, refresh docs/screenshots, note dependency pins (e.g., `miaou`), ensure clean tree.

## Daily discipline
- Before coding: update TODO, restate goal, ensure clean tree.
- During coding: add only succinct comments where logic isn’t obvious; design types first.
- After coding: format, test, coverage, docs, update TODO, then commit with a clear message.
- Never revert user changes or run destructive commands without explicit instruction.
