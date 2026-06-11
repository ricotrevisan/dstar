# Dstar Unified Page Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `Dstar.Page`, `Dstar.Component`, `Dstar.Page.Plug`, `Dstar.Router`, and `Dstar.Test` per the approved spec at `docs/superpowers/specs/2026-06-11-unified-page-module-design.md`, so a Datastar page is one module and one router line.

**Architecture:** A `Dstar.Page` behaviour with a thin `use` macro (imports + helpers, no control flow); all request handling lives in `Dstar.Page.Plug`, a plain plug that routes target via the `dstar/2` router macro. `Dstar.Component` is the same macro minus page concerns, with `event/2` targeting the Dispatch URL. Conn in, conn out everywhere; no socket, no processes beyond the SSE conn itself.

**Tech Stack:** Elixir ~> 1.14, Plug, Jason; new *optional* deps `phoenix` ~> 1.7 (render pipeline, router macros) and `phoenix_live_view` ~> 1.0 (`Phoenix.Component`, `~H`).

**Repo:** `/Users/rico/dev/packages/dstar` — all paths below are relative to it. Run all commands from the repo root.

**Out of scope:** The Defacto migration (spec's proving ground) is a separate follow-up plan in the Defacto repo.

**Conventions used throughout:**
- Tests: `use ExUnit.Case, async: true` + `import Plug.Test` (matches `test/dstar/plugs/dispatch_test.exs`).
- Existing facts you can rely on: `Dstar.SSE.start/1` sends a chunked 200 with `text/event-stream`; on the `Plug.Test` adapter, chunks accumulate into `conn.resp_body`. `Dstar.Elements.patch(conn, html, opts)` accepts binaries, `{:safe, iodata}`, and anything implementing `Phoenix.HTML.Safe` (including `%Phoenix.LiveView.Rendered{}`). Signals data lines look like `signals {"count":1}`; element data lines look like `selector #id`, `mode inner` (only when non-default), `elements <div>...</div>`.
- **Import collision warning:** `Dstar` already exports `patch/1,2,3` and `event/2,3` (URL builders). The new page helpers define `event/1,2` and `patch/3,4` with different meanings. Page/component modules therefore import `Dstar` with an explicit `only:` list of conn helpers — never `import Dstar` bare.

---

## File Structure

| File | Responsibility |
|---|---|
| `mix.exs` (modify) | optional deps, version, docs groups |
| `lib/dstar/page/assigns.ex` (create) | `assign/2,3`, `assign_new/3`, `update/3` shim: `%Plug.Conn{}` → Plug semantics, else → `Phoenix.Component` |
| `lib/dstar/page/helpers.ex` (create) | `event/1,2`, `connect/0,1`, `patch/3,4` |
| `lib/dstar/page.ex` (create) | behaviour + `use` macro |
| `lib/dstar/page/plug.ex` (create) | the plug: `page`/`event`/`stream` actions + receive loop |
| `lib/dstar/component.ex` (create) | `use` macro for shared components + `build_event/3` |
| `lib/dstar/router.ex` (create) | `dstar/2`, `dstar_components/2` macros |
| `lib/dstar/test.ex` (create) | SSE parsing + assertions for test conns |
| `test/dstar/page/assigns_test.exs`, `test/dstar/page/helpers_test.exs`, `test/dstar/page_test.exs`, `test/dstar/page/plug_test.exs`, `test/dstar/component_test.exs`, `test/dstar/router_test.exs`, `test/dstar/test_test.exs` (create) | one test file per module |
| `README.md`, `CHANGELOG.md`, `usage-rules.md` (modify) | docs restructure |

---

### Task 1: Optional dependencies

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add optional deps**

In `mix.exs`, replace the `deps` function:

```elixir
  defp deps do
    [
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end
```

- [ ] **Step 2: Fetch and compile**

Run: `mix deps.get && mix compile --warnings-as-errors`
Expected: deps fetch (phoenix, phoenix_live_view, phoenix_html, phoenix_template, etc.), clean compile.

- [ ] **Step 3: Verify existing tests still pass**

Run: `mix test`
Expected: all existing tests PASS.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add optional phoenix and phoenix_live_view"
```

---

### Task 2: `Dstar.Page.Assigns` — the assign shim

One set of names (`assign`, `assign_new`, `update`) that works on a `%Plug.Conn{}` in `mount`/`handle_event` and on sockets/assigns maps inside function components.

**Files:**
- Create: `lib/dstar/page/assigns.ex`
- Test: `test/dstar/page/assigns_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/page/assigns_test.exs`:

```elixir
defmodule Dstar.Page.AssignsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Page.Assigns

  describe "assign/2,3 with %Plug.Conn{}" do
    test "assign/3 sets a conn assign" do
      conn = conn(:get, "/") |> assign(:count, 1)
      assert conn.assigns.count == 1
    end

    test "assign/2 sets multiple assigns from a keyword list" do
      conn = conn(:get, "/") |> assign(count: 1, name: "rico")
      assert conn.assigns.count == 1
      assert conn.assigns.name == "rico"
    end

    test "assign/2 sets multiple assigns from a map" do
      conn = conn(:get, "/") |> assign(%{count: 2})
      assert conn.assigns.count == 2
    end
  end

  describe "assign_new/3 with %Plug.Conn{}" do
    test "assigns when key is absent" do
      conn = conn(:get, "/") |> assign_new(:count, fn -> 5 end)
      assert conn.assigns.count == 5
    end

    test "keeps existing value" do
      conn = conn(:get, "/") |> assign(:count, 1) |> assign_new(:count, fn -> 5 end)
      assert conn.assigns.count == 1
    end

    test "supports arity-1 fun receiving current assigns" do
      conn =
        conn(:get, "/")
        |> assign(:base, 10)
        |> assign_new(:count, fn assigns -> assigns.base + 1 end)

      assert conn.assigns.count == 11
    end
  end

  describe "update/3 with %Plug.Conn{}" do
    test "updates an existing assign" do
      conn = conn(:get, "/") |> assign(:count, 1) |> update(:count, &(&1 + 1))
      assert conn.assigns.count == 2
    end

    test "raises when key is missing" do
      assert_raise KeyError, fn ->
        conn(:get, "/") |> update(:missing, &(&1 + 1))
      end
    end
  end

  describe "delegation to Phoenix.Component for non-conn values" do
    test "assign/3 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign(assigns, :count, 1).count == 1
    end

    test "assign/2 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign(assigns, count: 3).count == 3
    end

    test "assign_new/3 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign_new(assigns, :count, fn -> 7 end).count == 7
    end

    test "update/3 works on an assigns map" do
      assigns = %{__changed__: nil, count: 1}
      assert update(assigns, :count, &(&1 + 1)).count == 2
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page/assigns_test.exs`
Expected: FAIL — `module Dstar.Page.Assigns is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/page/assigns.ex`:

```elixir
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Dstar.Page.Assigns do
    @moduledoc """
    Assign helpers that work in both halves of a Dstar page module.

    `use Dstar.Page` imports these instead of `Phoenix.Component`'s assign
    family, so one set of names works everywhere:

    - On a `%Plug.Conn{}` (in `mount/2`, `handle_event/3`, `handle_connect/2`,
      `handle_info/2`) they behave like `Plug.Conn.assign/3`.
    - On anything else (sockets, assigns maps inside function components)
      they delegate to `Phoenix.Component`.
    """

    @doc """
    Assigns one key/value or many key/values.

        conn |> assign(:count, 1)
        conn |> assign(count: 1, name: "rico")
    """
    def assign(%Plug.Conn{} = conn, key_values) when is_list(key_values) or is_map(key_values) do
      Enum.reduce(key_values, conn, fn {key, value}, acc -> Plug.Conn.assign(acc, key, value) end)
    end

    def assign(socket_or_assigns, key_values) do
      Phoenix.Component.assign(socket_or_assigns, key_values)
    end

    def assign(%Plug.Conn{} = conn, key, value) when is_atom(key) do
      Plug.Conn.assign(conn, key, value)
    end

    def assign(socket_or_assigns, key, value) do
      Phoenix.Component.assign(socket_or_assigns, key, value)
    end

    @doc """
    Assigns a value computed by `fun` only when `key` is absent.
    `fun` may take zero arguments or the current assigns.
    """
    def assign_new(%Plug.Conn{} = conn, key, fun) when is_atom(key) and is_function(fun) do
      if Map.has_key?(conn.assigns, key) do
        conn
      else
        value =
          case fun do
            fun when is_function(fun, 0) -> fun.()
            fun when is_function(fun, 1) -> fun.(conn.assigns)
          end

        Plug.Conn.assign(conn, key, value)
      end
    end

    def assign_new(socket_or_assigns, key, fun) do
      Phoenix.Component.assign_new(socket_or_assigns, key, fun)
    end

    @doc """
    Updates an existing assign with `fun`. Raises `KeyError` if absent.
    """
    def update(%Plug.Conn{} = conn, key, fun) when is_atom(key) and is_function(fun, 1) do
      Plug.Conn.assign(conn, key, fun.(Map.fetch!(conn.assigns, key)))
    end

    def update(socket_or_assigns, key, fun) do
      Phoenix.Component.update(socket_or_assigns, key, fun)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page/assigns_test.exs`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/page/assigns.ex test/dstar/page/assigns_test.exs
git commit -m "feat: add Dstar.Page.Assigns conn/component assign shim"
```

---

### Task 3: `Dstar.Page.Helpers` — `event`, `connect`, `patch`

**Files:**
- Create: `lib/dstar/page/helpers.ex`
- Test: `test/dstar/page/helpers_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/page/helpers_test.exs`:

```elixir
defmodule Dstar.Page.HelpersTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Page.Helpers

  describe "event/1,2" do
    test "builds a page-local @post expression" do
      assert event("increment") == "@post(location.pathname + '/_event/increment')"
    end

    test "supports event names with interpolated ids" do
      assert event("toggle_item:123") ==
               "@post(location.pathname + '/_event/toggle_item:123')"
    end

    test "supports verb override" do
      assert event("remove", verb: :delete) ==
               "@delete(location.pathname + '/_event/remove')"
    end

    test "raises on unknown verb" do
      assert_raise ArgumentError, fn -> event("x", verb: :head) end
    end

    test "appends raw options object" do
      assert event("save", opts: "{retryMaxCount: 5}") ==
               "@post(location.pathname + '/_event/save', {retryMaxCount: 5})"
    end
  end

  describe "connect/0,1" do
    test "builds the stream connect expression" do
      assert connect() == "@post(location.pathname, {retryMaxCount: Infinity})"
    end

    test "allows overriding the options object" do
      assert connect(opts: "{retryMaxCount: 3}") ==
               "@post(location.pathname, {retryMaxCount: 3})"
    end
  end

  describe "patch/3,4" do
    defp history(assigns) do
      # A function component without ~H: returns safe HTML directly.
      {:safe, ~s(<span id="history">Last: #{assigns.value}</span>)}
    end

    test "renders a component fun into a patch-elements event" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, value: 3)

      assert conn.resp_body =~ "event: datastar-patch-elements"
      assert conn.resp_body =~ ~s(<span id="history">Last: 3</span>)
    end

    test "passes opts through to Dstar.Elements.patch" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, [value: 1], selector: "#slot", mode: :inner)

      assert conn.resp_body =~ "data: selector #slot"
      assert conn.resp_body =~ "data: mode inner"
    end

    test "accepts a map of assigns" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, %{value: 9})

      assert conn.resp_body =~ "Last: 9"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page/helpers_test.exs`
Expected: FAIL — `module Dstar.Page.Helpers is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/page/helpers.ex`:

```elixir
defmodule Dstar.Page.Helpers do
  @moduledoc """
  Template and handler helpers imported by `use Dstar.Page`.

  - `event/1,2` — Datastar action expression targeting the page's own
    `_event` route, resolved client-side via `location.pathname`.
  - `connect/0,1` — Datastar action expression opening the page's SSE stream.
  - `patch/3,4` — render a function component into a `patch_elements` call.
  """

  @verbs ~w(get post put patch delete)a

  @doc """
  Builds a page-local Datastar action expression.

      event("increment")
      #=> "@post(location.pathname + '/_event/increment')"

      event("remove", verb: :delete)
      #=> "@delete(location.pathname + '/_event/remove')"

  The URL is computed in the browser, so path params (workspace slugs,
  ids) need no server-side threading. Event names become a single URL
  path segment: they must not contain `/` or `'`.

  ## Options

  - `:verb` — `:get | :post | :put | :patch | :delete` (default `:post`)
  - `:opts` — raw JS object string appended as the action's options,
    e.g. `"{retryMaxCount: 5}"`
  """
  def event(name, opts \\ []) when is_binary(name) and is_list(opts) do
    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    args = "location.pathname + '/_event/#{name}'"

    args =
      case Keyword.get(opts, :opts) do
        nil -> args
        extra when is_binary(extra) -> args <> ", " <> extra
      end

    "@#{verb}(#{args})"
  end

  @doc """
  Builds the stream-connect expression for `data-init` /
  `data-on:online__window`.

      connect()
      #=> "@post(location.pathname, {retryMaxCount: Infinity})"

  ## Options

  - `:opts` — override the options object (default `"{retryMaxCount: Infinity}"`)
  """
  def connect(opts \\ []) when is_list(opts) do
    extra = Keyword.get(opts, :opts, "{retryMaxCount: Infinity}")
    "@post(location.pathname, #{extra})"
  end

  @doc """
  Renders a function component and pipes it to `Dstar.Elements.patch/3`.

      conn |> patch(&history/1, value: count)
      conn |> patch(&item_card/1, [item: item], selector: "#row-1", mode: :outer)

  With no `:selector`, Datastar matches elements by their `id` attribute,
  so the component's root element must carry one.
  """
  def patch(conn, component, assigns, opts \\ [])
      when is_function(component, 1) and (is_list(assigns) or is_map(assigns)) do
    html = component.(Map.new(assigns))
    Dstar.Elements.patch(conn, html, opts)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page/helpers_test.exs`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/page/helpers.ex test/dstar/page/helpers_test.exs
git commit -m "feat: add Dstar.Page.Helpers (event, connect, patch)"
```

---

### Task 4: `Dstar.Page` — behaviour and `use` macro

**Files:**
- Create: `lib/dstar/page.ex`
- Test: `test/dstar/page_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/page_test.exs`:

```elixir
defmodule Dstar.PageTest do
  use ExUnit.Case, async: true

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, _params) do
      assign(conn, count: 0)
    end

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>
        <button data-on:click={event("increment")}>+1</button>
      </div>
      """
    end

    def handle_event(conn, "increment", signals) do
      count = (signals["count"] || 0) + 1

      conn
      |> patch_signals(%{count: count})
      |> patch(&history/1, value: count)
    end

    defp history(assigns) do
      ~H"""
      <span id="history">Last: {@value}</span>
      """
    end
  end

  defmodule TunedPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H"<div id=\"t\">tuned</div>"
  end

  defp render_to_string(rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  test "render/1 produces HEEx with the page-local event helper" do
    html = render_to_string(CounterPage.render(%{count: 0}))
    assert html =~ "data-signals:count"
    assert html =~ "@post(location.pathname + &#39;/_event/increment&#39;)"
  end

  test "the assign shim works on conns inside mount" do
    conn = Plug.Test.conn(:get, "/") |> CounterPage.mount(%{})
    assert conn.assigns.count == 0
  end

  test "handle_event pipes conn helpers and patch" do
    conn =
      Plug.Test.conn(:post, "/")
      |> Dstar.SSE.start()
      |> CounterPage.handle_event("increment", %{"count" => 2})

    assert conn.resp_body =~ ~s(signals {"count":3})
    assert conn.resp_body =~ "Last: 3"
  end

  test "__dstar__(:idle_check) defaults to 30_000" do
    assert CounterPage.__dstar__(:idle_check) == 30_000
  end

  test "__dstar__(:idle_check) is overridable via use options" do
    assert TunedPage.__dstar__(:idle_check) == 50
  end
end
```

Note: HEEx HTML-escapes attribute values, so the rendered `event(...)`
expression appears with `&#39;` for `'`. Datastar reads the attribute via
the DOM, which un-escapes — this is correct behavior, not a bug.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page_test.exs`
Expected: FAIL — `module Dstar.Page is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/page.ex`:

```elixir
defmodule Dstar.Page do
  @moduledoc """
  One module per page: render, event handlers, stream callbacks, and
  colocated function components.

      defmodule MyAppWeb.CounterPage do
        use Dstar.Page

        def mount(conn, _params), do: assign(conn, count: 0)

        def render(assigns) do
          ~H\"\"\"
          <div data-signals:count={@count}>
            <button data-on:click={event("increment")}>+1</button>
          </div>
          \"\"\"
        end

        def handle_event(conn, "increment", signals) do
          patch_signals(conn, %{count: (signals["count"] || 0) + 1})
        end
      end

  Route it with `Dstar.Router.dstar/2`:

      import Dstar.Router
      dstar "/counter", MyAppWeb.CounterPage

  All requests are driven by `Dstar.Page.Plug` — pages contain no
  control flow, only callbacks. Conn in, conn out.

  ## Options

  - `:idle_check` — ms between connection liveness checks in the stream
    loop (default `30_000`).
  """

  @doc "GET: load data and assign what `render/1` needs. Optional."
  @callback mount(Plug.Conn.t(), params :: map()) :: Plug.Conn.t()

  @doc "The full-page HEEx template. Required."
  @callback render(assigns :: map()) :: term()

  @doc "Handles a Datastar event POST. SSE is already started. Optional."
  @callback handle_event(Plug.Conn.t(), event :: String.t(), signals :: map()) :: Plug.Conn.t()

  @doc """
  Stream open: subscribe to topics, assign loop state. Optional —
  defining it enables `POST /path` streaming.
  """
  @callback handle_connect(Plug.Conn.t(), params :: map()) :: Plug.Conn.t()

  @doc "Handles one message from the library-owned receive loop. Optional."
  @callback handle_info(msg :: term(), Plug.Conn.t()) :: Plug.Conn.t() | {:halt, Plug.Conn.t()}

  @doc "If defined, the stream opens via `Dstar.start_stream/2` keyed on the result. Optional."
  @callback stream_key(Plug.Conn.t()) :: term()

  @optional_callbacks mount: 2, handle_event: 3, handle_connect: 2, handle_info: 2, stream_key: 1

  @default_idle_check 30_000

  defmacro __using__(opts) do
    idle_check = Keyword.get(opts, :idle_check, @default_idle_check)

    quote do
      @behaviour Dstar.Page

      use Phoenix.Component

      # Re-importing overrides the import set from `use Phoenix.Component`,
      # freeing the assign family for the conn/component shim below.
      import Phoenix.Component,
        except: [assign: 2, assign: 3, assign_new: 3, update: 3]

      import Dstar.Page.Assigns

      # Explicit list: `Dstar` also exports URL builders (post/2,3,
      # patch/1,2,3, event/2,3) that collide with the page helpers.
      import Dstar,
        only: [
          start: 1,
          start_stream: 2,
          check_connection: 1,
          read_signals: 1,
          patch_signals: 2,
          patch_signals: 3,
          remove_signals: 2,
          remove_signals: 3,
          patch_elements: 3,
          remove_elements: 2,
          remove_elements: 3,
          execute_script: 2,
          execute_script: 3,
          redirect: 2,
          redirect: 3,
          console_log: 2,
          console_log: 3
        ]

      import Dstar.Page.Helpers

      @doc false
      def __dstar__(:idle_check), do: unquote(idle_check)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page_test.exs`
Expected: PASS (5 tests). If the escaped-quote assertion fails, print the
actual html with `IO.puts(html)` and match the actual escaping — the
assertion's intent is "the event expression made it into the attribute."

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS — confirms no import regressions elsewhere.

- [ ] **Step 6: Commit**

```bash
git add lib/dstar/page.ex test/dstar/page_test.exs
git commit -m "feat: add Dstar.Page behaviour and use macro"
```

---

### Task 5: `Dstar.Test` — SSE assertions

Built before the plug so plug tests can use it.

**Files:**
- Create: `lib/dstar/test.ex`
- Test: `test/dstar/test_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/test_test.exs`:

```elixir
defmodule Dstar.TestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Test

  defp sse_conn do
    conn(:post, "/") |> Dstar.SSE.start()
  end

  describe "sse_events/1" do
    test "parses events out of a test conn body" do
      conn =
        sse_conn()
        |> Dstar.patch_signals(%{count: 1})
        |> Dstar.patch_elements(~s(<span id="x">hi</span>), [])

      assert [
               %{type: "datastar-patch-signals", data: [~s(signals {"count":1})]},
               %{type: "datastar-patch-elements", data: [~s(elements <span id="x">hi</span>)]}
             ] = sse_events(conn)
    end

    test "ignores comment-only keepalive chunks" do
      {:ok, conn} = Dstar.check_connection(sse_conn())
      assert sse_events(conn) == []
    end
  end

  describe "assert_patched_signals/2" do
    test "passes on a subset match across events" do
      conn =
        sse_conn()
        |> Dstar.patch_signals(%{count: 1})
        |> Dstar.patch_signals(%{name: "rico"})

      assert_patched_signals(conn, %{count: 1})
      assert_patched_signals(conn, %{count: 1, name: "rico"})
    end

    test "fails on a wrong value" do
      conn = sse_conn() |> Dstar.patch_signals(%{count: 1})

      assert_raise ExUnit.AssertionError, fn ->
        assert_patched_signals(conn, %{count: 2})
      end
    end
  end

  describe "assert_patched_element/2" do
    test "matches by explicit selector" do
      conn = sse_conn() |> Dstar.patch_elements("<li>x</li>", selector: "#items", mode: :append)
      assert_patched_element(conn, "#items")
    end

    test "matches by element id when no selector was sent" do
      conn = sse_conn() |> Dstar.patch_elements(~s(<span id="history">x</span>), [])
      assert_patched_element(conn, "#history")
    end

    test "fails when nothing matches" do
      conn = sse_conn() |> Dstar.patch_signals(%{a: 1})

      assert_raise ExUnit.AssertionError, fn ->
        assert_patched_element(conn, "#nope")
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/test_test.exs`
Expected: FAIL — `module Dstar.Test is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/test.ex`:

```elixir
defmodule Dstar.Test do
  @moduledoc """
  Assertions for Dstar SSE responses in `Plug.Test` / `Phoenix.ConnTest`
  tests. Chunked SSE bodies accumulate in `conn.resp_body` on the test
  adapter; these helpers parse them back into events.

      conn = post(conn, "/counter/_event/increment")
      assert_patched_signals(conn, %{count: 1})
      assert_patched_element(conn, "#history")
  """

  import ExUnit.Assertions

  @doc """
  Parses the SSE events from a conn (or raw body string) into a list of
  `%{type: String.t() | nil, data: [String.t()]}`.
  """
  def sse_events(%Plug.Conn{} = conn), do: sse_events(conn.resp_body || "")

  def sse_events(body) when is_binary(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_event/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_event(block) do
    lines = String.split(block, "\n", trim: true)

    type =
      Enum.find_value(lines, fn
        "event: " <> type -> type
        _ -> nil
      end)

    data = for "data: " <> data <- lines, do: data

    if type != nil or data != [], do: %{type: type, data: data}
  end

  @doc """
  Returns the merged map of all signals patched on the conn.
  """
  def patched_signals(conn) do
    conn
    |> sse_events()
    |> Enum.filter(&(&1.type == "datastar-patch-signals"))
    |> Enum.flat_map(& &1.data)
    |> Enum.reduce(%{}, fn
      "signals " <> json, acc -> Map.merge(acc, Jason.decode!(json))
      _line, acc -> acc
    end)
  end

  @doc """
  Asserts the given signals (a subset) were patched. Keys may be atoms
  or strings; values compare against the JSON-decoded patch.
  Returns the conn for piping.
  """
  def assert_patched_signals(conn, expected) when is_map(expected) do
    actual = patched_signals(conn)

    for {key, value} <- expected do
      key = to_string(key)

      assert Map.get(actual, key) == value,
             "expected signal #{inspect(key)} to be patched to #{inspect(value)}, " <>
               "got #{inspect(Map.get(actual, key))}. All patched signals: #{inspect(actual)}"
    end

    conn
  end

  @doc """
  Asserts a `datastar-patch-elements` event targets `target` — either via
  an explicit `selector` line or via an `id` attribute in the patched HTML
  (pass the target as `"#the-id"` in both cases).
  Returns the conn for piping.
  """
  def assert_patched_element(conn, "#" <> _ = target) do
    events =
      conn
      |> sse_events()
      |> Enum.filter(&(&1.type == "datastar-patch-elements"))

    id = String.trim_leading(target, "#")

    found =
      Enum.any?(events, fn %{data: data} ->
        Enum.any?(data, fn
          "selector " <> selector -> selector == target
          "elements " <> html -> String.contains?(html, ~s(id="#{id}"))
          _other -> false
        end)
      end)

    assert found,
           "no datastar-patch-elements event targeting #{inspect(target)}. " <>
             "Element events: #{inspect(events)}"

    conn
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/test_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/test.ex test/dstar/test_test.exs
git commit -m "feat: add Dstar.Test SSE assertions"
```

---

### Task 6: `Dstar.Page.Plug` — the `page` (GET) action

**Files:**
- Create: `lib/dstar/page/plug.ex`
- Test: `test/dstar/page/plug_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/page/plug_test.exs`:

```elixir
defmodule Dstar.Page.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  alias Dstar.Page.Plug, as: PagePlug

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, params) do
      assign(conn, count: String.to_integer(params["start"] || "0"))
    end

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>
        <button data-on:click={event("increment")}>+1</button>
      </div>
      """
    end

    def handle_event(conn, "increment", signals) do
      count = (signals["count"] || 0) + 1

      conn
      |> patch_signals(%{count: count})
      |> patch(&history/1, value: count)
    end

    defp history(assigns) do
      ~H"""
      <span id="history">Last: {@value}</span>
      """
    end
  end

  defmodule RedirectPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> Plug.Conn.put_resp_header("location", "/login")
      |> Plug.Conn.send_resp(302, "")
    end

    def render(assigns), do: ~H"<div id=\"never\">never rendered</div>"
  end

  defmodule BarePage do
    use Dstar.Page

    def render(assigns), do: ~H"<div id=\"bare\">bare</div>"
  end

  describe "page action (GET)" do
    test "mounts and renders HTML 200" do
      conn = conn(:get, "/counter?start=5")
      conn = PagePlug.call(conn, PagePlug.init({:page, CounterPage}))

      assert conn.status == 200
      assert conn.state == :sent
      assert {"content-type", "text/html" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert conn.resp_body =~ "data-signals:count=\"5\""
    end

    test "works without a mount callback" do
      conn = PagePlug.call(conn(:get, "/bare"), PagePlug.init({:page, BarePage}))
      assert conn.status == 200
      assert conn.resp_body =~ "bare"
    end

    test "skips render when mount already sent a response" do
      conn = PagePlug.call(conn(:get, "/r"), PagePlug.init({:page, RedirectPage}))
      assert conn.status == 302
      refute conn.resp_body =~ "never rendered"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: FAIL — `module Dstar.Page.Plug is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/page/plug.ex`:

```elixir
if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Dstar.Page.Plug do
    @moduledoc """
    The plug behind `Dstar.Router.dstar/2`. Drives `Dstar.Page` callbacks:

    - `{:page, Module}` — GET: `mount/2` then `render/1` through Phoenix's
      view pipeline (root layout, flash, `page_title` all apply).
    - `{:event, Module}` — POST `_event/:event`: reads signals, starts SSE,
      calls `handle_event/3`.
    - `{:stream, Module}` — POST: starts SSE (deduped when `stream_key/1`
      is defined), calls `handle_connect/2`, then owns the receive loop
      dispatching to `handle_info/2`.

    All control flow lives here as plain functions — pages contain only
    callbacks.
    """

    @behaviour Plug

    require Logger
    import Plug.Conn

    @impl Plug
    def init({action, page}) when action in [:page, :event, :stream] and is_atom(page) do
      {action, page}
    end

    @impl Plug
    def call(conn, {:page, page}), do: page(conn, page)
    def call(conn, {:event, page}), do: event(conn, page)
    def call(conn, {:stream, page}), do: stream(conn, page)

    # ── GET: mount + render ─────────────────────────────────────────────

    defp page(conn, page) do
      conn = conn |> fetch_query_params() |> ensure_html_format()

      conn =
        if function_exported?(page, :mount, 2) do
          page.mount(conn, conn.params)
        else
          conn
        end

      if conn.halted or conn.state != :unset do
        conn
      else
        conn
        |> Phoenix.Controller.put_view(html: page)
        |> Phoenix.Controller.render(:render)
      end
    end

    defp ensure_html_format(conn) do
      if Phoenix.Controller.get_format(conn) do
        conn
      else
        Phoenix.Controller.put_format(conn, "html")
      end
    end
  end
end
```

(The `event` and `stream` actions raise `FunctionClauseError` on `call/2`
until Tasks 7 and 8 — the `call` heads exist but `event/2` and `stream/2`
private functions don't yet. To keep this task compiling, add temporary
stubs and replace them in the next tasks:)

```elixir
    # ── POST _event/:event — implemented in Task 7 ──────────────────────
    defp event(conn, _page), do: send_resp(conn, 501, "not implemented")

    # ── POST stream — implemented in Task 8 ─────────────────────────────
    defp stream(conn, _page), do: send_resp(conn, 501, "not implemented")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: PASS (3 tests).

Known risk: `Phoenix.Controller.render/2` on a bare test conn. If it
raises about a missing format or view, the failure message names the
missing plumbing — fix inside `page/2` (e.g., the `ensure_html_format`
order), not in tests. The view/format pair set here is the documented
public API (`put_view(html: Module)` + template atom → `Module.render(assigns)`).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/page/plug.ex test/dstar/page/plug_test.exs
git commit -m "feat: add Dstar.Page.Plug with GET page rendering"
```

---

### Task 7: `Dstar.Page.Plug` — the `event` action

**Files:**
- Modify: `lib/dstar/page/plug.ex`
- Test: `test/dstar/page/plug_test.exs` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/dstar/page/plug_test.exs` (inside the outer module, after the `describe "page action (GET)"` block):

```elixir
  describe "event action (POST _event/:event)" do
    defp event_conn(event, signals) do
      conn(:post, "/counter/_event/#{event}")
      |> Map.put(:path_params, %{"event" => event})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, signals)
    end

    test "starts SSE and dispatches to handle_event with signals" do
      conn = event_conn("increment", %{"count" => 2})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))

      assert conn.state == :chunked
      assert conn.status == 200
      assert_patched_signals(conn, %{count: 3})
      assert_patched_element(conn, "#history")
    end

    test "handlers never call Dstar.start themselves" do
      # CounterPage.handle_event has no Dstar.start — reaching :chunked
      # proves the plug started SSE.
      conn = event_conn("increment", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      assert conn.state == :chunked
    end

    test "with debug_errors, a crash is relayed to the browser console and re-raised" do
      Application.put_env(:dstar, :debug_errors, true)
      on_exit(fn -> Application.delete_env(:dstar, :debug_errors) end)

      conn = event_conn("explode", %{})

      assert_raise FunctionClauseError, fn ->
        PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      end
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: the new tests FAIL (501 from the stub → state/status assertions fail).

- [ ] **Step 3: Implement**

In `lib/dstar/page/plug.ex`, replace the `event/2` stub with:

```elixir
    # ── POST _event/:event: read signals, start SSE, handle_event ───────

    defp event(conn, page) do
      conn = fetch_query_params(conn)
      event = conn.path_params["event"]
      signals = Dstar.Signals.read(conn)
      conn = Dstar.SSE.start(conn)

      if Application.get_env(:dstar, :debug_errors, false) do
        try do
          page.handle_event(conn, event, signals)
        rescue
          exception ->
            stacktrace = __STACKTRACE__

            Dstar.console_log(
              conn,
              Exception.format(:error, exception, stacktrace),
              level: :error
            )

            reraise exception, stacktrace
        end
      else
        page.handle_event(conn, event, signals)
      end
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/page/plug.ex test/dstar/page/plug_test.exs
git commit -m "feat: dispatch Datastar events through Dstar.Page.Plug"
```

---

### Task 8: `Dstar.Page.Plug` — the `stream` action and receive loop

**Files:**
- Modify: `lib/dstar/page/plug.ex`
- Test: `test/dstar/page/plug_test.exs` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/dstar/page/plug_test.exs` a stream page fixture (top of module, next to the other fixtures):

```elixir
  defmodule StreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H"<div id=\"s\">stream</div>"

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:connected, self()})
      conn
    end

    def handle_info({:tick, n}, conn), do: patch_signals(conn, %{tick: n})
    def handle_info(:halt_now, conn), do: {:halt, conn}
  end
```

And the describe block (after the event tests):

```elixir
  describe "stream action (POST)" do
    test "404s when the page has no handle_connect" do
      conn = PagePlug.call(conn(:post, "/bare"), PagePlug.init({:stream, BarePage}))
      assert conn.status == 404
    end

    test "connects, dispatches handle_info, tolerates strays, halts on demand" do
      Process.register(self(), :dstar_plug_stream_test)
      on_exit(fn -> Process.unregister(:dstar_plug_stream_test) end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/stream"), PagePlug.init({:stream, StreamPage}))
        end)

      assert_receive {:connected, stream_pid}, 1_000

      send(stream_pid, {:tick, 7})
      send(stream_pid, :unmatched_stray_message)
      send(stream_pid, {:tick, 8})
      send(stream_pid, :halt_now)

      conn = Task.await(task, 2_000)

      assert conn.state == :chunked
      assert_patched_signals(conn, %{tick: 8})
      # The stray message did not kill the loop: tick 8 arrived after it.
    end
  end
```

Note: `Process.unregister/1` raises if the process already died; in this
test the test process stays alive, so the `on_exit` is safe. Tests within
one module run sequentially, so the registered name does not collide.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: new tests FAIL (501 stub).

- [ ] **Step 3: Implement**

In `lib/dstar/page/plug.ex`, replace the `stream/2` stub with:

```elixir
    # ── POST stream: connect, then library-owned receive loop ───────────

    defp stream(conn, page) do
      if function_exported?(page, :handle_connect, 2) do
        conn = fetch_query_params(conn)

        conn =
          if function_exported?(page, :stream_key, 1) do
            Dstar.start_stream(conn, page.stream_key(conn))
          else
            Dstar.SSE.start(conn)
          end

        conn = page.handle_connect(conn, conn.params)
        loop(conn, page, page.__dstar__(:idle_check))
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
      end
    end

    defp loop(conn, page, idle_check) do
      receive do
        msg ->
          case dispatch_info(page, msg, conn) do
            {:halt, conn} -> conn
            conn -> loop(conn, page, idle_check)
          end
      after
        idle_check ->
          case Dstar.check_connection(conn) do
            {:ok, conn} -> loop(conn, page, idle_check)
            {:error, conn} -> conn
          end
      end
    end

    # A message matching no handle_info/2 clause must not kill the stream.
    # Only a FunctionClauseError raised by the head of the page's own
    # handle_info/2 is absorbed; errors inside a matched clause propagate.
    defp dispatch_info(page, msg, conn) do
      page.handle_info(msg, conn)
    rescue
      exception in FunctionClauseError ->
        if exception.module == page and exception.function == :handle_info and
             exception.arity == 2 do
          Logger.warning(
            "#{inspect(page)} received unhandled message: #{inspect(msg)}"
          )

          conn
        else
          reraise exception, __STACKTRACE__
        end
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/page/plug_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/dstar/page/plug.ex test/dstar/page/plug_test.exs
git commit -m "feat: library-owned SSE stream loop in Dstar.Page.Plug"
```

---

### Task 9: `Dstar.Component`

**Files:**
- Create: `lib/dstar/component.ex`
- Test: `test/dstar/component_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/component_test.exs`:

```elixir
defmodule Dstar.ComponentTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  defmodule DetailDrawer do
    use Dstar.Component

    def drawer(assigns) do
      ~H"""
      <div id="item-detail-drawer">
        <input data-on:change={event("change_title:#{@item.id}")} value={@item.title} />
      </div>
      """
    end

    def handle_event(conn, "change_title:" <> _id, signals) do
      conn
      |> start()
      |> patch_signals(%{saved: true, title: signals["title"]})
    end
  end

  test "event/2 targets the component's dispatch URL with the dsPrefix dataset" do
    html =
      DetailDrawer.drawer(%{item: %{id: "abc", title: "T"}})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    encoded = Dstar.Actions.encode_module(DetailDrawer)
    assert html =~ "document.body.dataset.dsPrefix"
    assert html =~ "/ds/#{encoded}/change_title:abc"
  end

  test "event/2 supports verb override" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)

    assert DetailDrawer.event("remove", verb: :delete) ==
             "@delete((document.body.dataset.dsPrefix || '') + '/ds/#{encoded}/remove')"
  end

  test "handle_event works through Dstar.Plugs.Dispatch" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)
    opts = Dstar.Plugs.Dispatch.init(modules: [DetailDrawer])

    conn =
      conn(:post, "/ds/#{encoded}/change_title:abc")
      |> Map.put(:path_params, %{"module" => encoded, "event" => "change_title:abc"})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"title" => "New"})

    conn = Dstar.Plugs.Dispatch.call(conn, opts)
    assert conn.state == :chunked
    assert_patched_signals(conn, %{saved: true, title: "New"})
  end
end
```

Design note on the fixture's explicit `start()`: component handlers run
under `Dstar.Plugs.Dispatch`, whose semantics stay unchanged for all
existing users (the spec keeps Dispatch as-is), so Dispatch does not
auto-start SSE. Pages get auto-start from `Dstar.Page.Plug`; component
handlers keep the one-line `start(conn)` (`start/1` is imported by
`use Dstar.Component`). The spec's "no `Dstar.start()` in handlers"
promise applies to page handlers.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/component_test.exs`
Expected: FAIL — `module Dstar.Component is not available`.

- [ ] **Step 3: Implement**

Create `lib/dstar/component.ex`:

```elixir
defmodule Dstar.Component do
  @moduledoc """
  Shared UI + its event handlers in one module — for drawers, pickers,
  and other components used across many pages.

      defmodule MyAppWeb.DetailDrawer do
        use Dstar.Component

        def drawer(assigns) do
          ~H\"\"\"
          <div id="detail-drawer">
            <input data-on:change={event("change_title:#{@item.id}")} />
          </div>
          \"\"\"
        end

        def handle_event(conn, "change_title:" <> id, signals) do
          # ... update, then patch
          conn |> start() |> patch_signals(%{saved: true})
        end
      end

  Pages embed the UI as plain function components and need no
  `handle_event` clauses for it — events route to this module via
  `Dstar.Plugs.Dispatch` (wire it with `Dstar.Router.dstar_components/2`).

  Unlike `Dstar.Page`, `event/2` here targets the component's dispatch
  URL. When your app mounts the dispatch route under a path prefix,
  declare it once in the root layout:

      <body data-ds-prefix={workspace_path(@current_scope.workspace.slug)}>

  Colocation only: no server-side component state, no lifecycle. State
  lives in signals, the DOM, and the database.
  """

  @verbs ~w(get post put patch delete)a

  defmacro __using__(_opts) do
    quote do
      use Phoenix.Component

      import Phoenix.Component,
        except: [assign: 2, assign: 3, assign_new: 3, update: 3]

      import Dstar.Page.Assigns

      import Dstar,
        only: [
          start: 1,
          start_stream: 2,
          check_connection: 1,
          read_signals: 1,
          patch_signals: 2,
          patch_signals: 3,
          remove_signals: 2,
          remove_signals: 3,
          patch_elements: 3,
          remove_elements: 2,
          remove_elements: 3,
          execute_script: 2,
          execute_script: 3,
          redirect: 2,
          redirect: 3,
          console_log: 2,
          console_log: 3
        ]

      import Dstar.Page.Helpers, only: [patch: 3, patch: 4]

      @doc """
      Builds a Datastar action expression targeting this component's
      dispatch URL, prefixed client-side by `document.body.dataset.dsPrefix`.
      """
      def event(name, opts \\ []) when is_binary(name) do
        Dstar.Component.build_event(__MODULE__, name, opts)
      end
    end
  end

  @doc false
  def build_event(module, name, opts) when is_atom(module) and is_binary(name) do
    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    encoded = Dstar.Actions.encode_module(module)
    args = "(document.body.dataset.dsPrefix || '') + '/ds/#{encoded}/#{name}'"

    args =
      case Keyword.get(opts, :opts) do
        nil -> args
        extra when is_binary(extra) -> args <> ", " <> extra
      end

    "@#{verb}(#{args})"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/component_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dstar/component.ex test/dstar/component_test.exs
git commit -m "feat: add Dstar.Component for shared UI with colocated events"
```

---

### Task 10: `Dstar.Router` — `dstar/2` and `dstar_components/2`

**Files:**
- Create: `lib/dstar/router.ex`
- Test: `test/dstar/router_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/dstar/router_test.exs`:

```elixir
defmodule Dstar.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, _params), do: assign(conn, count: 0)

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>counter</div>
      """
    end

    def handle_event(conn, "increment", signals) do
      patch_signals(conn, %{count: (signals["count"] || 0) + 1})
    end
  end

  defmodule Drawer do
    use Dstar.Component

    def handle_event(conn, "ping", _signals) do
      conn |> start() |> patch_signals(%{pong: true})
    end
  end

  defmodule TestRouter do
    use Phoenix.Router
    import Dstar.Router

    dstar "/counter", Dstar.RouterTest.CounterPage
    dstar_components "/ds", [Dstar.RouterTest.Drawer]
  end

  defp call(conn), do: TestRouter.call(conn, TestRouter.init([]))

  test "GET page route renders the page" do
    conn = call(conn(:get, "/counter"))
    assert conn.status == 200
    assert conn.resp_body =~ "counter"
  end

  test "POST event route dispatches handle_event" do
    conn =
      conn(:post, "/counter/_event/increment")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"count" => 1})
      |> call()

    assert conn.state == :chunked
    assert_patched_signals(conn, %{count: 2})
  end

  test "POST stream route 404s when page has no handle_connect" do
    conn = call(conn(:post, "/counter"))
    assert conn.status == 404
  end

  test "dstar_components wires the Dispatch plug" do
    encoded = Dstar.Actions.encode_module(Drawer)

    conn =
      conn(:post, "/ds/#{encoded}/ping")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{})
      |> call()

    assert conn.state == :chunked
    assert_patched_signals(conn, %{pong: true})
  end

  test "__event_path__ handles trailing slashes" do
    assert Dstar.Router.__event_path__("/counter") == "/counter/_event/:event"
    assert Dstar.Router.__event_path__("/counter/") == "/counter/_event/:event"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/dstar/router_test.exs`
Expected: FAIL — `module Dstar.Router is not available` (compile error in TestRouter).

- [ ] **Step 3: Implement**

Create `lib/dstar/router.ex`:

```elixir
defmodule Dstar.Router do
  @moduledoc """
  Router macros for Dstar pages and components.

      # In your Phoenix router:
      import Dstar.Router

      scope "/", MyAppWeb do
        pipe_through :browser

        dstar "/counter", CounterPage
        dstar_components "/ds", [DetailDrawer, DatePicker]
      end

  `dstar/2` expands to plain Phoenix routes — the route is the allowlist:

      GET   /counter                 -> Dstar.Page.Plug page    (mount + render)
      POST  /counter                 -> Dstar.Page.Plug stream  (handle_connect + loop)
      POST  /counter/_event/:event   -> Dstar.Page.Plug event   (handle_event)

  `_event` is a reserved path segment under page paths.

  `dstar_components/2` expands to one POST route on `Dstar.Plugs.Dispatch`
  with the given module allowlist.
  """

  @doc """
  Wires a `Dstar.Page` module: GET render, POST stream, POST events.
  """
  defmacro dstar(path, page) do
    quote bind_quoted: [path: path, page: page] do
      get(path, Dstar.Page.Plug, {:page, page})
      post(path, Dstar.Page.Plug, {:stream, page})
      post(Dstar.Router.__event_path__(path), Dstar.Page.Plug, {:event, page})
    end
  end

  @doc """
  Wires `Dstar.Component` modules (or any `handle_event/3` handler
  modules) onto a single dispatch route under `base`.
  """
  defmacro dstar_components(base, modules) do
    quote bind_quoted: [base: base, modules: modules] do
      post(Dstar.Router.__dispatch_path__(base), Dstar.Plugs.Dispatch, modules: modules)
    end
  end

  @doc false
  def __event_path__(path), do: String.trim_trailing(path, "/") <> "/_event/:event"

  @doc false
  def __dispatch_path__(base), do: String.trim_trailing(base, "/") <> "/:module/:event"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/dstar/router_test.exs`
Expected: PASS (5 tests).

Known risk: bare `Phoenix.Router` modules in tests work as plugs
(`TestRouter.call/2`), but if route dispatch complains about a missing
`:phoenix_endpoint`, add `Plug.Conn.put_private(conn, :phoenix_endpoint, nil)`
in the test's `call/1` helper — do not change library code for this.

- [ ] **Step 5: Run the full suite, format, and commit**

Run: `mix format && mix test`
Expected: PASS, no formatting diffs beyond your new files.

```bash
git add lib/dstar/router.ex test/dstar/router_test.exs
git commit -m "feat: add Dstar.Router with dstar/2 and dstar_components/2"
```

---

### Task 11: Docs restructure, version 0.1.0

**Files:**
- Modify: `mix.exs`, `README.md`, `CHANGELOG.md`, `usage-rules.md`

- [ ] **Step 1: Bump version and docs groups in `mix.exs`**

Change `@version "0.0.10"` to `@version "0.1.0"`, and replace `groups_for_modules`:

```elixir
      groups_for_modules: [
        Pages: [Dstar.Page, Dstar.Component, Dstar.Router, Dstar.Page.Plug,
                Dstar.Page.Helpers, Dstar.Page.Assigns],
        "Functional core": [Dstar, Dstar.SSE, Dstar.Signals, Dstar.Elements,
                            Dstar.Actions, Dstar.Scripts],
        Plugs: [Dstar.Plugs.Dispatch, Dstar.Plugs.RenameCsrfParam],
        Testing: [Dstar.Test],
        Utilities: [Dstar.Utility.StreamRegistry]
      ]
