# Dstar

[![Hex.pm](https://img.shields.io/hexpm/v/dstar)](https://hex.pm/packages/dstar)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/dstar)

**Datastar SSE helpers for Elixir — pure functions, no framework.**

## Why Dstar?

Phoenix LiveView without the websocket hiccups. It brings [Datastar's](https://data-star.dev/) reactive UI capabilities on top of a simple Phoenix DeadView app.

No processes. No supervision trees. No GenServers. No behaviours. No macros. Just **~700 lines of pure functions** that format and send Server-Sent Events over a Plug connection. You keep your controllers, templates, and routes exactly as they are. Dstar just adds SSE helpers.

It works with any Plug-based application: Phoenix (controller-based or LiveView-adjacent), plain Plug, Bandit. If you have a `%Plug.Conn{}`, you can use Dstar.

Think of it as the complement to "deadview" Phoenix — the controller-based approach where you own the request/response cycle. 

## Installation

Add `dstar` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:dstar, "~> 0.0.4"}
  ]
end
```

Then add the Datastar client script to your root layout's `<head>`:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.8/bundles/datastar.js"></script>
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
`@post(...)` expression with the correct path and CSRF headers so you
never hand-write URLs. One dispatch route, as many handlers as you want.

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

Sends a `datastar-patch-elements` event. Patches DOM elements on the client.

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
# => "@post('/ds/my_app_web-counter_handler/increment', {headers: {'x-csrf-token': $_csrfToken}})"

Dstar.delete(MyAppWeb.TodoHandler, "remove")
# => "@delete('/ds/my_app_web-todo_handler/remove', {headers: {'x-csrf-token': $_csrfToken}})"
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

### For SSE routes (recommended)

Add a `_csrfToken` signal to your root layout:

```heex
<body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>
```

The `_` prefix means Datastar treats it as client-only — it's sent as an `x-csrf-token` header but not in the request body. Dstar's `event/2,3` helpers automatically include this header in generated `@post(...)` expressions.

### For mixed SSE + form routes

If you have regular Phoenix form POSTs that go through `Plug.CSRFProtection`, use `Dstar.Plugs.RenameCsrfParam`:

```elixir
# In your router, before :protect_from_forgery
plug Dstar.Plugs.RenameCsrfParam
```

Then use a **non-prefixed** signal in your layout:

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

The plug copies `conn.params["csrf"]` → `conn.body_params["_csrf_token"]` so `Plug.CSRFProtection` can find it.

## Lower-level Modules

The `Dstar` module delegates to these. Use them directly when you need more control.

| Module | Functions |
|--------|-----------|
| `Dstar.SSE` | `start/1`, `send_event/3,4`, `send_event!/3,4`, `format_event/2` |
| `Dstar.Signals` | `read/1`, `patch/2,3`, `patch_raw/2,3`, `format_patch/1,2` |
| `Dstar.Elements` | `patch/2,3`, `remove/2,3`, `format_patch/1,2` |
| `Dstar.Actions` | `event/1,2,3`, `encode_module/1`, `decode_module/1` |
| `Dstar.Scripts` | `execute/2,3`, `redirect/2,3`, `console_log/2,3` |
| `Dstar.Plugs.Dispatch` | Standard Plug for dynamic event routing |
| `Dstar.Plugs.RenameCsrfParam` | Standard Plug for CSRF param compatibility |

## Dependencies

Just two:

- [`plug`](https://hex.pm/packages/plug) — Conn manipulation
- [`jason`](https://hex.pm/packages/jason) — JSON encoding/decoding

## License

MIT
T
