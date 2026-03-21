# Changelog

## 0.0.6 — 2026-03-21

### Added

- **`Dstar.Utility.StreamRegistry`** — Opt-in per-tab SSE stream
  deduplication. Tracks one stream process per user+tab using Elixir's
  `Registry`. When a new stream opens from the same tab, the previous process
  is killed instantly — no waiting for keepalive timeouts or PubSub broadcasts.
  Fixes zombie processes that hold subscriptions, run wasted DB queries, and
  exhaust the browser's 6-connection-per-origin limit on HTTP/1.1. Add it to
  your supervision tree, set a `tabId` signal in your root layout, and replace
  `Dstar.start/1` with `Dstar.start_stream/2`. Falls back to `Dstar.start/1`
  when no `tabId` is present. See the README's "Stream Deduplication" section
  for full setup.

- **`Dstar.start_stream/2`** — Convenience delegate to
  `Dstar.Utility.StreamRegistry.start_stream/2`.

## 0.0.5 — 2026-03-18

### Added

- **`Dstar.SSE.check_connection/1`** — Checks if an SSE connection is still
  open by sending an SSE comment line. Returns `{:ok, conn}` if the connection
  is active, `{:error, conn}` if closed or not yet started. Useful for
  detecting disconnections in streaming loops. Also available via
  `Dstar.check_connection/1`.

- **`Dstar.Signals.remove_signals/3`** — Removes signals from the client by
  setting them to `nil`. Accepts a single dot-notated path string (e.g.
  `"user.profile.theme"`) or a list of paths (e.g. `["user.name",
  "user.email"]`). Paths with shared prefixes are deep-merged correctly:
  `["user.a", "user.b"]` becomes `%{"user" => %{"a" => nil, "b" => nil}}`.
  Validates paths and raises on empty strings, leading/trailing/consecutive
  dots. Also available via `Dstar.remove_signals/3` and
  `Dstar.Signals.format_remove/2` for string formatting.

- **`:namespace` option for `Dstar.Elements.patch/3` and
  `Dstar.Elements.format_patch/2`** — Specify element namespace: `:html`
  (default), `:svg`, or `:mathml`. When set to `:svg` or `:mathml`, emits a
  `namespace` data line in the SSE event. Default `:html` omits the line
  (backward compatible).

### Changed

- **`Dstar.Elements.patch/3` and `Dstar.Elements.format_patch/2` now accept
  `Phoenix.HTML.safe()` tuples** in addition to plain binary strings. Pass
  HEEx template output and `Phoenix.HTML` helpers directly without manual
  conversion.

- **`Dstar.Scripts.redirect/3` now uses `Jason.encode!/1`** for URL encoding
  instead of manual JavaScript string escaping. Prevents injection via special
  characters, `</script>` sequences, and Unicode. Generated JS changed from
  `window.location='url'` to `window.location.href="url"`.

## 0.0.4 — 2026-03-15

### Added

- **HTTP verb helpers** — `Dstar.post/2,3`, `Dstar.get/2,3`, `Dstar.put/2,3`,
  `Dstar.patch/2,3`, `Dstar.delete/2,3` generate `@verb(...)` expressions for
  Datastar attributes. Same API across all verbs.

### Deprecated

- `Dstar.event/2,3` — use `Dstar.post/2,3` (or the appropriate verb) instead.
  Still works, will be removed in a future version.

## 0.0.3 — 2026-03-15

### Added

- **UsageRules integration** — ships `usage-rules.md`, streaming sub-rule, and
  a pre-built `use-dstar` skill with API patterns reference. Consumers using
  the `usage_rules` package can pull these in automatically.

### Changed

- **README rewrite** — new Quick Start walks through routes → controller →
  event handler → template, showing `patch_signals`, `patch_elements`,
  `execute_script`, and `console_log` in one cohesive counter example.
  Dispatch is now the primary routing pattern; plain controller routes shown
  as an alternative in "Without Dispatch" section.

## 0.0.2 — 2026-03-15

### Added

- Migration guide from PhoenixDatastar to Dstar (`docs/migrating-from-phoenix-datastar.md`)

## 0.0.1 — 2025-03-12

Initial release after the grug-brain simplification. The library was gutted from
1,742 lines / 15 files down to ~735 lines / 6 files. Everything that
reimplemented LiveView was deleted.

### What's in the box

- **`Dstar.SSE`** — Open SSE connections (`start/1`), send events
  (`send_event/4`, `send_event!/4`), format events as strings
  (`format_event/2`).

- **`Dstar.Signals`** — Read Datastar signals from requests (`read/1`). Patch
  signals on the client via SSE (`patch/3`). Format signal patches as strings
  (`format_patch/2`).

- **`Dstar.Elements`** — Patch DOM elements via SSE (`patch/3`) with selector,
  mode, and view transition support. Remove elements (`remove/3`). Format
  patches as strings (`format_patch/2`).

- **`Dstar.Actions`** — Generate `@post(...)` expressions for Datastar
  attributes (`event/1,2`). Encode/decode Elixir module names to/from
  URL-safe strings (`encode_module/1`, `decode_module/1`).

- **`Dstar.Plugs.Dispatch`** — Optional dynamic dispatch plug. Routes
  `POST /ds/:module/:event` to handler modules from an allowlist.

- **`Dstar`** — Thin convenience module that delegates to the above.

### What was removed

The following modules were deleted because they reimplemented LiveView's
process-per-session model, which contradicts Datastar's client-holds-state
architecture:

- `Dstar.Server` — GenServer per session (284 lines)
- `Dstar.Socket` — LiveView-style socket struct with event queues (315 lines)
- `Dstar.Plugs.Page` — Custom HTML page renderer (147 lines)
- `Dstar.Plugs.Stream` — Token-verified SSE streaming endpoint (80 lines)
- `Dstar.Scripts` — Script execution via DOM patching (106 lines)
- `Dstar.Registry` — Process registry for GenServers (28 lines)
- `Dstar.Token` — Plug.Crypto token signing (48 lines)
- `Dstar.Application` — OTP application that started the registry (15 lines)
- `Dstar.Helpers.JS` — JS string escaping helper (13 lines)
- `Dstar` behaviour and `__using__` macro — mount/handle_event/render callback
  system (rewritten to thin delegation module)

### Design

- No processes. No supervision tree. No OTP application callback.
- No behaviours. No macros. No `use Dstar`.
- Two dependencies: `plug` and `jason`.
- Designed to sit on top of deadview Phoenix. Use your controllers, templates,
  and layouts. The library just formats and sends SSE events.