```

- [ ] **Step 2: Rewrite the README Quick Start**

In `README.md`, immediately after the `## Installation` section, replace the
entire current `## Quick Start` section (the counter built from
CounterController + CounterEvents + template) with:

````markdown
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
declare it once in the root layout: `<body data-ds-prefix={...}>`.
````

- [ ] **Step 3: Reposition the rest of the README**

Still in `README.md`:

1. Change the `## Core API` heading to `## The functional core` and add this intro sentence below it: *"Everything above is built from these functions. Use them directly in plain controllers, custom plugs, or anywhere you have a `%Plug.Conn{}` — pages are optional sugar, the core is the contract."*
2. In the `## Why Dstar?` bullet list, add a first bullet: `- **Pages** — \`use Dstar.Page\` puts render, event handlers, streaming callbacks, and components in one module. One router line wires it.`
3. Update the line "Under the hood, it's ~700 lines of code with no GenServers, no behaviours, and no macros." to: "The functional core is still a small bag of functions with no processes. The page layer on top is one behaviour, one plug, and two router macros — all optional, all readable."
4. In `## Installation`, update the dep snippet to `{:dstar, "~> 0.1.0"}` and add after it: "Pages need `{:phoenix, "~> 1.7"}` and `{:phoenix_live_view, "~> 1.0"}` in your app (any Phoenix app already has them). The functional core needs neither."
5. In the `## Real-time Streaming` section, keep the PubSub explanation but add at the top: *"With `Dstar.Page`, declare subscriptions in `handle_connect/2` and implement `handle_info/2` — the library owns the loop (see Quick Start). The hand-rolled loop below remains fully supported for plain controllers:"*
6. In `## Lower-level Modules`, add rows for the new modules: `Dstar.Page` (behaviour + use macro), `Dstar.Page.Plug` (request driver), `Dstar.Component` (shared UI + events), `Dstar.Router` (`dstar/2`, `dstar_components/2`), `Dstar.Test` (SSE assertions).

