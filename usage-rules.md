# Dstar Usage Rules

## Pages first

Prefer `use Dstar.Page` + `dstar/2` for new pages. Use `Dstar.Component` +
`dstar_components/2` for shared UI with colocated event handlers. Reach for
the functional core (`Dstar.*` on a conn) in plain controllers or custom plugs.

### Canonical example — full counter page

```elixir
# router.ex
import Dstar.Router
dstar "/counter", MyAppWeb.CounterPage
```

```elixir
defmodule MyAppWeb.CounterPage do
  use Dstar.Page

  # GET — load data, assign, render
  def mount(conn, _params) do
    assign(conn, count: 0, page_title: "Counter")
  end

  def render(assigns) do
    ~H"""
    <div data-signals:count={@count}>
      <h1 data-text="$count"></h1>
      <span id="history">—</span>
      <button data-on:click={event("increment")}>+1</button>
      <button data-on:click={event("reset")}>Reset</button>
    </div>
    """
  end

  # POST /counter/_event/<name> — SSE already started for you
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> patch_signals(%{count: count})
    |> patch(&history/1, last: "+1 → #{count}")
  end

  def handle_event(conn, "reset", _signals) do
    conn
    |> patch_signals(%{count: 0})
    |> patch(&history/1, last: "Reset")
    |> console_log("Counter reset")
  end

  # Colocated components — used by render/1 and by patches alike
  defp history(assigns) do
    ~H"""
    <span id="history">Last: {@last}</span>
    """
  end
end
```

Key rules:
- One module per page — no separate controller, HTML module, or template file.
- `event("name")` generates the `@post(...)` expression client-side; no path
  threading needed for path params. The name is encoded as one literal route
  segment; empty, `.` and `..` names are rejected.
- The library calls `Dstar.start/1` before `handle_event/3` — do not call it
  again inside the handler.
- `dstar "/path", PageModule` is the allowlist. No separate allowlist entry needed.

## What Dstar Is

Dstar is a **minimalist SSE library** providing pure functions over `Plug.Conn` to format and send Server-Sent Events for Datastar client-side framework.

**Not:** LiveView, PhoenixDatastar, a framework, or a state management system. The **functional core** has no processes, GenServers, supervision trees, behaviours, or macros — two deps: `plug` and `jason`. The page layer (`Dstar.Page`, `Dstar.Component`, `Dstar.Router`) adds one behaviour, one plug, and two router macros on top, and is entirely opt-in.

## Core Pattern

**Read → Process → Start → Patch**

```elixir
def handle_event(conn, _params) do
  signals = Dstar.read_signals(conn)  # Read input
  new_count = (signals["count"] || 0) + 1  # Process
  conn
  |> Dstar.start()  # Open SSE connection
  |> Dstar.patch_signals(%{count: new_count})  # Send updates
end
```

## Core API

All functions in `Dstar` module:

### Connection

- **`Dstar.start(conn)`** — Opens SSE connection (chunked, text/event-stream)
- **`Dstar.check_connection(conn)`** — Tests if SSE connection is still open. Returns `{:ok, conn}` if active, `{:error, conn}` if closed. Useful for detecting disconnections in streaming loops

### Signals

- **`Dstar.read_signals(conn)`** — Reads signals from request (GET: query, POST: body)
- **`Dstar.patch_signals(conn, signals, opts \\ [])`** — Sends datastar-patch-signals event
  - Opts: `:only_if_missing`, `:event_id`, `:retry`

### DOM Manipulation

- **`Dstar.patch_elements(conn, html, opts)`** — Sends datastar-patch-elements event
  - Opts: `:selector` (required), `:mode` (`:outer`/`:inner`/`:append`/`:prepend`/`:before`/`:after`/`:replace`/`:remove`), `:use_view_transitions`
- **`Dstar.remove_elements(conn, selector, opts \\ [])`** — Removes elements

### Scripts & Actions

- **`Dstar.execute_script(conn, script, opts \\ [])`** — Executes JS on client
  - Opts: `:auto_remove`, `:attributes` (map of script tag attributes, e.g. `%{type: "module"}`)
- **`Dstar.redirect(conn, url, opts \\ [])`** — Client-side redirect.
  Default destination policy is same-origin path-absolute (`/path`, `?q`, `#frag`).
  Rejects `javascript:`/`data:`/`vbscript:` (any case, including
  whitespace/control-obfuscated forms), protocol-relative URLs, URLs with
  userinfo, and off-origin `http`/`https`. Opt in with `external: true` or
  `allow: ["host"]`. `Jason.encode!/1` prevents JS string breakout, not a
  dangerous destination.
- **`Dstar.console_log(conn, message, opts \\ [])`** — Browser console output
  - Opts: `:level` (`:log`/`:warn`/`:error`/`:info`/`:debug`)

### HTTP Verb Helpers

- **`Dstar.post(module, event_name)`** — Generates `@post("/ds/:module/:event")` for attributes.
- **`Dstar.post(module, event_name, opts)`** — `:prefix` is a local absolute app path beginning with one `/`; relative, protocol-relative, cross-origin, dot-segment, query, fragment, backslash, and control-containing, malformed-percent, and non-UTF-8 prefixes are rejected.
- **`Dstar.post(event_name, opts)`** — Dynamic module variant. Without `:module`, it reads and percent-encodes `$_dstar_module` in the browser. `:module` is a literal module override, not JavaScript.
- Event and module values are UTF-8 percent-encoded as one route segment. `/`, `\`, `?`, `#`, `%`, controls, quotes, and Unicode round-trip to the handler. Empty, `.` and `..` values raise `ArgumentError`.
- Page/Component `event(..., opts: "...")` and page `connect(opts: "...")` treat `:opts` as raw **trusted developer code**. Never interpolate request or stored data into it.
- All HTTP verbs available: `Dstar.get/2,3`, `Dstar.put/2,3`, `Dstar.patch/2,3`, `Dstar.delete/2,3`.

