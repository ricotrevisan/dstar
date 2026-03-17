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
  Reads Datastar signals from the request.

  For GET requests, reads from query params. For POST/PUT/etc, reads from the JSON body.

  ## Example

      signals = Dstar.read_signals(conn)
      count = signals["count"] || 0

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

  Requires a `:selector` option.

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

  # ── HTTP verb helpers ─────────────────────────────────────────────────

  @doc """
  Generates a `@post(...)` expression for Datastar attributes.

  ## Examples

      Dstar.post(MyAppWeb.CounterHandler, "increment")
      # => "@post('/ds/my_app_web-counter_handler/increment', {headers: ...})"

      Dstar.post("increment")
      # => "@post('/ds/' + $_dstar_module + '/increment', {headers: ...})"

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

  ## Example

      conn |> Dstar.redirect("/workspaces")

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
