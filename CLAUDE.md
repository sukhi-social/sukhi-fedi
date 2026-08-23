# sukhi-fedi

Read first:

- `docs/ARCHITECTURE.md` — canonical; where processes run and why.
- `docs/CODE_STYLE.md` — the separation style; where concerns live.

The one rule from CODE_STYLE.md: **every security or performance
property lives in exactly one place, and structure routes all paths
through it.** Check once at the boundary, trust inside; pay once per
batch, never per item. Before finishing any change, walk the
checklist in CODE_STYLE.md §7.

Practical notes:

- Toolchain: `mise.toml` pins Elixir/OTP to what the Dockerfile
  builds with. `mise trust` once per checkout, then plain `mix`
  is the right version — no per-command prefix.
- Entry points all live in the Makefile — `make` lists them.
  `make dev` runs the whole thing locally with no Docker.
- Tests: `make test` (unit, every layer), `make test-pglite`
  (DB integration, no docker).
- TypeScript in `bun/` is checked with `bun run check` (type-only).
- Every source file starts with
  `# SPDX-License-Identifier: AGPL-3.0-or-later`.