- [ ] **Step 4: CHANGELOG entry**

Add at the top of `CHANGELOG.md`:

```markdown
## 0.1.0

The unified page module release. A Datastar page is now one module and
one router line.

### Added

- `Dstar.Page` — `use` it for one-module pages: `mount/2`, `render/1`,
  `handle_event/3`, `handle_connect/2`, `handle_info/2`, `stream_key/1`.
- `Dstar.Page.Plug` — drives all page requests; owns the SSE receive
  loop with idle checks and stray-message tolerance.
- `Dstar.Component` — shared UI with colocated event handlers; `event/2`
  targets the dispatch URL with a client-side `data-ds-prefix` base.
- `Dstar.Router` — `dstar/2` (page routes) and `dstar_components/2`
  (dispatch route) macros.
- `Dstar.Page.Helpers` — `event/1,2`, `connect/0,1`, `patch/3,4`.
- `Dstar.Page.Assigns` — `assign`/`assign_new`/`update` working on both
  conns and component assigns.
- `Dstar.Test` — `sse_events/1`, `patched_signals/1`,
  `assert_patched_signals/2`, `assert_patched_element/2`.
- Optional deps: `phoenix ~> 1.7`, `phoenix_live_view ~> 1.0`. The
  functional core still needs only `plug` + `jason`.

### Changed

- Docs restructured around pages; the original API is now "the
  functional core". Nothing breaks: all 0.0.x code works unchanged.
```

