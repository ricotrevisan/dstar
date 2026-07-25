# Changelog

## 0.1.6 — 2026-07-25

### Documentation

- **Retracted: the `connect()` placement warning.** 0.1.4 and 0.1.5 documented
  that a `data-init={connect()}` on the same element as the `data-signals:*` it
  needs fires before those signals are applied, so the stream POST omits them.
  That is false and the mechanism given for it does not exist.

  Isolated against the Datastar v1 bundle with a static page and an echo
  endpoint — no Elixir, no dstar in the loop. Signals and `data-init` sharing an
  element send correctly, including the exact multi-signal kebab-case shape the
  warning called broken. There is no signals-first pass in the client to support
  the claim: every plugin name is added to the restricted set as it registers,
  so that gate batches late-registered plugins rather than ordering them, and
  attributes apply in document order.

  The original report came from a measurement taken against stale tabs from a
  previous server instance with reconnect churn in flight.

  Placing `connect()` on a child element remains perfectly fine — it is simply
  not necessary.

## 0.1.5 — 2026-07-25

### Security

- **SSE field injection via a line break in `:selector`.** `Dstar.SSE` splits
  every `data:` value on line terminators so multi-line `elements` HTML frames
  correctly (the 0.1.1 fix). `selector` went through the same path, so a line
  break in it opened a *second* field inside the same event — and the Datastar
  client **accumulates** repeated fields rather than overwriting them, joining
  them with newlines. An injected `elements` line was therefore prepended to
  the real HTML and morphed into the DOM of every subscribed client:

      conn |> Dstar.patch_elements(html, selector: "#row-" <> untrusted)

  With `untrusted` carrying `"1\nelements <img src=x onerror=…>"`, that is
  stored XSS; a plainer payload silently redirects the patch at an attacker's
  chosen selector (`selector body > *` on a `remove` deletes the page). Any
  selector built from a record id, slug, or other user-supplied value was a
  vector. 0.1.1 closed frame injection — escaping into a *new event* — but not
  field injection *within* an event.

  Line terminators are now stripped from `:selector`, where they are
  meaningless anyway. `mode` and `namespace` were never reachable (validated
  against fixed atom lists), and `signals` is JSON-escaped.

  Found while adversarially reviewing the `ash_dstar` Stream bridge, which
  derives a DOM id from a record's primary key — a string primary key
  containing a newline reaches `remove_elements/2` as a selector.

## 0.1.4 — 2026-07-25

### Fixed

