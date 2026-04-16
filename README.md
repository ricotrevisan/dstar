# Dstar

[![Hex.pm](https://img.shields.io/hexpm/v/dstar)](https://hex.pm/packages/dstar)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/dstar)

**The batteries-included Datastar toolkit for Elixir.** SSE helpers, event dispatch, CSRF handling, stream deduplication — everything you need to ship Datastar apps, not just the wire protocol.

> Successor to [PhoenixDatastar](https://hex.pm/packages/phoenix_datastar).

## Why Dstar?

Other libraries give you SSE primitives and leave the rest to you. Dstar gives you the primitives **and** the utilities you'd end up building yourself:

- **Event dispatch** — One route, unlimited handlers. `Dstar.Plugs.Dispatch` routes events to handler modules by convention, so you never hand-wire a route per action.
- **URL generation** — `Dstar.post/2`, `Dstar.get/2`, `Dstar.delete/2` generate `@post(...)` expressions with correct paths. No hand-written URLs in templates.
- **CSRF handling** — Works out of the box with Datastar's header-based tokens. `Dstar.Plugs.RenameCsrfParam` bridges SSE and form-based routes so `Plug.CSRFProtection` just works.
- **Stream deduplication** — `Dstar.Utility.StreamRegistry` kills zombie SSE processes when users navigate between pages. One process per tab, always.
- **Console logging** — `Dstar.console_log/2` sends log/warn/error messages straight to the browser DevTools. Debug from the server, read in the browser.
- **Phoenix.HTML support** — `patch_elements` accepts both raw strings and `Phoenix.HTML.safe()` tuples, so HEEx template output works without conversion.

Under the hood, it's ~700 lines of code with no GenServers, no behaviours, and no macros. Just functions that take a `Plug.Conn` and return a `Plug.Conn`. The one optional process — `StreamRegistry` — is opt-in only if you need stream deduplication.

Drop it into any Plug-based app: Phoenix controllers, plain Plug, Bandit. If you have a `%Plug.Conn{}`, you can use Dstar.

## Installation

Add `dstar` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:dstar, "~> 0.0.9"}
  ]
end
```

Then add the Datastar client script to your root layout's `<head>`:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0/bundles/datastar.js"></script>
```

That's it. No generators, no config, no application callback.

## Quick Start

A counter with increment, decrement, and reset — enough to show every primitive.

### 1. Routes

```elixir
# router.ex

# Page render — normal Phoenix controller
get "/counter", CounterController, :show

# All Datastar events — single dispatch route
post "/ds/:module/:event", Dstar.Plugs.Dispatch,
  modules: [MyAppWeb.CounterEvents]
```

Two routes. The `GET` renders HTML. The `POST` dispatches Datastar events
to an allowlisted handler module. That's the entire wiring.

### 2. Controller — renders the page

```elixir
defmodule MyAppWeb.CounterController do
  use MyAppWeb, :controller

  def show(conn, _params) do
    render(conn, :counter)
  end
end
```

No SSE logic here. This is a plain Phoenix controller that serves HTML.

### 3. Event handler — reacts to Datastar actions

```elixir
defmodule MyAppWeb.CounterEvents do
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
    |> Dstar.patch_elements(
      ~s(<span id="history">Last: +1 → #{count}</span>),
      selector: "#history"
    )
  end

  def handle_event(conn, "decrement", signals) do
    count = max((signals["count"] || 0) - 1, 0)

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
    |> Dstar.patch_elements(
      ~s(<span id="history">Last: -1 → #{count}</span>),
      selector: "#history"
    )
  end

  def handle_event(conn, "reset", _signals) do
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: 0})
    |> Dstar.patch_elements(
      ~s(<span id="history">Reset</span>),
      selector: "#history"
    )
    |> Dstar.execute_script("""
    document.getElementById('history').animate(
      [{opacity: 0}, {opacity: 1}],
      {duration: 300}
    )
    """)
    |> Dstar.console_log("Counter reset")
  end
end
```

Pattern-match on event name. Read signals, do work, pipe SSE patches back.
`increment` and `decrement` update both the reactive signal *and* a DOM element.
`reset` also runs a JS animation and logs to the browser console — all from
the same pipeline.

### 4. Template

```heex
<%# counter.html.heex %>

<div data-signals:count="0">
  <h1 data-text="$count">0</h1>

  <span id="history">—</span>

  <button data-on:click={Dstar.post(MyAppWeb.CounterEvents, "increment")}>
    +1
  </button>

  <button data-on:click={Dstar.post(MyAppWeb.CounterEvents, "decrement")}>
    −1
  </button>

  <button data-on:click={Dstar.post(MyAppWeb.CounterEvents, "reset")}>
    Reset
  </button>
</div>
```

`Dstar.post/2` pairs with `Dstar.Plugs.Dispatch` — it generates the
`@post(...)` expression with the correct path so you never hand-write
URLs. CSRF is handled separately via the standard Phoenix meta tag
(see [CSRF Protection Setup](#csrf-protection-setup)). One dispatch
route, as many handlers as you want.

### What just happened?

| Layer | Concern |
| --- | --- |
| **Router** | `GET` → controller, `POST /ds/*` → dispatch |
| **Controller** | Renders HTML. No SSE awareness. |
| **Handler** | Pure `handle_event/3` functions. Reads signals, pipes SSE responses. |
| **Template** | Standard HEEx + Datastar attributes. `Dstar.post/2` wires the buttons. |

Three Dstar primitives covered:

- **`patch_signals`** — update reactive client state
- **`patch_elements`** — patch DOM elements by CSS selector
- **`execute_script`** / **`console_log`** — run JS on the client

No GenServers. No processes. No macros. Just functions that format SSE events
and send them over a `Plug.Conn`.

## Core API

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

For real-time features (chat, tickers, notifications), use PubSub and a receive loop in your controller. The library doesn't need to own this — PubSub is the real-time primitive.

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

The Quick Start uses `Dstar.Plugs.Dispatch` to route events, but you can
skip it entirely and use plain controller actions:

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

Dstar includes CSRF token handling for Datastar requests. Two approaches:

### For Dstar helper routes (recommended)

Ensure your layout `<head>` includes Phoenix's standard CSRF meta tag:

```heex
<meta name="csrf-token" content={get_csrf_token()} />
```

`Dstar.post/2,3` and the other verb helpers read that tag directly and send it as an `x-csrf-token` header.

That means Datastar's normal signal round-tripping does **not** rewrite the helper's CSRF header.

### For mixed SSE + form routes

If you have regular Phoenix form POSTs that go through `Plug.CSRFProtection`, use `Dstar.Plugs.RenameCsrfParam`:

```elixir
# In your router, before :protect_from_forgery
plug Dstar.Plugs.RenameCsrfParam
```

Then expose the token as a **non-prefixed** signal in your layout:

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

Because `csrf` is not `_`-prefixed, Datastar will include it in each request body. The plug copies `conn.params["csrf"]` → `conn.body_params["_csrf_token"]` so `Plug.CSRFProtection` can find it.

## Lower-level Modules

The `Dstar` module delegates to these. Use them directly when you need more control.

| Module | Functions |
|--------|-----------|
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
