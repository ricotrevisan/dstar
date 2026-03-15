# Dstar

[![Hex.pm](https://img.shields.io/hexpm/v/dstar)](https://hex.pm/packages/dstar)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/dstar)

**Datastar SSE helpers for Elixir — pure functions, no framework.**

## Why Dstar?

Dstar is for people who want [Datastar's](https://data-star.dev/) reactive UI capabilities without a framework on top.

No processes. No supervision trees. No GenServers. No behaviours. No macros. Just **~700 lines of pure functions** that format and send Server-Sent Events over a Plug connection. You keep your controllers, templates, and routes exactly as they are. Dstar just adds SSE helpers.

It works with any Plug-based application: Phoenix (controller-based or LiveView-adjacent), plain Plug, Bandit. If you have a `%Plug.Conn{}`, you can use Dstar.

Think of it as the complement to "deadview" Phoenix — the controller-based approach where you own the request/response cycle. If [PhoenixDatastar](https://github.com/elixir-datastar/phoenix_datastar) gives you a LiveView-like experience with processes and channels, Dstar gives you the **raw primitives** for people who want to build their own abstractions or stay close to the metal.

## Installation

Add `dstar` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:dstar, "~> 0.0.1"}
  ]
end
```

Then add the Datastar client script to your root layout's `<head>`:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.8/bundles/datastar.js"></script>
```

That's it. No generators, no config, no application callback.

## Quick Start

### 1. A controller action

```elixir
defmodule MyAppWeb.CounterController do
  use MyAppWeb, :controller

  # Render the page — normal Phoenix
  def show(conn, _params) do
    render(conn, :counter)
  end

  # Handle a Datastar event — read signals, do work, send patches
  def increment(conn, _params) do
    signals = Dstar.read_signals(conn)
    count = (signals["count"] || 0) + 1

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
end
```

### 2. A template

```heex
<div data-signals:count="0">
  <span data-text="$count"></span>
  <button data-on:click="@post('/counter/increment')">+1</button>
</div>
```

### 3. Routes

```elixir
get "/counter", CounterController, :show
post "/counter/increment", CounterController, :increment
```

No mount, no socket, no `handle_event` callback. Read the signals, do math, send a patch. A junior dev reads this and understands it in 30 seconds.

## Core API

Everything goes through the `Dstar` convenience module, which delegates to lower-level modules.

### `Dstar.start(conn)` → `Plug.Conn.t()`

Opens an SSE connection. Sets `text/event-stream` content type, disables caching, starts a chunked response.

```elixir
conn = Dstar.start(conn)
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

### `Dstar.patch_elements(conn, html, opts)` → `Plug.Conn.t()`

Sends a `datastar-patch-elements` event. Patches DOM elements on the client.

```elixir
conn
|> Dstar.patch_elements(~s(<span id="count">42</span>), selector: "#count")
|> Dstar.patch_elements("<li>new item</li>", selector: "ul#items", mode: :append)
```

**Options:**
- `:selector` — CSS selector (required)
- `:mode` — `:outer` (default), `:inner`, `:append`, `:prepend`, `:before`, `:after`, `:replace`, `:remove`
- `:use_view_transitions` — Enable View Transitions API (default: `false`)
- `:event_id` — Event ID for client tracking
- `:retry` — Retry duration in milliseconds

### `Dstar.remove_elements(conn, selector, opts \\ [])` → `Plug.Conn.t()`

Sends a `datastar-patch-elements` event that removes matching elements.

```elixir
conn |> Dstar.remove_elements("#flash-message")
```

### `Dstar.event(module, event_name)` → `String.t()`

Generates a `@post(...)` expression for use in Datastar attributes.

```elixir
Dstar.event(MyAppWeb.CounterHandler, "increment")
# => "@post('/ds/my_app_web-counter_handler/increment', {headers: {'x-csrf-token': $_csrfToken}})"
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
        conn = Dstar.patch_signals(conn, %{tick: count})
        loop(conn)
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

## Dynamic Dispatch (Optional)

If you'd rather have one route handle all Datastar events, use `Dstar.Plugs.Dispatch`:

```elixir
# Router
post "/ds/:module/:event", Dstar.Plugs.Dispatch, modules: [
  MyAppWeb.CounterHandler,
  MyAppWeb.TodoHandler
]
```

Handler modules are plain modules with a `handle_event/3` function:

```elixir
defmodule MyAppWeb.CounterHandler do
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
end
```

The `:modules` option is an allowlist — only listed modules can be dispatched to.

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
