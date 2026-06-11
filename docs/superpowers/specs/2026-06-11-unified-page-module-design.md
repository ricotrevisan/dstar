# Dstar Unified Page Module — Design

**Date:** 2026-06-11
**Status:** Approved (brainstorm with Rico)
**Scope:** New `Dstar.Page`, `Dstar.Component`, and `Dstar.Router` layers; docs restructure; Defacto migration path.

## Problem

Phoenix LiveView puts a page's render, event handlers, and components in one module. A
Dstar/deadview page today is sprawled across three modules plus wiring:

- `*_controller.ex` — `show/2` (page render), `stream/2` (hand-written SSE receive loop),
  many `handle_event/3` clauses, data loaders. Defacto's `PrewriteController` is ~1,750 lines.
- `*_html.ex` — the full-page template.
- `*_components.ex` — function components shared between the initial render and SSE patches.
- Two router lines per page, plus registration in `Dstar.Plugs.Dispatch`'s `modules:` list.
- `handler={@handler}` and `prefix={@prefix}` threaded through every component, because
  `event/3` builds absolute URLs server-side and components can't know module or path prefix.
- `conn |> Dstar.start()` ritual opening every event handler.

The split exists for two mechanical reasons: `use :controller` and `use :html` have
conflicting imports (`Plug.Conn.assign/3` vs `Phoenix.Component.assign/2,3`), and
`render(conn, :show)` conventionally looks up a separate `*HTML` module.

## Decisions (made during brainstorm)

1. **Primary goal: colocation.** One module per page: render + events + components.
2. **Front and center.** The unified module becomes THE recommended way to use Dstar.
   README and docs restructure around it. The existing API is re-titled "the functional core."
3. **Library owns the SSE receive loop.** Pages declare subscriptions in a connect callback
   and implement `handle_info/2`; the loop, idle checks, and cleanup are library code.
4. **Router macro.** `dstar "/path", Module` wires the page's GET render, event POST, and
   stream POST in one line. The route is the allowlist.
5. **Implementation: behaviour + runner plug** (not macro-injected controller). `use Dstar.Page`
   is a thin macro (behaviour, imports, helpers). All control flow lives in a plain, testable
   `Dstar.Page.Runner` module that routes target.
6. **`Dstar.Component` is in scope for v1.** Shared UI + its event handlers in one module
   (LiveComponent's colocation without its state machinery).
7. **No socket struct, no server-side page state.** Conn in, conn out, everywhere. State lives
   in client signals and the database, per Datastar's model. (The grug-simplify plan axed a
   Socket once; it stays dead.)

## Concept map

| Concept | Unit of | Routing | `event/1` target |
|---|---|---|---|
| `Dstar.Page` | A routed page: mount/render/events/stream | `dstar "/path", Module` | `location.pathname + '/_event/<name>'` |
| `Dstar.Component` | Shared UI + its events (drawers, pickers) | `dstar_components "/ds", [Modules]` | `(document.body.dataset.dsPrefix \|\| '') + '/ds/<module>/<name>'` |
| Functional core | Conn helpers (`Dstar.*`) | n/a | n/a |

`Dstar.Plugs.Dispatch` remains in the library as the engine under `dstar_components` and the
escape hatch for handler-only modules. `Dstar.post(Module, "event")` remains the explicit
cross-page form.

## `Dstar.Page`

### Callbacks

