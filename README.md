# Dstar

Datastar server helpers for Elixir. ~700 lines of functions that format and send
[Datastar](https://data-star.dev/) SSE events over a Plug connection. No
processes, no supervision tree, no macros, no behaviours. Sits on top of
deadview Phoenix — you keep your controllers, templates, and layouts.

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

## Quick start

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
<div data-signals-count="0">
  <span data-text="$count"></span>
  <button data-on-click="@post('/counter/increment')">+1</button>
</div>
```

### 3. Routes

```elixir
get "/counter", CounterController, :show
post "/counter/increment", CounterController, :increment
```

No mount, no socket, no handle_event callback. Read the signals, do math, send
a patch. A junior dev reads this and understands it in 30 seconds.

## Core API

Everything goes through the `Dstar` convenience module, which delegates to the
modules below.

### `Dstar.start(conn)` → `%Dstar.SSE{}`

Opens an SSE connection. Sets `text/event-stream` content type, disables
caching, starts a chunked response, and returns an `%SSE{}` struct you pipe
through the rest of the API.

### `Dstar.read_signals(conn)` → `map()`

Reads Datastar signals from the request. For `GET` requests, reads from the
`datastar` query parameter. For everything else, reads from the JSON body.

### `Dstar.patch_signals(sse, signals, opts \\ [])` → `%SSE{}`

Sends a `datastar-patch-signals` event. Updates reactive signals on the client.

```elixir
sse |> Dstar.patch_signals(%{count: 42, message: "hello"})
sse |> Dstar.patch_signals(%{defaults: true}, only_if_missing: true)
```

### `Dstar.patch_elements(sse, html, opts)` → `%SSE{}`

Sends a `datastar-patch-elements` event. Patches DOM elements on the client.

```elixir
sse |> Dstar.patch_elements(~s(<span id="count">42</span>), selector: "#count")
sse |> Dstar.patch_elements("<li>new item</li>", selector: "ul#items", mode: :append)
```

Options: `:selector` (required), `:mode` (`:outer`, `:inner`, `:append`,
`:prepend`, `:before`, `:after`, `:replace`, `:remove` — default `:outer`),
`:use_view_transitions`.

### `Dstar.remove_elements(sse, selector, opts \\ [])` → `%SSE{}`

Sends a `datastar-patch-elements` event that removes matching elements.

```elixir
sse |> Dstar.remove_elements("#flash-message")
```

### `Dstar.event(module, event_name)` → `string`

Generates a `@post(...)` expression for use in Datastar attributes.

```elixir
Dstar.event(MyAppWeb.CounterHandler, "increment")
# "@post('/ds/my_app_web-counter_handler/increment')"
```

## Real-time streaming

For real-time features (chat, tickers, notifications), use PubSub and a receive
loop in your controller. The library doesn't need to own this — PubSub is the
real-time primitive.

```elixir
defmodule MyAppWeb.TickerController do
  use MyAppWeb, :controller

  def stream(conn, _params) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "ticker")
    sse = Dstar.start(conn)
    loop(sse)
  end

  defp loop(sse) do
    receive do
      {:tick, count} ->
        sse = Dstar.patch_signals(sse, %{tick: count})
        loop(sse)
    after
      30_000 ->
        case Plug.Conn.chunk(sse.conn, ": keepalive\n\n") do
          {:ok, conn} -> loop(%{sse | conn: conn})
          {:error, _} -> :ok
        end
    end
  end
end
```

Template:

```heex
<div data-signals-tick="0"
     data-on-load="@get('/ticker/stream')">
  <span data-text="$tick"></span>
</div>
```

The library provides the SSE plumbing. Your app provides the PubSub topic and
the business logic.

## Dynamic dispatch (optional)

If you'd rather have one route handle all Datastar events, use
`Dstar.Plugs.Dispatch`:

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

The `:modules` option is an allowlist — only listed modules can be dispatched
to.

## Lower-level modules

The `Dstar` module delegates to these. Use them directly when you need more
control.

| Module | Purpose |
|---|---|
| `Dstar.SSE` | SSE struct, `start/1`, `new/1`, `send_event/4`, `send_event!/4`, `format_event/2`, `close/1` |
| `Dstar.Signals` | `read/1`, `patch/3`, `patch_raw/3`, `format_patch/2` |
| `Dstar.Elements` | `patch/3`, `remove/3`, `format_patch/2` |
| `Dstar.Actions` | `event/1,2`, `encode_module/1`, `decode_module/1` |

## Dependencies

Just two:

- [`plug`](https://hex.pm/packages/plug) — conn manipulation
- [`jason`](https://hex.pm/packages/jason) — JSON encoding/decoding

## License

MIT
