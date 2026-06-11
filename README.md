# Dstar

[![Hex.pm](https://img.shields.io/hexpm/v/dstar)](https://hex.pm/packages/dstar)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/dstar)

**The batteries-included Datastar toolkit for Elixir.** SSE helpers, event dispatch, CSRF handling, stream deduplication — everything you need to ship Datastar apps, not just the wire protocol.

> Successor to [PhoenixDatastar](https://hex.pm/packages/phoenix_datastar).

## Why Dstar?

Other libraries give you SSE primitives and leave the rest to you. Dstar gives you the primitives **and** the utilities you'd end up building yourself:

- **Pages** — `use Dstar.Page` puts render, event handlers, streaming callbacks, and components in one module. One router line wires it.
- **Event dispatch** — One route, unlimited handlers. `Dstar.Plugs.Dispatch` routes events to handler modules by convention, so you never hand-wire a route per action.
- **URL generation** — `Dstar.post/2`, `Dstar.get/2`, `Dstar.delete/2` generate `@post(...)` expressions with correct paths. No hand-written URLs in templates.
- **CSRF handling** — Works out of the box with Datastar's header-based tokens. `Dstar.Plugs.RenameCsrfParam` bridges SSE and form-based routes so `Plug.CSRFProtection` just works.
- **Stream deduplication** — `Dstar.Utility.StreamRegistry` kills zombie SSE processes when users navigate between pages. One process per tab, always.
- **Console logging** — `Dstar.console_log/2` sends log/warn/error messages straight to the browser DevTools. Debug from the server, read in the browser.
- **Phoenix.HTML support** — `patch_elements` accepts both raw strings and `Phoenix.HTML.safe()` tuples, so HEEx template output works without conversion.

The functional core is still a small bag of functions with no processes. The page layer on top is one behaviour, one plug, and two router macros — all opt-in, all readable. The one optional process — `StreamRegistry` — is opt-in only if you need stream deduplication.

Drop it into any Plug-based app: Phoenix controllers, plain Plug, Bandit. If you have a `%Plug.Conn{}`, you can use Dstar.

## Installation

Add `dstar` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:dstar, "0.1.0-alpha.1"}
  ]
end
```

> The page layer is in alpha — the requirement is exact because `~>`
> never resolves pre-releases. Prefer the stable functional core only?
> `{:dstar, "~> 0.0.10"}` stays exactly as it was.

Pages need `{:phoenix, "~> 1.7"}` and `{:phoenix_live_view, "~> 1.0"}` in your app (any Phoenix app already has them). The functional core needs neither.

Then add the Datastar client script to your root layout's `<head>`:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0/bundles/datastar.js"></script>
```

That's it. No generators, no config, no application callback.

## Quick Start

A page is **one module and one router line**.

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

That's the whole page. Notice what's *absent*:

- No separate controller, HTML, or components module — one file.
- No `handler={...}` / `prefix={...}` threading: `event("increment")`
  resolves its URL in the browser (`location.pathname + '/_event/...'`),
  so path params like `/:workspace_slug` need no server-side plumbing.
- No `Dstar.start()` — event POSTs are SSE by definition, so the
  library starts the stream before calling you.
- No allowlist registration — the `dstar` route *is* the allowlist.

> **Routing through `:protect_from_forgery`?** Event POSTs need the CSRF
> token as a signal — one plug plus one `<body>` attribute. See
> [CSRF Protection Setup](#csrf-protection-setup).

### Streaming

Declare how to subscribe; the library owns the receive loop:

```elixir
  # In the same page module:
  def handle_connect(conn, _params) do
    MyAppWeb.Endpoint.subscribe("ticker")
    conn
  end

  def handle_info(%Phoenix.Socket.Broadcast{payload: p}, conn) do
    patch_signals(conn, %{tick: p.count})
  end
```

```heex
<div data-init={connect()} data-on:online__window={connect()}>
  <span data-text="$tick"></span>
</div>
```

The loop checks connection liveness every 30s (tune with
`use Dstar.Page, idle_check: 10_000`), survives stray messages, and
cleans up when the client disconnects. Add a `stream_key/1` callback to
enable per-tab stream deduplication via `Dstar.Utility.StreamRegistry`.

### Shared components

UI used across many pages — with its event handlers in the same module:

```elixir
defmodule MyAppWeb.DetailDrawer do
  use Dstar.Component

  def drawer(assigns) do
    ~H"""
    <div id="detail-drawer">
      <input data-on:change={event("change_title:#{@item.id}")} value={@item.title} />
    </div>
    """
  end

  def handle_event(conn, "change_title:" <> id, signals) do
    # update the record, then patch
    conn |> start() |> patch_signals(%{saved: true})
  end
end
```

```elixir
# router.ex — one line for ALL components:
dstar_components "/ds", [MyAppWeb.DetailDrawer]
```

Pages embed `<MyAppWeb.DetailDrawer.drawer item={@item} />` and need zero
`handle_event` clauses for it. If your app mounts routes under a prefix,
declare the dispatch base once in the root layout: `<body data-ds-base={...}>`
(defaults to `/ds`; it must match the base given to `dstar_components/2`,
including any app path prefix).

Unlike page handlers, component handlers call `start()` themselves — the dispatch plug doesn't start the SSE response for them.

## The functional core

*Everything above is built from these functions. Use them directly in plain controllers, custom plugs, or anywhere you have a `%Plug.Conn{}` — pages are optional sugar, the core is the contract.*

Everything goes through the `Dstar` convenience module, which delegates to lower-level modules.

### `Dstar.start(conn)` → `Plug.Conn.t()`

Opens an SSE connection. Sets `text/event-stream` content type, disables caching, starts a chunked response.

```elixir
conn = Dstar.start(conn)
```

### `Dstar.start_stream(conn, scope_key)` → `Plug.Conn.t()`

Like `start/1`, but with per-tab stream deduplication. Kills any previous stream process for the same user+tab before opening a new one. Requires setup — see [Stream Deduplication](#stream-deduplication-optional).

```elixir
conn = Dstar.start_stream(conn, current_user.id)
```

### `Dstar.check_connection(conn)` → `{:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}`

Checks if an SSE connection is still open by sending an SSE comment line. Returns `{:ok, conn}` if the connection is active, `{:error, conn}` if closed or not yet started. Useful for detecting disconnections in streaming loops.

```elixir
case Dstar.check_connection(conn) do
  {:ok, conn} ->
    conn = Dstar.patch_signals(conn, %{data: new_data})
    loop(conn)
  
  {:error, _conn} ->
    # Client disconnected, clean up
    Phoenix.PubSub.unsubscribe(MyApp.PubSub, "topic")
    :ok
end
```

### `Dstar.read_signals(conn)` → `map()`

Reads Datastar signals from the request. For `GET` requests, reads from the `datastar` query parameter. For everything else, reads from the JSON body.

```elixir
signals = Dstar.read_signals(conn)
count = signals["count"] || 0
```

### `Dstar.patch_signals(conn, signals, opts \\ [])` → `Plug.Conn.t()`

Sends a `datastar-patch-signals` event. Updates reactive signals on the client.

```elixir
conn
|> Dstar.patch_signals(%{count: 42, message: "hello"})
|> Dstar.patch_signals(%{defaults: true}, only_if_missing: true)
```

**Options:**
- `:only_if_missing` — Only patch signals that don't exist on the client (default: `false`)
- `:event_id` — Event ID for client tracking
- `:retry` — Retry duration in milliseconds

### `Dstar.remove_signals(conn, paths, opts \\ [])` → `Plug.Conn.t()`

Removes signals from the client by setting them to `nil`. Accepts a single dot-notated path string or a list of paths. Paths with shared prefixes are deep-merged correctly.

```elixir
# Remove single signal
conn |> Dstar.remove_signals("user.profile.theme")

# Remove multiple signals
conn |> Dstar.remove_signals([
  "user.name",
  "user.email",
  "user.profile.avatar"
])

# Common use case: logout
conn
|> Dstar.start()
|> Dstar.remove_signals(["user", "session", "preferences"])
|> Dstar.redirect("/login")
```

Validates paths and raises on empty strings, leading/trailing/consecutive dots.

### `Dstar.patch_elements(conn, html, opts)` → `Plug.Conn.t()`

Sends a `datastar-patch-elements` event. Patches DOM elements on the client. Accepts both binary strings and `Phoenix.HTML.safe()` tuples (e.g., HEEx template output).

```elixir
conn
|> Dstar.patch_elements(~s(<span id="count">42</span>), selector: "#count")
|> Dstar.patch_elements("<li>new item</li>", selector: "ul#items", mode: :append)

# SVG chart update
svg = "<svg>...</svg>"
conn |> Dstar.patch_elements(svg, selector: "#chart", namespace: :svg)

# MathML formula
mathml = "<math>...</math>"
conn |> Dstar.patch_elements(mathml, selector: "#formula", namespace: :mathml)
```

**Options:**
- `:selector` — CSS selector (required)
- `:mode` — `:outer` (default), `:inner`, `:append`, `:prepend`, `:before`, `:after`, `:replace`, `:remove`
- `:namespace` — `:html` (default), `:svg`, `:mathml`
- `:use_view_transitions` — Enable View Transitions API (default: `false`)
- `:event_id` — Event ID for client tracking
- `:retry` — Retry duration in milliseconds

### `Dstar.remove_elements(conn, selector, opts \\ [])` → `Plug.Conn.t()`

Sends a `datastar-patch-elements` event that removes matching elements.

```elixir
conn |> Dstar.remove_elements("#flash-message")
```

### `Dstar.post(module, event_name)` → `String.t()`

Generates a `@post(...)` expression for use in Datastar attributes. All HTTP verbs are available: `Dstar.get/2,3`, `Dstar.put/2,3`, `Dstar.patch/2,3`, `Dstar.delete/2,3` — they all follow the same API.

```elixir
Dstar.post(MyAppWeb.CounterHandler, "increment")
# => "@post('/ds/my_app_web-counter_handler/increment')"

Dstar.delete(MyAppWeb.TodoHandler, "remove")
# => "@delete('/ds/my_app_web-todo_handler/remove')"
```

Also supports dynamic module references and URL prefixes. See `Dstar.Actions` docs for details.

### `Dstar.execute_script(conn, script, opts \\ [])` → `Plug.Conn.t()`

Executes JavaScript on the client by appending a `<script>` tag via SSE.

```elixir
conn |> Dstar.execute_script("alert('Hello!')")
conn |> Dstar.execute_script("console.log('debug')", auto_remove: false)
```

**Options:**
- `:auto_remove` — Remove script tag after execution (default: `true`)
- `:attributes` — Map of additional script tag attributes

### `Dstar.redirect(conn, url, opts \\ [])` → `Plug.Conn.t()`

Redirects the client to the given URL via JavaScript.

```elixir
conn |> Dstar.redirect("/workspaces")
```

### `Dstar.console_log(conn, message, opts \\ [])` → `Plug.Conn.t()`

Logs a message to the browser console via SSE.

```elixir
conn |> Dstar.console_log("Debug info")
conn |> Dstar.console_log("Warning!", level: :warn)
```

**Options:**
- `:level` — `:log` (default), `:warn`, `:error`, `:info`, `:debug`

## Real-time Streaming

With `Dstar.Page`, declare subscriptions in `handle_connect/2` and implement `handle_info/2` — the library owns the loop (see Quick Start). The hand-rolled loop below remains fully supported for plain controllers:

```elixir
defmodule MyAppWeb.TickerController do
  use MyAppWeb, :controller

  def stream(conn, _params) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "ticker")
    conn = Dstar.start(conn)
    loop(conn)
  end

  defp loop(conn) do
    receive do
      {:tick, count} ->
        # Optional: check connection health
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{tick: count})
            loop(conn)
          
          {:error, _conn} ->
            # Client disconnected, clean up
            Phoenix.PubSub.unsubscribe(MyApp.PubSub, "ticker")
            :ok
        end
    end
  end
end
```

**Template:**

Use `@post` with `retryMaxCount: Infinity` — Datastar handles reconnection
automatically. Add `data-on:online__window` to reconnect when the browser
comes back online (laptop lid, WiFi drop, etc.):

```heex
<div data-signals:tick="0"
     data-init="@post('/ticker/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/ticker/stream', {retryMaxCount: Infinity})">
  <span data-text="$tick"></span>
</div>
```

No keepalive loop needed on the server. Datastar's built-in retry handles
dropped connections, and `online__window` re-establishes the stream when the
network returns.

The library provides the SSE plumbing. Your app provides the PubSub topic and the business logic.

## Stream Deduplication (Optional)

With full-page navigation, SSE stream processes don't learn the client
disconnected until they try to write — which only happens on the next
PubSub broadcast or keepalive tick. In the meantime, zombie processes
hold subscriptions, run wasted DB queries on every broadcast, and on
HTTP/1.1 can exhaust the browser's 6-connection-per-origin limit.

`Dstar.Utility.StreamRegistry` fixes this. It tracks one stream process
per user+tab. When a new stream opens from the same tab, the previous
one is killed instantly — zero-delay cleanup, no wasted work.

This is the **one process** in Dstar. It's opt-in: if you don't need it,
the library stays zero-process. If you do, you add one child to your
existing supervision tree.

> With `Dstar.Page`, just define a `stream_key/1` callback — `Dstar.Page.Plug` calls `start_stream/2` for you. The manual `start`/`start_stream` swap in step 3 below applies to hand-rolled controller loops.

### 1. Add to your supervision tree

```elixir
# lib/my_app/application.ex
children = [
  Dstar.Utility.StreamRegistry,
  # ...
]
```

### 2. Add a `tabId` signal to your root layout

```heex
<body data-signals:tabId="sessionStorage.getItem('_ds_tab') || (() => { const id = crypto.randomUUID(); sessionStorage.setItem('_ds_tab', id); return id; })()">
```

`sessionStorage` is per-tab — each tab gets its own UUID that persists
across navigations but is unique per tab. Multiple tabs work independently.

> **Why not `_tabId`?** Datastar treats `_`-prefixed signals as client-only
> and never sends them to the server. The signal needs to reach the backend,
> so it must not have a `_` prefix.

### 3. Replace `Dstar.start(conn)` in stream controllers

```diff
- conn = Dstar.start(conn)
+ conn = Dstar.start_stream(conn, scope.user.id)
```

The second argument is any term that identifies the user or session
(e.g., `user.id`, `{user.id, workspace.id}`). The registry keys on
`{scope_key, tab_id}` so different users and different tabs never collide.

If no `tabId` signal is present in the request, `start_stream/2` falls
back to `Dstar.start/1` — so existing streams keep working while you
roll out the client-side signal.

### What it does

| Scenario | Before | After |
|---|---|---|
| User clicks 5 pages in 3s (same tab) | 5 zombie processes doing wasted PubSub work | 1 process per tab, always |
| 3 tabs open | 3 streams (fine) | 3 streams (unchanged) |
| 100 users rapid nav | Spikes of zombies doing wasted DB queries | Max 100 processes, zero wasted work |

## SSE Connection Limits & HTTP/2

Browsers allow only **6 concurrent HTTP/1.1 connections per domain**. Each
SSE stream holds one connection open. With rapid navigation, zombie streams
(server hasn't noticed the client left yet) plus the new page's stream can
exhaust the pool — silently stalling **all** requests to that domain: fetches,
asset loads, even page navigation. The page appears to hang with no error.

**HTTP/2 fixes this.** It multiplexes ~100 streams over a single TCP
connection, so SSE streams no longer compete with other requests. Bandit
(Phoenix's default adapter) auto-negotiates HTTP/2 over TLS — no extra
config beyond enabling HTTPS.

### Enable HTTPS in dev

1. Generate a self-signed certificate:

```bash
mix phx.gen.cert
```

If `mix phx.gen.cert` fails (missing `:public_key` on some OTP versions), use openssl:

```bash
mkdir -p priv/cert
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
  -subj "/CN=localhost" \
  -keyout priv/cert/selfsigned_key.pem \
  -out priv/cert/selfsigned.pem
```

2. Switch `http:` to `https:` in `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  https: [
    ip: {127, 0, 0, 1},
    port: 4000,
    cipher_suite: :strong,
    keyfile: "priv/cert/selfsigned_key.pem",
    certfile: "priv/cert/selfsigned.pem"
  ],
  url: [host: "localhost", scheme: "https"],
  # ...
```

3. If `config/runtime.exs` sets `http: [port: ...]` for dev, change it to `https:` too.

4. Add `priv/cert/` to `.gitignore` — each developer generates their own.

5. Open `https://localhost:4000` and accept the self-signed cert warning once.

6. **Tidewave users:** switching to HTTPS means Tidewave's MCP endpoint
   (plain HTTP) is no longer auto-discovered. Re-add it explicitly:

   ```bash
   claude mcp add tidewave --transport http http://localhost:4000/tidewave/mcp -s local
   ```

### Verify HTTP/2 is active

Open DevTools → Network tab → right-click column headers → enable
**Protocol**. All requests should show `h2`.

### Recommendation

Use **Stream Deduplication** (previous section) and **HTTP/2** together.
Dedup kills zombie processes server-side so they stop doing wasted DB
queries. HTTP/2 prevents client-side connection exhaustion so the browser
never stalls. Either one helps on its own; both together eliminate the
problem entirely.

## Without Dispatch

You can skip both the page model and the dispatch plug entirely and use plain controller actions:

```elixir
# router.ex
post "/counter/increment", CounterController, :increment
```

```elixir
# controller
def increment(conn, _params) do
  signals = Dstar.read_signals(conn)
  count = (signals["count"] || 0) + 1

  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{count: count})
end
```

```heex
<button data-on:click="@post('/counter/increment')">+1</button>
```

Dispatch gives you convention and a single route. Plain controllers give
you full routing control. Both use the same Dstar functions underneath.

## CSRF Protection Setup

Datastar has **no built-in CSRF support** — it does not read Phoenix's
`<meta name="csrf-token">` tag and never sets an `x-csrf-token` header.
(Verified against the v1 bundle: zero references to CSRF.) The token must
travel as a signal.

### The signal pattern (pages, components, and helper routes alike)

1. Add the plug to your browser pipeline, before `:protect_from_forgery`:

```elixir
plug Dstar.Plugs.RenameCsrfParam
plug :protect_from_forgery
```

2. Expose the token as a **non-prefixed** signal in your root layout:

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

Because `csrf` is not `_`-prefixed, Datastar includes it in every request
body. The plug copies it to `body_params["_csrf_token"]`, where
`Plug.CSRFProtection` looks. This one setup covers page `event()` POSTs,
stream `connect()` POSTs, component events, and the verb helpers.

### Or: skip CSRF for SSE-only routes

Pipe Datastar-only routes through a pipeline without `:protect_from_forgery`
(the classic dispatch-route setup). Simpler, but then those endpoints rely on
your session/auth checks alone.

## Lower-level Modules

The `Dstar` module delegates to these. Use them directly when you need more control.

| Module | Functions |
|--------|-----------|
| `Dstar.Page` | behaviour + `use` macro: `mount/2`, `render/1`, `handle_event/3`, `handle_connect/2`, `handle_info/2`, `stream_key/1` |
| `Dstar.Page.Plug` | request driver: handles page, event, and stream actions |
| `Dstar.Component` | shared UI with colocated event handlers |
| `Dstar.Router` | `dstar/2` (page routes), `dstar_components/2` (dispatch route) |
| `Dstar.Test` | `sse_events/1`, `patched_signals/1`, `assert_patched_signals/2`, `assert_patched_element/2` |
| `Dstar.SSE` | `start/1`, `check_connection/1`, `send_event/3,4`, `send_event!/3,4`, `format_event/2` |
| `Dstar.Signals` | `read/1`, `patch/2,3`, `patch_raw/2,3`, `format_patch/1,2`, `remove_signals/2,3`, `format_remove/1,2` |
| `Dstar.Elements` | `patch/2,3`, `remove/2,3`, `format_patch/1,2` |
| `Dstar.Actions` | `post/2,3`, `get/2,3`, `put/2,3`, `patch/2,3`, `delete/2,3`, `encode_module/1`, `decode_module/1` |
| `Dstar.Scripts` | `execute/2,3`, `redirect/2,3`, `console_log/2,3` |
| `Dstar.Plugs.Dispatch` | Standard Plug for dynamic event routing |
| `Dstar.Plugs.RenameCsrfParam` | Standard Plug for CSRF param compatibility |
| `Dstar.Utility.StreamRegistry` | Opt-in per-tab stream deduplication (see [Stream Deduplication](#stream-deduplication-optional)) |

## Dependencies

Just two:

- [`plug`](https://hex.pm/packages/plug) — Conn manipulation
- [`jason`](https://hex.pm/packages/jason) — JSON encoding/decoding

## License

MIT