| Callback | Required | Purpose |
|---|---|---|
| `mount(conn, params) → conn` | optional | GET: load data, `assign/2` what render needs. Default: passthrough. |
| `render(assigns) → rendered` | yes | Full-page `~H` template. |
| `handle_event(conn, event, signals) → conn` | optional | Datastar event POSTs. SSE is already started when called. |
| `handle_connect(conn, params) → conn` | optional | Stream open: subscribe to PubSub (app's choice of `Endpoint.subscribe` or `Phoenix.PubSub`), assign loop state. Defining it enables stream behavior. |
| `handle_info(msg, conn) → conn \| {:halt, conn}` | optional | Called by the library-owned loop per message. `{:halt, conn}` ends the stream deliberately. |
| `stream_key(conn) → term` | optional | If defined, stream opens via `Dstar.start_stream/2` (StreamRegistry dedup) keyed on the result; else `Dstar.start/1`. |

`mount` and `handle_connect` are deliberately separate callbacks (no LiveView-style dual-mode
`mount`): they are different requests with different jobs.

### Example

```elixir
defmodule MyAppWeb.CounterPage do
  use Dstar.Page

  def mount(conn, _params) do
    assign(conn, count: 0, page_title: "Counter")
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div data-signals:count={@count}>
        <h1 data-text="$count"></h1>
        <button data-on:click={event("increment")}>+1</button>
        <.history value={@count} />
      </div>
    </Layouts.app>
    """
  end

  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> patch_signals(%{count: count})
    |> patch(&history/1, value: count)
  end

  def handle_connect(conn, _params) do
    MyAppWeb.Endpoint.subscribe("ticker")
    conn
  end

  def handle_info(%Phoenix.Socket.Broadcast{payload: p}, conn) do
    patch_signals(conn, %{tick: p.count})
  end

  defp history(assigns) do
    ~H"""
    <span id="history">Last: {@value}</span>
    """
  end
end
```

### What `use Dstar.Page` does (exhaustively)

1. `@behaviour Dstar.Page`
2. `use Phoenix.Component` (brings `~H`, `attr`, `slot`), excluding the `assign` family
3. Imports the assign shim: `assign/2,3`, `assign_new/3`, `update/3` that pattern-match —
   `%Plug.Conn{}` → `Plug.Conn` semantics; otherwise → `Phoenix.Component` semantics.
   One name works in `mount`/`handle_event` (conn) and inside components (assigns maps).
4. `import Dstar` (the conn helpers: `patch_signals`, `patch_elements`, `execute_script`,
   `console_log`, `redirect`, …) and `import Dstar.Page.Helpers` (`event/1,2`, `connect/0,1`,
   `patch/3,4`).
5. Accepts `use Dstar.Page, idle_check: 10_000` to override the stream idle-check interval
   (default 30_000 ms).
6. Nothing else. No injected `init/call`, no hidden state, no module attributes.

### Helpers

- `event(name, opts \\ [])` — emits a Datastar expression resolved client-side:
  `@post(location.pathname + '/_event/<name>')`. `opts` supports `verb: :get | :put | :patch | :delete`
  (default `:post`) and a raw `opts:` string merged into the action's options object.
  Rationale: Datastar attribute values are JavaScript; the browser knows the current path —
  including live path params like `/:workspace_slug` — so no server-side URL building, no
  handler/prefix threading.
- `connect(opts \\ [])` — emits `@post(location.pathname, {retryMaxCount: Infinity})` for
  `data-init` / `data-on:online__window` stream attachment. `opts` supports the same `opts:`
  raw-string override as `event/2` for customizing the action's options object.
- `patch(conn, component_fun, assigns, opts \\ [])` — renders the component function and pipes
  it to `Dstar.patch_elements`. With no `:selector`, relies on Datastar's id-based matching
  (the component's root element must carry an `id`). Opts pass through (`:selector`, `:mode`, …).

### Boundary: page-local vs cross-page events

`location.pathname` is only correct for events handled by the page the user is on. UI shared
across pages (drawers, pickers) must not use it — that is what `Dstar.Component` (below) and
the explicit `Dstar.post(Module, "event")` form are for. Rule of thumb in docs: *component
belongs to this page → `event("name")`; shared across pages → it lives in a `Dstar.Component`.*

## Routing — `Dstar.Router`

```elixir
import Dstar.Router

dstar "/counter", MyAppWeb.CounterPage
dstar "/:workspace_slug/meetings/:meeting_ref/prewrite", DefactoWeb.Meetings.PrewritePage
dstar_components "/ds", [DefactoWeb.Items.DetailDrawer]
```

`dstar/2` expands to plain Phoenix routes targeting `Dstar.Page.Runner` with `page: Module`:

```
GET   /path                 → Runner.page    (mount + render)
POST  /path                 → Runner.stream  (handle_connect + loop)
POST  /path/_event/:event   → Runner.event   (handle_event)
```

- The route **is** the allowlist: a page is reachable because you routed it. No module-name
  encoding in page URLs, no `modules:` registration.
- Path params arrive in `params` like any Phoenix route.
- Whether the page defines `handle_connect/2` is checked at runtime via `function_exported?`
  (no compile-time dependency from the router onto page modules). `POST /path` without
  `handle_connect` → 404.
- `_event` is a reserved path segment under page paths.

`dstar_components/2` expands to `post "<base>/:module/:event"` targeting `Dstar.Plugs.Dispatch`
with the given allowlist — sugar over the existing plug.

## `Dstar.Page.Runner`

A plain module of ordinary functions; routes point at it as a plug. No macro-generated control
flow.

- **page(conn)** — calls `mount/2` if exported; if a response was already sent or conn halted
  (auth plugs, redirects), stops; otherwise renders via the standard Phoenix view pipeline:
  `conn |> put_view(html: page) |> render(:render)`. Root layout (where the Datastar `<script>`
  lives), `@conn`, `@flash`, `page_title` all behave exactly like a vanilla controller. Inner
  layouts are explicit components in `render/1` (Phoenix 1.8 style). No custom page renderer.
- **event(conn)** — reads signals, starts SSE (`Dstar.start/1`), calls
  `handle_event(conn, event, signals)`. Handlers never call `Dstar.start()` themselves.
- **stream(conn)** — opens SSE (`start_stream/2` if `stream_key/1` is exported, else `start/1`),
  calls `handle_connect/2`, then enters the loop:

```elixir
defp loop(conn, page) do
  receive do
    msg ->
      case page.handle_info(msg, conn) do
        {:halt, conn} -> conn
        conn -> loop(conn, page)
      end
  after
    idle_check ->
      case Dstar.check_connection(conn) do
        {:ok, conn} -> loop(conn, page)
        {:error, conn} -> conn
      end
  end
end
```

- No `terminate` callback: the conn process dying cleans up PubSub subscriptions (process-bound).
- **Stray-message tolerance:** a message matching no `handle_info/2` clause logs a warning and
  continues the loop. Implemented narrowly — only a `FunctionClauseError` whose stacktrace head
  is `{page, :handle_info, 2}` is absorbed; errors raised inside a matched clause crash normally.

### Error handling

- `mount` redirect/halt: Runner checks `conn.halted` / response state before rendering.
- `handle_event` crash: request process crashes as in any controller action. Because SSE is
  already started, the browser sees a dead stream rather than a 500 page. Mitigation:
  `config :dstar, debug_errors: true` (docs instruct setting it in `dev.exs`) makes the Runner
  rescue, push the error + stacktrace to the browser console via
  `console_log(level: :error)`, then re-raise. Default: `false`.
- Unknown event name with no matching clause = `FunctionClauseError` = a bug; it crashes (with
  the `debug_errors` relay in dev).

## `Dstar.Component`

Shared UI + its event handlers in one module. Colocation only — **no** server-side component
state, no `update/preload` lifecycle, no per-component assigns. State lives in signals, the
DOM, and the database.

```elixir
defmodule DefactoWeb.Items.DetailDrawer do
  use Dstar.Component

  def drawer(assigns) do
    ~H"""
    <div id="item-detail-drawer">
      <input
        data-bind="detail.title"
        data-on:change={event("change_title:#{@item.id}")}
        value={@item.title}
      />
    </div>
    """
  end

  def handle_event(conn, "change_title:" <> item_id, signals) do
    scope = conn.assigns.current_scope
    item = Defacto.Items.get_item_by_id!(item_id, scope: scope)
    item = Defacto.Items.update_item!(item, %{title: signals["detail"]["title"]}, scope: scope)

    patch(conn, &drawer_title/1, item: item)
  end

  defp drawer_title(assigns), do: ~H"..."
end
```

- Pages embed it as a plain function component (`<DetailDrawer.drawer item={@item} />`) and
  need zero `handle_event` clauses for it.
- `use Dstar.Component` = `use Dstar.Page`'s macro minus the page behaviour/runner concerns:
  `Phoenix.Component` + assign shim + `import Dstar` + helpers, where `event/1,2` targets the
  component's dispatch URL instead of `location.pathname`.
- **Prefix handling:** the root layout declares the mount prefix once —
  `<body data-ds-prefix={workspace_path(@current_scope.workspace.slug)}>` — and component
  `event/1` emits `@post((document.body.dataset.dsPrefix || '') + '/ds/<module>/<name>')`.
  Apps without a prefix set nothing; it degrades to `''`. This replaces per-component `prefix`
  attrs entirely.
- **Page ↔ component coordination:** a component never reaches into a page. It patches its own
  elements; for cross-cutting updates (e.g., a page list refreshing after a drawer rename) it
  broadcasts on PubSub and pages react in `handle_info`. (Defacto already works this way:
  `item:workspace:*` broadcasts drive `patch_prewrite_step`.)

## Testing

- **Components:** `Phoenix.LiveViewTest.render_component/2` works on any function component
  (no LiveView process involved).
- **Callbacks:** `handle_event/3`, `handle_connect/2`, `handle_info/2` are plain functions on
  conns — unit-test directly.
- **Full request:** `Phoenix.ConnTest`. `get(conn, "/counter")` for the page;
  `post(conn, "/counter/_event/increment")` — chunked SSE accumulates in `conn.resp_body`.
- **`Dstar.Test`** (new, small): parses SSE events out of a test conn and provides assertions:
  `assert_patched_signals(conn, %{count: 1})`, `assert_patched_element(conn, "#history")`.
- **Runner:** tested in dstar itself as plain functions. Streams are unit-tested via callbacks;
  full-stream integration tests are possible (task + timeout) but not the primary path.

## Dependencies

| Dep | Status | Why |
|---|---|---|
| `plug`, `jason` | required (unchanged) | functional core |
| `phoenix` ~> 1.7 | new, `optional: true` | router macro, controller render pipeline |
| `phoenix_live_view` ~> 1.0 | new, `optional: true` | `Phoenix.Component` / `~H` live there |

Page/Component/Router modules compile only when the optional deps are present. A plug-only app
gets exactly today's Dstar.

## Naming

`Dstar.Page`, `Dstar.Component`, `Dstar.Router`, `Dstar.Page.Runner`, `Dstar.Test`;
macros `dstar/2`, `dstar_components/2`; helpers `event/1,2`, `connect/0,1`, `patch/3,4`.
(`Dstar.Component` deliberately echoes `Phoenix.Component`; fallback name if the echo proves
confusing in practice: `Dstar.Partial`.)

## Docs restructure ("front and center")

- README Quick Start rewritten around a one-module `CounterPage` + one router line.
- Current functional API re-titled **"The functional core"**, positioned as the layer underneath
  and the escape hatch.
- `usage-rules/` skills updated to lead with pages; `Dispatch` reframed as the cross-page
  handler engine.
- Version bump to **0.1.0** to mark the shape change. Migration notes for `0.0.x` users
  (nothing breaks; pages are additive).

## Defacto migration path (proving ground, in risk order)

1. Bump dstar; convert one small page (e.g., `Meetings.Settings`: controller + html +
   components → one `SettingsPage`, one `dstar` router line).
2. Convert the shared drawer: `Items.Detail.Handler` + `Items.Detail.Components` →
   `Items.DetailDrawer`; add `data-ds-prefix` to the root layout; one `dstar_components` line.
3. Convert Prewrite last — the stress test: ~30 handlers, hand-written stream loop →
   `handle_connect`/`handle_info`, drawer embedding.
4. Old and new coexist throughout (both are just routes); land page-by-page in normal PRs,
   removing Dispatch `modules:` entries as pages convert.

## Out of scope / rejected

- **Socket/assigns-diffing state model** — rebuilding LiveView; contradicts Datastar's
  client-holds-state model and the grug-simplify history.
- **Stateful components (LiveComponent lifecycle)** — colocation only, see above.
- **Macro-injected controller** (approach B) — control flow belongs in a readable runner
  module, not macro expansion.
- **Merge-modules-only** (approach C) — would not deliver the streaming and routing decisions.
- **Non-POST event verbs in the router macro** — `event/2` supports verb overrides, but v1
  routes only `POST /path/_event/:event`; other verbs remain on the Dispatch/explicit path.
  Revisit if real demand appears.

## Success criteria

- A page is one module and one router line; the counter example fits in the README intro.
- No `handler`/`prefix` attrs anywhere in page-local components; no `Dstar.start()` in handlers.
- Defacto's Prewrite converts without behavior loss and with a net reduction in lines/files.
- The functional core remains untouched and fully usable without the optional deps.