- [ ] **Step 5: Update `usage-rules.md`**

Add a "Pages first" section at the top of `usage-rules.md` stating: prefer
`use Dstar.Page` + `dstar/2` for new pages; use `Dstar.Component` +
`dstar_components/2` for shared UI; reach for the functional core
(`Dstar.*` on a conn) in plain controllers or custom plugs. Include the
Quick Start counter module from Step 2 as the canonical example. (Deeper
skill updates under `usage-rules/skills/` are follow-up work, not this task.)

- [ ] **Step 6: Verify docs build and full suite**

Run: `mix docs && mix test`
Expected: docs build without warnings about missing modules in groups; tests PASS.

- [ ] **Step 7: Commit**

```bash
git add mix.exs README.md CHANGELOG.md usage-rules.md
git commit -m "docs: restructure around Dstar.Page; bump to 0.1.0"
```

---

## Spec coverage checklist (self-review)

- Page contract, all six callbacks → Task 4. URL scheme + route-is-allowlist → Task 10. Plug page/event/stream + loop + stray tolerance + debug_errors → Tasks 6–8. `event`/`connect`/`patch` helpers + `location.pathname` → Task 3. Assign shim → Task 2. `Dstar.Component` + `data-ds-prefix` → Task 9. `Dstar.Test` → Task 5. Optional deps → Task 1. Docs/version → Task 11.
- Spec items intentionally deferred: Defacto migration (separate repo/plan); deep `usage-rules/skills/` rewrites (noted in Task 11 Step 5).
- One deliberate deviation, documented in Task 9: component handlers call `start(conn)` explicitly because `Dstar.Plugs.Dispatch` semantics stay unchanged for existing users. Pages get auto-start via `Dstar.Page.Plug`. The spec's "no `Dstar.start()` in handlers" promise applies to page handlers.
