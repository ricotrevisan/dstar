# Dstar Usage Rules

## What Dstar Is

Dstar is a **minimalist SSE library** (~700 lines) providing pure functions over `Plug.Conn` to format and send Server-Sent Events for Datastar client-side framework. Two deps: `plug` and `jason`.

**Not:** LiveView, PhoenixDatastar, a framework, or a state management system. No processes, GenServers, supervision trees, behaviours, or macros.

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
- **`Dstar.redirect(conn, url, opts \\ [])`** — Client-side redirect
- **`Dstar.console_log(conn, message, opts \\ [])`** — Browser console output
  - Opts: `:level` (`:log`/`:warn`/`:error`/`:info`/`:debug`)

### HTTP Verb Helpers

- **`Dstar.post(module, event_name)`** — Generates `@post("/ds/:module/:event", {...})` for attributes
- **`Dstar.post(module, event_name, opts)`** — With options (`:prefix` for URL prefix)
- **`Dstar.post(event_name, opts)`** — Dynamic module variant (reads `$_dstar_module` signal from client)
- All HTTP verbs available: `Dstar.get/2,3`, `Dstar.put/2,3`, `Dstar.patch/2,3`, `Dstar.delete/2,3`

## CSRF Setup

**Approach 1: Header-based (recommended)**

```heex
<body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>
```

The `_` prefix makes it client-only; sent as `x-csrf-token` header. Dstar's verb helpers (`post/2,3`, `get/2,3`, `put/2,3`, `patch/2,3`, `delete/2,3`) auto-include this.

**Approach 2: Form-compat** (for mixed SSE + regular form routes)

```elixir
# In your router pipeline, BEFORE :protect_from_forgery:
plug Dstar.Plugs.RenameCsrfParam
plug :protect_from_forgery
```

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

The plug safely no-ops when the param isn't present, so it's fine to use globally.

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

Client: `data-on:click={Dstar.post(CounterHandler, "increment")}`

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
dencies

Only two: `{:plug, "~> 1.14"}` and `{:jason, "~> 1.4"}`
"~> 1.14"}` and `{:jason, "~> 1.4"}`
y two: `{:plug, "~> 1.14"}` and `{:jason, "~> 1.4"}`
"~> 1.14"}` and `{:jason, "~> 1.4"}`
