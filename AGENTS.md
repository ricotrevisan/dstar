# AGENTS.md

Guidance for AI agents working in this repository.

## What this is

`dstar` is the batteries-included Datastar toolkit for Elixir — SSE helpers,
event dispatch, CSRF handling, stream deduplication. Successor to
[PhoenixDatastar](https://hex.pm/packages/phoenix_datastar). It works on any
Plug-based app (Phoenix controllers, plain Plug, Bandit); Phoenix and
LiveView are **optional** dependencies used only by the page layer.

## Architecture rules

Respect the two-layer split when adding features:

- **Functional core** — `Dstar.SSE`, `Dstar.Signals`, `Dstar.Elements`,
  `Dstar.Actions`, `Dstar.Scripts`, the `Dstar.Plugs.*`. Depends only on
  `plug` and `jason`. No processes, no application callback, no config, no
  generators.
- **Page layer** — `Dstar.Page`, `Dstar.Component`, `Dstar.Router`, page
  helpers. Opt-in; requires Phoenix/LiveView.

The only process in the package is `Dstar.Utility.StreamRegistry`, and it is
**opt-in** — keep it that way. Prefer pure functions. When the same wire
format is built in two places (e.g. patch vs. `format_patch`), share one
builder instead of inlining a copy.

Keep code compatible with `elixir: "~> 1.14"` (see `mix.exs`) even though CI
runs newer versions.

## CSRF — how the token travels

Phoenix expects the CSRF token in `_csrf_token`, but Datastar treats
`_`-prefixed signal keys as front-end-only and never sends them to the
backend — so the token rides as a **non-prefixed** signal (`csrf`).
Transport depends on the HTTP method:

- **POST / PUT / PATCH** — signals are the JSON request body; the token
  arrives as a top-level body param.
- **GET / DELETE** — signals go in the `datastar` **URL query parameter**
  (those methods carry no body). **Do not write "the token travels in every
  request body"** — on GET/DELETE it is in the query string.

`Dstar.Plugs.RenameCsrfParam` extracts the token from either channel into
`body_params["_csrf_token"]` for `Plug.CSRFProtection`. Validation is
cryptographic against the session-derived token, so renaming an
attacker-chosen value is not a bypass — but the URL placement on GET/DELETE
means the token lands in access logs and same-origin `Referer` headers; the
README's CSRF section documents the hardening options.

## Docs must stay in sync

Behavior changes need matching updates in all of these, or CI/docs drift:

- `README.md`
- `usage-rules.md` and `usage-rules/` (including
  `usage-rules/skills/use-dstar/SKILL.md` and
  `references/api-patterns.md`) — these ship in the Hex package
- `docs/migrating-from-phoenix-datastar.md`
- `CHANGELOG.md` (one entry per user-visible change, under `## Unreleased`)
- Module `@moduledoc`/`@doc` — ExDoc is the main reference

## Testing

- `mix test`; write tests mirroring the lib layout under `test/dstar/`.
- Unit tests run `async: true` where possible.
- Plug tests use `Plug.Test` conns; SSE assertions use the `Dstar.Test`
  helpers.
- Run `mix format --check-formatted` and `mix compile --warnings-as-errors`
  before committing.

## Git workflow

- **Merge PRs with "Rebase and merge"** (or squash) — Rico prefers a linear
  history where every commit and tag sits on a single line. Do not create
  merge commits.
- Rebase-merging **replays branch commits onto `main` with new SHAs**. The
  original pre-rebase commits remain on the feature branch. This is expected,
  not a problem.
- After a PR merges, GitHub auto-deletes the head branch. If you ever see
  "splinters" hanging off the graph in a Git GUI, they are almost always
  **stale local remote-tracking refs**, not real branches — clean them up with
  `git fetch --prune`. Confirm a branch is truly merged before deleting it with
  `git cherry main origin/<branch>` (patch-id comparison catches rebased
  commits that `git branch --merged` misses).

## Housekeeping

- **Never commit `deps/`** — it was tracked once by mistake and untracked in
  `287ea40`. `doc/` is ExDoc build output; regenerate it with `mix docs`, don't
  edit it by hand. Both are gitignored.
- Releases: bump `@version` in `mix.exs`, add a `Release 0.1.x` CHANGELOG
  entry, commit, tag `v0.1.x`.
