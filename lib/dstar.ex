defmodule Dstar do
  @moduledoc """
  Datastar SSE helpers for Elixir/Phoenix.

  A trivially small library: SSE connection management,
  signal patching, DOM element patching. That's it.

  ## Quick Example

      def increment(conn, _params) do
        signals = Dstar.read_signals(conn)
        count = signals["count"] || 0

        conn
        |> Dstar.start()
        |> Dstar.patch_signals(%{count: count + 1})
      end

  ## Modules

  - `Dstar.SSE` — Open SSE connections, send raw events
  - `Dstar.Signals` — Read signals from requests, patch signals on the client
  - `Dstar.Elements` — Patch and remove DOM elements
  - `Dstar.Actions` — Generate `@post(...)` expressions for Datastar attributes
  - `Dstar.Plugs.Dispatch` — Optional dynamic event dispatch plug
  """

  @doc """
  Starts an SSE connection on the given Plug conn.

  Sets content type to `text/event-stream`, disables caching,
  and initiates a chunked response. Returns the conn.

  ## Example

      conn = Dstar.start(conn)

  """
  defdelegate start(conn), to: Dstar.SSE

  @doc """
  Starts an SSE stream with per-tab deduplication.

  Requires `Dstar.Utility.StreamRegistry` in your supervision tree and a
  `tabId` signal in your root layout. A usable `tabId` is claimed atomically
  before SSE starts. Claim failure returns a halted, plain-text 503 conn; it
  never starts an undeduplicated keyed stream. Missing/invalid `tabId` is the
  intentional unkeyed fallback.

  Hand-rolled loops must check `conn.halted` before subscribing/looping and
  call `Dstar.Utility.StreamRegistry.release(conn)` during teardown. See that
  module's docs for setup. Pass `max_bytes: n` as a third argument to bound
  raw/query signal input per call.

  ## Example

      conn = Dstar.start_stream(conn, current_user.id)

  """
  defdelegate start_stream(conn, scope_key), to: Dstar.Utility.StreamRegistry
  defdelegate start_stream(conn, scope_key, opts), to: Dstar.Utility.StreamRegistry

  @doc """
  Checks if an SSE connection is still open.

  Returns `{:ok, conn}` if open, `{:error, conn}` if closed.
  Useful in streaming loops to detect disconnections.

  ## Example

      case Dstar.check_connection(conn) do
        {:ok, conn} -> stream_loop(conn)
        {:error, _} -> :ok
      end

  """
  defdelegate check_connection(conn), to: Dstar.SSE

  @doc """
  Safely fetches Datastar signals and returns the updated Plug conn.

  Use this for plain Plug conns whose body has not already been parsed. It
  accepts JSON objects only and bounds raw/query payloads with `:max_bytes`.

      case Dstar.fetch_signals(conn, max_bytes: 64_000) do
        {:ok, signals, conn} -> handle(conn, signals)
        {:error, reason, conn} -> Dstar.Signals.send_error(conn, reason)
      end
  """
  def fetch_signals(conn, opts \\ []), do: Dstar.Signals.fetch(conn, opts)

  @doc """
  Reads already-fetched Datastar signals as a map.

  `Plug.Parsers`/Phoenix body params and already-fetched GET/DELETE query
  params work here. For an unfetched raw body, use `fetch_signals/2`; this
  convenience function cannot return the adapter-updated conn.
  """
  defdelegate read_signals(conn), to: Dstar.Signals, as: :read

  @doc """
  Patches signals on the client via SSE.

  ## Example

      conn |> Dstar.patch_signals(%{count: 42})

  """
  def patch_signals(conn, signals, opts \\ []) do
    Dstar.Signals.patch(conn, signals, opts)
  end

  @doc """
  Removes signals from the client by setting them to nil.

  Accepts a single path string or list of dot-notated paths.

  ## Examples

      conn |> Dstar.remove_signals("user.profile.theme")
      conn |> Dstar.remove_signals(["user.name", "user.email"])

  """
  def remove_signals(conn, paths, opts \\ []) do
    Dstar.Signals.remove_signals(conn, paths, opts)
  end

  @doc """
  Patches a DOM element on the client via SSE.

  Takes a `:selector`, or — with no selector — targets by the `id` on each
  top-level element of `html`. See `Dstar.Elements.patch/3` for all options.

  ## Example

      conn |> Dstar.patch_elements("<span id=\\"count\\">42</span>", selector: "#count")

  """
  defdelegate patch_elements(conn, html, opts), to: Dstar.Elements, as: :patch

  @doc """
  Removes DOM elements on the client via SSE.

  ## Example

      conn |> Dstar.remove_elements("#old-item")

  """
  def remove_elements(conn, selector, opts \\ []) do
    Dstar.Elements.remove(conn, selector, opts)
  end

  @doc """
  Appends an element as the last child of a container, via SSE.

  ## Example

      conn |> Dstar.append_elements(post_row(%{post: post}), "#posts")

  """
  def append_elements(conn, html, container, opts \\ []) do
    Dstar.Elements.append(conn, html, container, opts)
  end

  @doc """
  Morphs the element whose DOM id matches the root of `html`, via SSE.

  Dropped by the client if this tab has no element with that id — see
  `Dstar.Elements.upsert/3`.

  ## Example

      conn |> Dstar.upsert_elements(post_row(%{post: post}))

  """
  def upsert_elements(conn, html, opts \\ []) do
    Dstar.Elements.upsert(conn, html, opts)
  end

  @doc """
  Signals that a collection changed, so each tab reloads it with its own
  filter/sort/page signals.

  ## Example

      conn |> Dstar.nudge("posts")

  """
  def nudge(conn, key, opts \\ []) do
    Dstar.Signals.nudge(conn, key, opts)
  end

  # ── HTTP verb helpers ─────────────────────────────────────────────────

  @doc """
  Generates a `@post(...)` expression for Datastar attributes.

  ## Examples

      Dstar.post(MyAppWeb.CounterHandler, "increment")
      # => ~s|@post("/ds/my_app_web-counter_handler/increment")|

      expression = Dstar.post("increment")
      # The `$_dstar_module` signal is percent-encoded at runtime.
      String.contains?(expression, "encodeURIComponent")
      # => true

  Event and module values are percent-encoded as one route segment. Exact empty
  and dot segments are rejected. In the module form, `:prefix` must be a local
  absolute application path beginning with one `/`; `:module` on the dynamic
  form is a literal module override, not JavaScript or a signal name.

  """
  defdelegate post(module_or_name, name_or_opts \\ []), to: Dstar.Actions
  defdelegate post(module, event_name, opts), to: Dstar.Actions

  @doc """
  Generates a `@get(...)` expression for Datastar attributes.
  See `Dstar.post/2` for usage — same API, different HTTP verb.
  """
  defdelegate get(module_or_name, name_or_opts \\ []), to: Dstar.Actions
  defdelegate get(module, event_name, opts), to: Dstar.Actions

  @doc """
  Generates a `@put(...)` expression for Datastar attributes.
  See `Dstar.post/2` for usage — same API, different HTTP verb.
  """
  defdelegate put(module_or_name, name_or_opts \\ []), to: Dstar.Actions
  defdelegate put(module, event_name, opts), to: Dstar.Actions

  @doc """
  Generates a `@patch(...)` expression for Datastar attributes.
  See `Dstar.post/2` for usage — same API, different HTTP verb.
  """
  defdelegate patch(module_or_name, name_or_opts \\ []), to: Dstar.Actions
  defdelegate patch(module, event_name, opts), to: Dstar.Actions

  @doc """
  Generates a `@delete(...)` expression for Datastar attributes.
  See `Dstar.post/2` for usage — same API, different HTTP verb.
  """
  defdelegate delete(module_or_name, name_or_opts \\ []), to: Dstar.Actions
  defdelegate delete(module, event_name, opts), to: Dstar.Actions

  @doc deprecated: "Use Dstar.post/2 (or get/put/patch/delete) instead"
  defdelegate event(module_or_name, name_or_opts), to: Dstar.Actions
  defdelegate event(module, event_name, opts), to: Dstar.Actions

  @doc """
  Executes JavaScript on the client by appending a script tag via SSE.

  ## Example

      conn |> Dstar.execute_script("alert('Hello!')")

  """
  def execute_script(conn, script, opts \\ []) do
    Dstar.Scripts.execute(conn, script, opts)
  end

  @doc """
  Redirects the client to the given URL via JavaScript.

  Default destination policy is same-origin and path-absolute
  (`/workspaces`, `?x=1`, `#frag`). Off-origin `http`/`https` requires
  `external: true` or `allow: ["host"]`. See `Dstar.Scripts.redirect/3`.

  ## Example

      conn |> Dstar.redirect("/workspaces")
      conn |> Dstar.redirect("https://ok.example/docs", external: true)

  """
  def redirect(conn, url, opts \\ []) do
    Dstar.Scripts.redirect(conn, url, opts)
  end

  @doc """
  Logs a message to the browser console via SSE.

  ## Example

      conn |> Dstar.console_log("Debug info")

  """
  def console_log(conn, message, opts \\ []) do
    Dstar.Scripts.console_log(conn, message, opts)
  end
end