- **Stream takeover did nothing on the default stack** (#17). Bandit
  connection processes trap exits, so `StreamRegistry`'s
  `Process.exit(pid, :replaced)` arrived as a message instead of killing
  the old stream: dedup silently did not happen, every navigation stalled
  5 seconds, and the registry key stayed owned by a zombie. The library
  loop now halts on `{:EXIT, _, :replaced}`, `replace_and_register/1`
  waits for the key to be *released* (killing only a holder that ignores
  the signal), the `Registry.register/3` result is no longer discarded,
  and the handover is bounded at 1s instead of 5s.
- **Stream state outlived the stream** (#18). The `Dstar.Page.Plug` receive
  loop did no teardown, so on HTTP/1.1 keep-alive — where the connection process
  survives the stream — registry entries and subscriptions leaked onto a
  process serving unrelated requests. Every exit path now unregisters from
  `StreamRegistry` and calls the new optional `handle_disconnect/1`.
- **`tabId` was registered unvalidated** (#19). Any JSON value the client
  sent became a Registry key; `""` collided every such tab onto one key.
  Now required to be a 1..64-byte non-blank binary, exposed as
  `StreamRegistry.tab_id/1`.

### Documentation

- **`data-signals:tabId` never produced a `tabId` signal** (#20). HTML
  lowercases attribute names and Datastar camelizes on hyphens, so the
  documented setup silently disabled dedup. Corrected to `tab-id`, with
  the general kebab-case rule documented for all keyed attributes.
- **`retryMaxCount` cannot bound a reconnect loop** (#21). It counts
  consecutive *connection failures* and resets on every 200, so only
  `retryMaxCount: 0` stops a cycle that reconnects successfully each pass.
  Scoped to streams ending as a transport error (HTTP/2 takeover, kill,
  crash) or with `retry: "always"` — a cleanly ended stream does not
  reconnect at all under the default `retry: "auto"`.
- The installation snippet pinned `0.1.0-alpha.2`, four releases stale.

### Added

- **`handle_disconnect/1`** — optional `Dstar.Page` callback, run on every
  exit from the receive loop, for releasing what `handle_connect/2`
  acquired. A page's own `{:EXIT, _, :replaced}` clause still runs on a
  takeover, so existing cleanup code is unaffected.
- **`Dstar.Utility.StreamRegistry.tab_id/1`** — the validated `tabId`, so
  apps driving a hand-rolled loop can rebuild the registry key.
- **`Dstar.Utility.StreamRegistry.unregister_self/0`** — releases every key
  the calling process holds; a no-op when the opt-in registry is not running.

- **Live collections.** Helpers for keeping a list current in every open tab,
  plus a [usage-rules topic](usage-rules/live-collections.md) documenting the
  blind-stream trap.
  - `Dstar.Signals.nudge/3` (facade `Dstar.nudge/3`) — patch `nudges.<key>`
    with a fresh integer so each tab re-runs its own load action with its own
    filter/sort/page signals. The default for any non-plain view.
  - `Dstar.Actions.on_nudge/2` (also in `Dstar.Page.Helpers`) — the client
    half, an attribute map for HEEx spread that fires only on that nudge.
  - `Dstar.Elements.append/4` (facade `Dstar.append_elements/4`) and
    `Dstar.Elements.upsert/3` (facade `Dstar.upsert_elements/3`) — the row
    mutation fast path for plain feeds.

## 0.1.3 — 2026-06-28

### Security

- **`<script>` attribute injection in `Dstar.execute_script/3`.**
  The `:attributes` option interpolated attribute *names* verbatim and emitted
  non-binary attribute *values* unescaped, so a developer routing untrusted
  data into a script-tag attribute name (or a non-string value) could break
  out of the `<script …>` tag and inject live markup. Attribute names are now
  validated against `[A-Za-z0-9_:.-]` (rejected otherwise), and all attribute
  values — including charlists, atoms, and other non-binaries — are
  HTML-escaped. Found via adversarial review of the 0.1.2 fix.

## 0.1.2 — 2026-06-28

### Security

- **Incomplete `<script>` end-tag escaping in `Dstar.Scripts`.**
  `execute_script/2`, `console_log/2`, and `redirect/2` neutralized only an
  exact, lowercase `</script>` in the script body, so attacker-controlled
  content containing `</SCRIPT>`, `</script >`, `</script/>`, or `</script`
  followed by any terminator broke out of the appended `<script>` element
  (HTML closes script data case-insensitively), enabling stored XSS — e.g.
  logging a user-controlled value with `console_log/2`. Escaping now
  neutralizes every `</script` case-insensitively, while leaving developer
  JavaScript — including regex literals like `/<script/` — byte-identical.
  Found via internal security audit.

## 0.1.1 — 2026-06-28

### Security

- **SSE frame injection via carriage returns.** `Dstar.Elements` framed
  element HTML and selectors into SSE `data:` lines by splitting only on
  `\n`, so a lone carriage return (`\r`) in attacker-controlled content
  survived into the wire stream. The browser's `EventSource` parser treats
  CR, LF, and CRLF as line terminators, so this let an attacker forge
  additional SSE events — e.g. a `datastar-patch-signals` event spoofing
  client signals, or a `<script>` DOM injection — affecting every viewer of
  the patched fragment. `Dstar.SSE` now splits every `data:` value on all
  line terminators, and strips line breaks from the single-valued `event:`,
  `id:`, and `retry:` fields (the latter reachable through the `:event_id`
  and `:retry` options on `patch_elements`, `patch_signals`, and the script
  helpers). Found via internal security audit.

## 0.1.0 — 2026-06-14

### Fixed

- `Dstar.Page.Helpers.patch/4` injects `:__changed__` so rendered
  components may call `assign/3` (direct calls bypass the HEEx engine,
  which normally adds it).
- `Dstar.Plugs.Dispatch` and `Dstar.Page.Plug` now log crashes from
  `handle_event`/`handle_connect`/`handle_info` before reraising —
  previously a stream callback crash was a silent dead stream.

### Added

- `connect(include_search: true)` appends `location.search` to the
  stream-connect URL for pages whose render depends on query params.

### Documentation

- Corrected the CSRF guidance across the usage rules, the `use-dstar`
  skill, and the Phoenix-Datastar migration guide to match the README and
  `RenameCsrfParam` correction: Datastar has no built-in CSRF support, so
  the token must travel as a non-prefixed `csrf` signal rather than the
  previously-documented (and nonexistent) `x-csrf-token` meta-tag path.
- Modernized the `datastar-attributes` handler examples to the conn-based
  API (`handle_event(conn, event, signals)`, `Dstar.start/1`,
  `patch_signals`, `patch_elements(html, selector:, mode:)`).

## 0.1.0-alpha.2 — 2026-06-11

### Added

- **`mix dstar.https`** — one-command trusted HTTPS for dev. Adds a
  `my-app.test` entry to `/etc/hosts` and generates a browser-trusted
  certificate via mkcert, enabling HTTP/2 so SSE streams don't exhaust the
  browser's 6-connection HTTP/1.1 limit. Tries cached `sudo -n` first,
  falls back to a GUI prompt on macOS (`osascript`) and interactive sudo
  on Linux; detects conflicting hosts entries before touching anything.
  Supports `--host`, `--cert`, `--key`, `--ip`, `--dry-run`, and `--yes`.

### Fixed

- **`Dstar.Page.Plug`'s stream loop no longer consumes Bandit's HTTP/2
  flow-control messages.** Over HTTP/2, Bandit runs each stream in its own
  process and delivers `{:bandit, {:send_window_update, _}}` (and friends)
  to that process's mailbox, consuming them by selective receive inside
  its send path. The library loop's catch-all `receive` stole those
  messages, logging them as unhandled page messages and — worse —
  discarding the window credit, which would stall the stream with a
  flow-control timeout once the send window drained. The loop now skips
  `{:bandit, _}` messages so Bandit finds them where it expects them.

- **`Dstar.Page.Plug` now loads the page module before probing its
  callbacks.** `function_exported?/3` returns `false` for modules the code
  server has not loaded yet, so under lazy code loading (dev and test on a
  fresh VM) the first GET to a page silently skipped `mount/2` — typically
  crashing `render/1` with a `KeyError` — and the first stream POST
  returned 404 despite a defined `handle_connect/2`. The plug now calls
  `Code.ensure_loaded?/1` before `function_exported?/3`.

## 0.1.0-alpha.1

The unified page module release. A Datastar page is now one module and
one router line. Alpha until the page layer has survived its proving
ground (a full production-app migration); the functional core is the
same battle-tested code as 0.0.x.

### Added

- `Dstar.Page` — `use` it for one-module pages: `mount/2`, `render/1`,
  `handle_event/3`, `handle_connect/2`, `handle_info/2`, `stream_key/1`.
- `Dstar.Page.Plug` — drives all page requests; owns the SSE receive
  loop with idle checks and stray-message tolerance.
- `Dstar.Component` — shared UI with colocated event handlers; `event/2`
  targets the dispatch URL with a client-side `data-ds-prefix` base.
- `Dstar.Router` — `dstar/2` (page routes) and `dstar_components/2`
  (dispatch route) macros.
- `Dstar.Page.Helpers` — `event/1,2`, `connect/0,1`, `patch/3,4`.
- `Dstar.Page.Assigns` — `assign`/`assign_new`/`update` working on both
  conns and component assigns.
- `Dstar.Test` — `sse_events/1`, `patched_signals/1`,
  `assert_patched_signals/2`, `assert_patched_element/2`.
- Optional deps: `phoenix ~> 1.7`, `phoenix_live_view ~> 1.0`. The
  functional core still needs only `plug` + `jason`.

### Changed

- Docs restructured around pages; the original API is now "the
  functional core". Nothing breaks: all 0.0.x code works unchanged.

## 0.0.10 — 2026-04-24

### Fixed

- **Removed `Connection: keep-alive` header from SSE responses.** The header
  is forbidden in HTTP/2 (RFC 9113 §8.2.2) and caused browsers and curl to
  reject the entire response body over HTTP/2 connections. It was also
  redundant in HTTP/1.1, where keep-alive is already the default.

## 0.0.9 — 2026-04-16

### Fixed

- **README copy fixes.** The install snippet now references `~> 0.0.9`
  (was stuck on `~> 0.0.7` in the v0.0.8 release). Removed two stale
  mentions of "CSRF headers" in the URL-generation feature list and the
  Quick Start — verb helpers stopped injecting CSRF headers in 0.0.8
  when CSRF moved to the Phoenix meta tag. Removed a stray `T` after the
  License section.

## 0.0.8 — 2026-04-16

Consolidates the unreleased 0.0.7 work (CSRF rewrite, expanded usage rules)
with Datastar v1.0 compatibility fixes. Users on 0.0.6 upgrading to 0.0.8
should read the **Changed** section — CSRF handling has been rewritten.

### Changed

- **CSRF is no longer transported through a Datastar signal.** Verb helpers
  (`Dstar.post/2,3`, `get`, `put`, `patch`, `delete`) no longer inject an
  `{headers: {'x-csrf-token': $_csrfToken}}` options object into generated
  expressions. Datastar reads the token from Phoenix's standard
  `<meta name="csrf-token">` tag and sends it as an `x-csrf-token` header
  automatically. This decouples CSRF from Datastar's signal round-tripping
  and shortens every generated expression.

  **Migration from 0.0.6:** remove any `data-signals:_csrf-token` /
  `$_csrfToken` signal from your root layout. Keep the standard Phoenix
  `<meta name="csrf-token" content={get_csrf_token()}>` tag in `<head>`.
  If you use Datastar-driven form POSTs that go through `Plug.CSRFProtection`,
  expose the token as a **non-prefixed** `csrf` signal and keep
  `Dstar.Plugs.RenameCsrfParam` in your pipeline — that plug's role is now
  scoped to bridging form posts, not SSE.

- **Datastar version references bumped from `1.0.0-RC.8` to `v1.0.0`** in
  the README, `doc/readme.md`, and the `datastar-attributes` usage rule.
  v1.0's other changes (new `data-bind` `__prop`/`__event` modifiers,
  `data-on` `__document` modifier, morphing improvements,
  `retryMaxWaitMs` → `retryMaxWait` rename, Rocket JS API rewrite) are all
  client-side and need no Dstar changes.

### Fixed

- **`Dstar.Signals.read/1` now reads signals from query params for DELETE
  requests.** Datastar v1.0 stopped sending a body on DELETE requests
  ([#1144](https://github.com/starfederation/datastar/issues/1144)), so
  signals from `Dstar.delete/2,3` actions arrived empty under the previous
  code path. `read/1` now treats GET and DELETE the same — both read from
  the `datastar` query param.

### Added

- **New usage-rules reference files** ship with the package: `error-handling.md`,
  `heex-rendering.md`, `loading-states.md`, and a full `datastar-attributes.md`
  cheat sheet. Consumers of the `usage_rules` package will pick these up
  automatically.

- **HTTP/2 SSE connection limit docs** added to the README, covering why the
  browser 6-connection-per-origin cap on HTTP/1.1 matters for long-lived
  Datastar streams and how HTTP/2 multiplexing removes it.

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
