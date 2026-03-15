# Migrating from PhoenixDatastar to Dstar

This guide walks you through migrating an existing [PhoenixDatastar](https://github.com/elixir-datastar/phoenix_datastar) application to [Dstar](https://github.com/ricotrevisan/dstar).

## Why Migrate?

PhoenixDatastar is **deprecated as of v0.2.0** — no further updates are planned. Dstar is its successor, built on the same SSE/Datastar foundations but with a radically simpler architecture:

| | PhoenixDatastar | Dstar |
|---|---|---|
| **Architecture** | Behaviours, GenServers, Socket structs, Registry, supervision trees | ~700 lines of pure functions |
| **State** | `Socket` with assigns + signals + event queue | Direct `Plug.Conn` — no wrapper structs |
| **Routing** | Custom macros (`datastar_session`, `datastar`) | Standard Phoenix routes |
| **Views** | Stateless + Live view modes via `use` macro | Plain controller actions |
| **Real-time** | Built-in GenServer per session | PubSub + receive loop (you own it) |
| **Navigation** | Soft nav system (NavPlug, RouteRegistry, tokens) | Standard links / Datastar client-side nav |
| **Dependencies** | Phoenix (full framework) | Plug + Jason only |
| **Config** | `config :phoenix_datastar`, Registry in supervision tree | Nothing — zero config |

The tradeoff is clear: PhoenixDatastar gave you more batteries (session management, soft navigation, process-backed state). Dstar gives you **raw primitives** and gets out of your way. You write less library code and more application code.

---

## Step 1: Update Dependencies

```elixir
# mix.exs

# Before
def deps do
  [
    {:phoenix_datastar, "~> 0.2.0"}
  ]
end

# After
def deps do
  [
    {:dstar, "~> 0.0.1"}
  ]
end
```

Run `mix deps.get`.

## Step 2: Remove PhoenixDatastar Infrastructure

### Supervision tree

Remove the Registry from your `application.ex`:

```elixir
# Before — application.ex
children = [
  {Registry, keys: :unique, name: PhoenixDatastar.Registry},
  # ...
]

# After — just remove the Registry line
children = [
  # ...
]
```

### Configuration

Remove all `config :phoenix_datastar` entries from `config/`:

```elixir
# Before — config.exs
config :phoenix_datastar,
  html_module: MyAppWeb.DatastarHTML,
  strip_debug_annotations: true,
  stream_token_max_age: 3600

# After — delete these lines entirely. Dstar has no config.
```

### Web module helpers

Remove the `datastar` and `live_datastar` helper functions from your `*_web.ex`:

```elixir
# Before — my_app_web.ex
def datastar do
  quote do
    use PhoenixDatastar
    import PhoenixDatastar.Actions
    unquote(html_helpers())
  end
end

def live_datastar do
  quote do
    use PhoenixDatastar, :live
    import PhoenixDatastar.Actions
    unquote(html_helpers())
  end
end

# After — delete both functions. You won't need them.
```

## Step 3: Rewrite Routes

PhoenixDatastar used custom router macros. Dstar uses standard Phoenix routes.

### Basic routes

```elixir
# Before — router.ex
import PhoenixDatastar.Router

scope "/__datastar" do
  pipe_through [:fetch_session]
  post "/stream", PhoenixDatastar.StreamPlug, :stream
end

scope "/__datastar" do
  pipe_through [:fetch_session, :protect_from_forgery]
  post "/nav", PhoenixDatastar.NavPlug, :navigate
end

scope "/", MyAppWeb do
  pipe_through :browser

  datastar_session :default do
    datastar "/counter", CounterStar
    datastar "/todos", TodoStar
  end
end

# After — router.ex
scope "/", MyAppWeb do
  pipe_through :browser

  get "/counter", CounterController, :show
  post "/counter/increment", CounterController, :increment

  get "/todos", TodoController, :show
  post "/todos/add", TodoController, :add
  post "/todos/toggle", TodoController, :toggle
end
```

The `/__datastar/*` routes (stream, nav) are no longer needed — there are no session processes or soft navigation tokens.

### Using dynamic dispatch (optional)

If you have many events per view, you can use `Dstar.Plugs.Dispatch` instead of individual routes:

```elixir
# After (alternative) — router.ex
scope "/", MyAppWeb do
  pipe_through :browser

  get "/counter", CounterController, :show
  get "/todos", TodoController, :show
end

# Single route handles all Datastar events
post "/ds/:module/:event", Dstar.Plugs.Dispatch, modules: [
  MyAppWeb.CounterHandler,
  MyAppWeb.TodoHandler
]
```

## Step 4: Convert Views to Controllers

This is the biggest change. PhoenixDatastar views are **behaviour modules** with callbacks. Dstar uses **plain controller actions** (or handler modules with `handle_event/3`).

### Stateless views

```elixir
# Before — counter_star.ex
defmodule MyAppWeb.CounterStar do
  use MyAppWeb, :datastar

  @impl PhoenixDatastar
  def mount(_params, _session, socket) do
    {:ok, put_signal(socket, :count, 0)}
  end

  @impl PhoenixDatastar
  def handle_event("increment", payload, socket) do
    count = (payload["count"] || 0) + 1
    {:noreply, put_signal(socket, :count, count + 1)}
  end

  @impl PhoenixDatastar
  def render(assigns) do
    ~H"""
    <div>
      Count: <span data-text="$count"></span>
      <button data-on:click={event("increment")}>+</button>
    </div>
    """
  end
end
```

```elixir
# After — counter_controller.ex
defmodule MyAppWeb.CounterController do
  use MyAppWeb, :controller

  def show(conn, _params) do
    render(conn, :counter)
  end

  def increment(conn, _params) do
    signals = Dstar.read_signals(conn)
    count = (signals["count"] || 0) + 1

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
end
```

```heex
<%!-- After — counter.html.heex --%>
<div data-signals:count="0">
  Count: <span data-text="$count"></span>
  <button data-on:click="@post('/counter/increment')">+</button>
</div>
```

**Key differences:**
- No `mount/3` — initial state goes in the template via `data-signals`
- No `socket` — work directly with `conn`
- No `{:noreply, socket}` tuples — just return the conn
- No `put_signal/3` — use `Dstar.patch_signals/3`
- No `render/1` callback — use standard Phoenix templates
- No `event("name")` — use `@post('/path')` or `Dstar.post(Module, "name")`

### Stateless views using dynamic dispatch

If you prefer handler modules over controller actions (closer to the PhoenixDatastar pattern):

```elixir
# After (alternative) — counter_handler.ex
defmodule MyAppWeb.CounterHandler do
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
end
```

```heex
<%!-- Template uses Dstar.post/2 for dispatch routing --%>
<div data-signals:count="0">
  Count: <span data-text="$count"></span>
  <button data-on:click={Dstar.post(MyAppWeb.CounterHandler, "increment")}>+</button>
</div>
```

> **Note:** The `handle_event/3` signature is different — Dstar passes `(conn, event, signals)` instead of PhoenixDatastar's `(event, payload, socket)`.

### Live views (with PubSub)

Live views require the most thought. PhoenixDatastar managed a GenServer per session with persistent SSE. In Dstar, **you manage the SSE loop yourself**.

```elixir
# Before — multiplayer_star.ex
defmodule MyAppWeb.MultiplayerStar do
  use MyAppWeb, :live_datastar

  @impl PhoenixDatastar
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "game:updates")
    {:ok, assign(socket, players: [])}
  end

  @impl PhoenixDatastar
  def handle_event("join", %{"name" => name}, socket) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "game:updates", {:player_joined, name})
    {:noreply, update(socket, :players, &[name | &1])}
  end

  @impl PhoenixDatastar
  def handle_info({:player_joined, name}, socket) do
    socket = update(socket, :players, &[name | &1])
    {:noreply, patch_elements(socket, "#players", &render_players/1)}
  end

  @impl PhoenixDatastar
  def render(assigns) do
    ~H"""
    <div>
      <div id="players"><.render_players players={@players} /></div>
      <button data-on:click={event("join")}>Join</button>
    </div>
    """
  end

  defp render_players(assigns) do
    ~H"<ul><li :for={p <- @players}>{p}</li></ul>"
  end
end
```

```elixir
# After — split into controller + stream controller

# game_controller.ex (page load + events)
defmodule MyAppWeb.GameController do
  use MyAppWeb, :controller

  def show(conn, _params) do
    render(conn, :game)
  end

  def join(conn, _params) do
    signals = Dstar.read_signals(conn)
    name = signals["name"]
    Phoenix.PubSub.broadcast(MyApp.PubSub, "game:updates", {:player_joined, name})

    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{joined: true})
  end
end

# game_stream_controller.ex (persistent SSE connection)
defmodule MyAppWeb.GameStreamController do
  use MyAppWeb, :controller

  def stream(conn, _params) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "game:updates")

    conn
    |> Dstar.start()
    |> loop()
  end

  defp loop(conn) do
    receive do
      {:player_joined, name} ->
        html = Phoenix.Template.render_to_string(MyAppWeb.GameHTML, "players", %{name: name})

        conn
        |> Dstar.patch_elements(html, selector: "#players ul", mode: :append)
        |> loop()
    end
  end
end
```

```heex
<%!-- game.html.heex --%>
<div data-signals:name="''"
     data-signals:joined="false"
     data-init="@post('/game/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/game/stream', {retryMaxCount: Infinity})">

  <div id="players"><ul></ul></div>

  <input data-bind:name placeholder="Your name" />
  <button data-on:click="@post('/game/join')">Join</button>
</div>
```

```elixir
# Routes
get "/game", GameController, :show
post "/game/join", GameController, :join
post "/game/stream", GameStreamController, :stream
```

**Key differences:**
- No GenServer — the stream action *is* the long-lived process
- No `handle_info/2` callback — use a `receive` loop directly
- No automatic keepalive — Datastar's `retryMaxCount: Infinity` handles reconnection
- No session management — each stream connection is independent
- `assigns` (server-side state) don't survive across requests — use the database, ETS, or PubSub to share state

## Step 5: Update Templates

### Signals initialization

```heex
<%!-- Before: signals were set in mount/3 via put_signal --%>
<%!-- The template just referenced them with $signal_name --%>

<%!-- After: initialize signals directly in the template --%>
<div data-signals:count="0"
     data-signals:name="''"
     data-signals:items="[]">
  ...
</div>
```

### Event bindings

```heex
<%!-- Before --%>
<button data-on:click={event("increment")}>+</button>
<button data-on:click={event("save", method: :put)}>Save</button>

<%!-- After — explicit routes --%>
<button data-on:click="@post('/counter/increment')">+</button>
<button data-on:click="@put('/items/save')">Save</button>

<%!-- After — using dynamic dispatch --%>
<button data-on:click={Dstar.post(MyAppWeb.CounterHandler, "increment")}>+</button>
```

### Navigation links

```heex
<%!-- Before — soft navigation --%>
<.ds_link navigate="/settings">Settings</.ds_link>
<button data-on:click={navigate("/settings")}>Go</button>

<%!-- After — standard links (full page load) --%>
<a href="/settings">Settings</a>

<%!-- After — Datastar client-side nav (if you want SPA-like behavior) --%>
<%!-- See Datastar docs for data-on:click with fetch + DOM swap patterns --%>
```

> **Note:** Dstar does not include a soft navigation system. If you relied heavily on PhoenixDatastar's in-session navigation, you'll need to either accept full page loads or implement client-side navigation yourself using Datastar's primitives.

### Server-rendered patches

```elixir
# Before — patch_elements on socket with render function
def handle_event("refresh", _payload, socket) do
  {:noreply, patch_elements(socket, "#items", &render_items/1)}
end

defp render_items(assigns) do
  ~H"<ul id='items'><li :for={i <- @items}>{i}</li></ul>"
end

# After — patch_elements on conn with HTML string
def refresh(conn, _params) do
  items = MyApp.Items.list()
  html = Phoenix.Template.render_to_string(MyAppWeb.ItemHTML, "list", %{items: items})

  conn
  |> Dstar.start()
  |> Dstar.patch_elements(html, selector: "#items")
end
```

## Step 6: Update CSRF Setup

### Header-based approach (recommended)

```heex
<%!-- Before — layout --%>
<body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>

<%!-- After — identical! Same approach works with Dstar --%>
<body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>
```

When using Dstar's verb helpers (`post/2,3`, `get/2,3`, `put/2,3`, `patch/2,3`, `delete/2,3`), the CSRF header is automatically included in the generated expressions. If you write `@post(...)` manually, add the header yourself:

```heex
<button data-on:click="@post('/counter/increment', {headers: {'x-csrf-token': $_csrfToken}})">
  +
</button>
```

### Form + SSE approach

```elixir
# Before — router.ex
plug Dstar.Plugs.RenameCsrfParam

# After — same plug, same setup
plug Dstar.Plugs.RenameCsrfParam
```

## Step 7: Update Script Execution & Redirects

The API is nearly identical, just swap `socket` for `conn`:

```elixir
# Before
def handle_event("export", _payload, socket) do
  {:noreply,
   socket
   |> execute_script("window.alert('Done!')")
   |> redirect("/results")}
end

# After
def export(conn, _params) do
  conn
  |> Dstar.start()
  |> Dstar.execute_script("window.alert('Done!')")
  |> Dstar.redirect("/results")
end
```

## Step 8: Clean Up

1. **Delete** old view modules (`*_star.ex` or similar) once they've been converted to controllers/handlers.
2. **Delete** any custom `DatastarHTML` mount template module — Dstar doesn't use one.
3. **Remove** `import PhoenixDatastar.Router` from your router.
4. **Remove** `import PhoenixDatastar.Actions` from any modules still referencing it.
5. **Run** `mix compile --warnings-as-errors` to catch any remaining references to PhoenixDatastar modules.

---

## API Mapping Reference

| PhoenixDatastar | Dstar | Notes |
|---|---|---|
| `put_signal(socket, key, val)` | `Dstar.patch_signals(conn, %{key => val})` | Template `data-signals` for initial values |
| `put_signal(socket, map)` | `Dstar.patch_signals(conn, map)` | |
| `update_signal(socket, key, fun)` | Read + transform + `Dstar.patch_signals` | No shortcut — apply the function yourself |
| `assign(socket, key, val)` | N/A | Use controller assigns or local variables |
| `update(socket, key, fun)` | N/A | Use local variables |
| `patch_elements(socket, sel, fn)` | `Dstar.patch_elements(conn, html, selector: sel)` | Render HTML before calling |
| `patch_elements(socket, sel, html)` | `Dstar.patch_elements(conn, html, selector: sel)` | |
| `execute_script(socket, js)` | `Dstar.execute_script(conn, js)` | |
| `redirect(socket, url)` | `Dstar.redirect(conn, url)` | |
| `console_log(socket, msg)` | `Dstar.console_log(conn, msg)` | |
| `event("name")` | `Dstar.post(Module, "name")` or `@post('/path')` | All verbs available: `get`, `put`, `patch`, `delete` |
| `navigate("/path")` | Standard `<a href>` | No soft nav in Dstar |
| `PhoenixDatastar.Router.datastar/3` | Standard `get`/`post` routes | |
| `PhoenixDatastar.Router.datastar_session/3` | N/A | No sessions in Dstar |
| `{:noreply, socket}` | Return `conn` | |
| `{:stop, socket}` | Return `conn` (connection closes naturally) | |
| `handle_info/2` callback | `receive` block in stream loop | |
| `terminate/1` callback | N/A (process cleanup is automatic) | |

## Common Patterns Comparison

### Flash messages

```elixir
# Before
def handle_event("save", _payload, socket) do
  socket = assign(socket, flash: %{"info" => "Saved!"})
  {:noreply, patch_elements(socket, "#flash", &render_flash/1)}
end

# After
def save(conn, _params) do
  # ... save logic ...
  html = ~s(<div id="flash" class="alert alert-info">Saved!</div>)

  conn
  |> Dstar.start()
  |> Dstar.patch_elements(html, selector: "#flash")
end
```

### Conditional rendering

```elixir
# Before — use assigns to control render
def handle_event("toggle", _payload, socket) do
  {:noreply, update(socket, :show, &(!&1))}
end

# After — use signals (client-side)
# No server round-trip needed! Use Datastar's data-show:
# <div data-show="$show">...</div>
# <button data-on:click="$show = !$show">Toggle</button>
#
# Or if server logic is needed:
def toggle(conn, _params) do
  signals = Dstar.read_signals(conn)
  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{show: !signals["show"]})
end
```

### Loading states

```elixir
# Before — signals on socket
def handle_event("search", %{"query" => q}, socket) do
  socket = put_signal(socket, :loading, true)
  results = MyApp.Search.run(q)
  {:noreply,
   socket
   |> put_signal(:loading, false)
   |> put_signal(:results, results)}
end

# After — signals on conn
def search(conn, _params) do
  signals = Dstar.read_signals(conn)
  results = MyApp.Search.run(signals["query"])

  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{loading: false, results: results})
end
```

```heex
<%!-- In both cases, the template stays the same --%>
<div data-show="$loading">Searching...</div>
```

> **Tip:** For instant feedback, use Datastar's `data-indicator` attribute to show a loading state client-side *before* the server responds, without any server-side signal patching.

---

## FAQ

### Do I need to migrate all at once?

No. You can run both libraries side-by-side during migration since they use different routes and modules. Remove `phoenix_datastar` from your deps only after all views are converted.

### What about session state across requests?

PhoenixDatastar kept state in a GenServer between requests. Dstar is stateless — each request starts fresh. Move persistent state to:

- **The client** (Datastar signals — they're sent with every request)
- **The database** (for data that must survive across sessions)
- **ETS / Agent** (for in-memory shared state)
- **Plug session** (for user-specific server state)

### What about `terminate/1`?

If you used `terminate/1` for cleanup in live views, that logic should move to wherever you manage the resource lifecycle (e.g., a supervised process, or database cleanup on session expiry).

### Can I still use HEEx templates?

Yes. Dstar works with standard Phoenix templates. The only difference is you render them in the controller and pass the HTML string to `Dstar.patch_elements/3` instead of returning them from a `render/1` callback.

### What replaces the mount template / DefaultHTML?

Nothing. Your standard Phoenix layout (`root.html.heex`, `app.html.heex`) serves this purpose. Initialize signals with `data-signals` attributes directly in your templates.
`data-signals` attributes directly in your templates.
