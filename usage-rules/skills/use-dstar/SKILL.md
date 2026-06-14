---
name: use-dstar
description: "Use when working with Dstar (Datastar SSE helpers for Elixir). Covers controller actions, template markup, real-time streaming, CSRF setup, and dynamic dispatch."
---

# Dstar Skill

## Overview

Dstar is a **minimalist SSE library** (~700 lines, pure functions) for Elixir/Phoenix apps using Datastar client framework.

**What it is:** Pure functions over `Plug.Conn` to send Server-Sent Events. No processes, GenServers, macros, or behaviours. Just `plug` and `jason` deps.

**What it's NOT:** LiveView replacement, PhoenixDatastar, framework, or state manager.

## Core Pattern: Read → Process → Start → Patch

```elixir
def handle_event(conn, _params) do
  signals = Dstar.read_signals(conn)  # 1. Read input
  new_value = process(signals)        # 2. Process
  conn
  |> Dstar.start()                    # 3. Open SSE
  |> Dstar.patch_signals(%{key: new_value})  # 4. Send updates
end
```

## API Reference

### Connection & Signals

- `Dstar.start(conn)` — Open SSE (chunked, text/event-stream)
- `Dstar.read_signals(conn)` — Read signals from GET query or POST body
- `Dstar.patch_signals(conn, %{key: value}, opts)` — Send signal updates
  - `only_if_missing: true` — Only set if client doesn't have key
  - `event_id: "123"`, `retry: 5000`

### DOM Manipulation

- `Dstar.patch_elements(conn, html, selector: "#id", mode: :inner)` — Patch HTML
  - Modes: `:outer`, `:inner`, `:append`, `:prepend`, `:before`, `:after`, `:replace`, `:remove`
  - `use_view_transitions: true`
- `Dstar.remove_elements(conn, "#selector")`

### Scripts & Navigation

- `Dstar.execute_script(conn, "console.log('hi')", auto_remove: true)`
- `Dstar.redirect(conn, "/path")`
- `Dstar.console_log(conn, "Debug info", level: :warn)` — Levels: `:log`, `:warn`, `:error`, `:info`, `:debug`

### HTTP Verb Helpers

- `Dstar.post(MyHandler, "increment")` → `"@post('/ds/my_handler/increment', {...})"`
- `Dstar.delete(MyHandler, "remove")` → `"@delete('/ds/my_handler/remove', {...})"`
- `Dstar.post(MyHandler, "save", prefix: "/workspace")` — URL prefix
- `Dstar.post("increment")` — Dynamic module (reads `$_dstar_module` signal from client)
- All HTTP verbs available: `get/2,3`, `put/2,3`, `patch/2,3`, `delete/2,3`

## Controller Patterns

### Stateless Event Handler

```elixir
def increment(conn, _params) do
  signals = Dstar.read_signals(conn)
  count = (signals["count"] || 0) + 1
  
  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{count: count})
end
```

### With DOM Patching

```elixir
def add_item(conn, _params) do
  signals = Dstar.read_signals(conn)
  item = %{id: UUID.uuid4(), name: signals["new_item"]}
  
  html = Phoenix.Template.render_to_string(
    MyAppWeb.ItemView, "item.html", item: item
  )
  
  conn
  |> Dstar.start()
  |> Dstar.patch_elements(html, selector: "#items", mode: :append)
  |> Dstar.patch_signals(%{new_item: ""})
end
```

### Real-time Streaming

```elixir
def live_feed(conn, _params) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "feed")
  conn = Dstar.start(conn)
  stream_loop(conn)
end

defp stream_loop(conn) do
  receive do
    {:new_post, post} ->
      conn = Dstar.patch_signals(conn, %{latest: post})
      stream_loop(conn)
  end
end
```

## Template Patterns

### Signal Value Quoting

Signal values are **JavaScript expressions**:
```heex
data-signals:count="0"           <%!-- Number --%>
data-signals:name="''"           <%!-- Empty string (JS quotes needed) --%>
data-signals:id={"'#{@id}'"}     <%!-- Dynamic string (HEEx + JS quotes) --%>
data-signals:active="false"      <%!-- Boolean --%>
data-signals:items="[]"          <%!-- Array --%>
```

### Basic Signals & Binding