## CSRF Setup

Phoenix expects the CSRF token in the `_csrf_token` body param — and
Datastar can't deliver that: its `_`-prefixed signal keys are front-end-only
and never sent to the backend. So the token travels as a non-prefixed
signal, and one plug copies it into place.

```elixir
# In your router pipeline, BEFORE :protect_from_forgery:
plug Dstar.Plugs.RenameCsrfParam
plug :protect_from_forgery
```

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

Because `csrf` is not `_`-prefixed, Datastar includes it in every request — as a body param for POST/PUT/PATCH, and in the `datastar` query parameter for GET/DELETE (those methods carry no body). `Dstar.Plugs.RenameCsrfParam` copies that value into `_csrf_token` for `Plug.CSRFProtection` from either channel. This one setup covers page events, stream connects, component events, and the verb helpers. The plug safely no-ops when the param isn't present, so it's fine to use globally.

The plug writes `body_params["_csrf_token"]` only when that key is missing, in this order: existing body `_csrf_token`, body `csrf`, `csrf` inside `datastar`, then a last-resort top-level `csrf` param. A query `_csrf_token` is not a source and does not hide a valid body or `datastar` token. `Plug.CSRFProtection` then checks the body token first, then `x-csrf-token`.

Cookie-authenticated state-changing routes need a real CSRF defense — normally this plug plus `:protect_from_forgery`, or an `x-csrf-token` header (strongest hygiene: the token never lands in a URL), or a deliberately implemented Origin / Fetch-Metadata policy. Session/auth checks and SameSite cookies identify the victim; they do not prove who initiated the request.

On GET/DELETE the token rides in the URL, so it lands in access logs and same-origin `Referer` headers. Validation is unaffected, but redact the entire `datastar` query value from logs/APM and set `Referrer-Policy` to `no-referrer` or `origin` (`same-origin` still sends path/query on same-origin requests).

## Dynamic Dispatch

**Router:**
```elixir
post "/ds/:module/:event", Dstar.Plugs.Dispatch, modules: [MyApp.CounterHandler]
```

**Handler:**
```elixir
defmodule MyApp.CounterHandler do
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1
    conn |> Dstar.start() |> Dstar.patch_signals(%{count: count})
  end
end
```

Client: `data-on:click={Dstar.post(CounterHandler, "increment")}`. The helper
encodes both route values as literal path segments; do not concatenate a URL or
a Datastar expression by hand when either value contains data.

## Real-time Streaming Pattern

```elixir
def stream(conn, _params) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")
  conn = Dstar.start(conn)
  loop(conn)
end

defp loop(conn) do
  receive do
    {:update, data} ->
      conn = Dstar.patch_signals(conn, %{data: data})
      loop(conn)
  end
end
```

Client reconnection:
```heex
<div data-init="@post('/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/stream', {retryMaxCount: Infinity})">
```

## Live Collections

Keeping a list current in every open tab? The stream is one-way and cannot
learn a tab's filter/sort/page after connect, so blindly appending or morphing
rows silently corrupts any non-plain view. **Default to the nudge:**
`nudge(conn, "posts")` bumps a signal, each tab re-runs its own load action
with its own signals. Row mutation (`append_elements`, `upsert_elements`,
`remove_elements`) is the fast path for plain feeds only. Full pattern:
`usage-rules/live-collections.md`.

## JavaScript Islands

Embedding a stateful, JS-managed-DOM component (rich-text editor, map, chart,
canvas) in a Datastar page? Make it a **custom element that is also a Datastar
form control**: `data-bind` a `value` property for state, patch the signal for
content, dispatch element-targeted `CustomEvent`s for commands, and add
`data-ignore-morph` so the morph leaves its subtree alone. Full pattern + gotchas:
`usage-rules/javascript-islands.md`.

## Anti-patterns

**❌ Don't:**
- Use GenServers to store per-connection state (stateless functions only)
- Keep server-side state between events (except PubSub for streaming)
- Wrap `conn` in custom structs
- Call `Dstar.start()` multiple times per response
- Use in same controller action as `render/3` or `json/2`

**✅ Do:**
- Keep handlers pure: `(conn, signals) -> conn`
- Store state in signals (client-side) or database
- Call `Dstar.start()` once, then patch multiple times if needed
- Chain patches: `conn |> patch_signals(...) |> patch_elements(...)`

## Signal Value Quoting

Datastar signal values are JavaScript expressions:
```heex
data-signals:count="0"           <%!-- Number --%>
data-signals:name="''"           <%!-- Empty string (JS quotes needed) --%>
data-signals:id={"'#{@id}'"}     <%!-- Dynamic string (HEEx + JS quotes) --%>
data-signals:active="false"      <%!-- Boolean --%>
data-signals:items="[]"          <%!-- Array --%>
data-signals:errors="{}"         <%!-- Object --%>
```

## Key Datastar Attributes

- `data-signals:name="value"` — Declare reactive signal (JS expression)
- `data-signals:_name="value"` — Client-only signal (not sent in body, used for headers)
- `data-text="$signalName"` — Text binding
- `data-show="$condition"` — Conditional visibility
- `data-on:click="..."` — Event handler
- `data-init="..."` — Run on mount
- `data-class:className="$condition"` — Conditional CSS class
- `data-model="signalName"` — Two-way input binding

## Dependencies

Only two: `{:plug, "~> 1.14"}` and `{:jason, "~> 1.4"}`