```heex
<div data-signals:count="0">
  <p>Count: <span data-text="$count"></span></p>
  <button data-on:click={Dstar.post(CounterHandler, "increment")}>
    Increment
  </button>
</div>
```

### Forms with Input Binding

```heex
<div data-signals:name="''"
     data-signals:email="''">
  <input type="text" data-model="name" placeholder="Name">
  <input type="email" data-model="email" placeholder="Email">
  <button data-on:click={Dstar.post(FormHandler, "submit")}>
    Submit
  </button>
  
  <p data-show="$name">Hello, <span data-text="$name"></span>!</p>
</div>
```

### Conditional Rendering

```heex
<div data-signals:loading="false"
     data-signals:error="''">
  <div data-show="$loading">Loading...</div>
  <div data-show="$error" data-text="$error" class="error"></div>
  <button data-show="!$loading"
          data-on:click={Dstar.post(DataHandler, "load")}>
    Load Data
  </button>
</div>
```

### Streaming Updates

```heex
<div data-init="@post('/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/stream', {retryMaxCount: Infinity})"
     data-signals:messages="[]">
  <ul>
    <template data-for="msg in $messages">
      <li data-text="msg.content"></li>
    </template>
  </ul>
</div>
```

## CSRF Setup

Datastar has **no built-in CSRF support** — it does not read Phoenix's `<meta name="csrf-token">` tag and never sets an `x-csrf-token` header. The token must travel as a signal.

**Router (before `:protect_from_forgery`):**
```elixir
pipeline :browser do
  plug Dstar.Plugs.RenameCsrfParam  # safely no-ops when param isn't present
  plug :protect_from_forgery
end
```

**Layout:**
```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

Because `csrf` is not `_`-prefixed, Datastar will include it in each request body. `Dstar.Plugs.RenameCsrfParam` copies that value into `_csrf_token` for `Plug.CSRFProtection`. This one setup covers page events, stream connects, component events, and the verb helpers.

For Datastar-only routes you can instead use a pipeline without `:protect_from_forgery` — simpler, but those endpoints then rely on your session/auth checks alone.

## Dynamic Dispatch

**Router:**
```elixir
post "/ds/:module/:event", Dstar.Plugs.Dispatch,
  modules: [MyApp.CounterHandler, MyApp.TodoHandler]
```

**Handler Module:**
```elixir
defmodule MyApp.TodoHandler do
  def handle_event(conn, "add", signals) do
    todo = %{id: UUID.uuid4(), text: signals["new_todo"], done: false}
    # Save to DB
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{new_todo: "", todos: [todo | signals["todos"]]})
  end
  
  def handle_event(conn, "toggle", signals) do
    todo_id = signals["todo_id"]
    # Toggle in DB
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{updated_at: DateTime.utc_now()})
  end
end
```

**Template:**
```heex
<button data-on:click={Dstar.post(TodoHandler, "add")}>
  Add Todo
</button>
```

## Common Mistakes & Fixes

### ❌ Multiple start() calls
```elixir
# Wrong
conn = Dstar.start(conn)
conn = Dstar.start(conn)  # Error!
```

**✅ Fix:** Call `start()` once, chain patches
```elixir
conn
|> Dstar.start()
|> Dstar.patch_signals(...)
|> Dstar.patch_elements(...)
```

### ❌ Mixing with render/json
```elixir
# Wrong
conn
|> Dstar.patch_signals(...)
|> render("index.html")  # Conflict!
```

**✅ Fix:** SSE responses are complete, don't render after

### ❌ Storing conn state in GenServers
```elixir
# Wrong - connections are stateless
GenServer.start_link(ConnectionWorker, conn)
```

**✅ Fix:** Use PubSub for broadcasting, signals for client state

### ❌ Subscribe after start in streaming
```elixir
# Wrong - messages lost
conn = Dstar.start(conn)
PubSub.subscribe(...)
```

**✅ Fix:** Subscribe → start → loop
```elixir
PubSub.subscribe(...)
conn = Dstar.start(conn)
loop(conn)
```

## Chaining Multiple Updates

```elixir
conn
|> Dstar.start()
|> Dstar.patch_signals(%{loading: false})
|> Dstar.patch_elements("<p>Done!</p>", selector: "#status")
|> Dstar.console_log("Operation complete")
```

All patches sent in one SSE stream.
