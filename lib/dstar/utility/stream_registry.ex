defmodule Dstar.Utility.StreamRegistry do
  @moduledoc """
  Opt-in per-tab stream deduplication.

  Tracks active SSE stream processes by a compound key (typically
  `{user_id, tab_id}`). When a new stream registers with an existing
  key, the previous process is killed immediately — no waiting for
  keepalive timeouts.

  ## Problem

  With full-page navigation, SSE stream processes don't learn the
  client disconnected until they try to write — which only happens
  on the next PubSub broadcast or keepalive tick. This creates zombie
  processes that hold subscriptions, do wasted DB queries, and on
  HTTP/1.1 can exhaust the browser's 6-connection-per-origin limit.

  ## Setup

  Add to your application's supervision tree:

      # lib/my_app/application.ex
      children = [
        Dstar.Utility.StreamRegistry,
        # ...
      ]

  Then add a `tabId` signal to your root layout:

      <body data-signals:tabId="sessionStorage.getItem('_ds_tab') || (() => { const id = crypto.randomUUID(); sessionStorage.setItem('_ds_tab', id); return id; })()">

  `sessionStorage` is per-tab — each tab gets its own UUID that
  persists across full-page navigations but is unique per tab.

  > **Important:** Do not use a `_` prefix for the signal name.
  > Datastar treats `_`-prefixed signals as local (client-only) and
  > never sends them to the server.

  ## Usage

  In your stream controllers, replace `Dstar.start(conn)` with
  `Dstar.start_stream/2` (or call this module directly):

      def stream(conn, _params) do
        scope = conn.assigns.current_scope

        # Kills any previous stream for this user+tab, then starts SSE
        conn = Dstar.start_stream(conn, scope.user.id)

        loop(conn, state)
      end

  If no `tabId` signal is present in the request, falls back to
  `Dstar.start/1` without deduplication — so existing streams
  keep working while you roll out the client-side signal.
  """

  @registry __MODULE__
  @signal_key "tabId"

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Starts an SSE stream with per-tab deduplication.

  Reads `tabId` from the request signals, kills any previous stream
  process registered under `{scope_key, tab_id}`, registers the
  current process, and calls `Dstar.start/1`.

  If no `tabId` signal is present, falls back to `Dstar.start/1`
  without deduplication.

  ## Parameters

    - `conn` — the Plug connection
    - `scope_key` — any term that identifies the user/session
      (e.g., `user.id` or `{user.id, workspace.id}`)

  """
  @spec start_stream(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def start_stream(conn, scope_key) do
    signals = Dstar.Signals.read(conn)
    tab_id = signals[@signal_key]

    if tab_id do
      key = {scope_key, tab_id}
      replace_and_register(key)
    end

    Dstar.start(conn)
  end

  @doc """
  Replaces any previous process registered under `key` and registers
  the current process.

  Kills the previous holder with `Process.exit(pid, :replaced)` and
  waits for the registration to clear before registering the caller.
  This avoids a race where `Registry.register/3` fails because the
  exited process hasn't been cleaned up yet.
  """
  @spec replace_and_register(term()) :: :ok
  def replace_and_register(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] when pid != self() ->
        ref = Process.monitor(pid)
        Process.exit(pid, :replaced)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end

      _ ->
        :ok
    end

    Registry.register(@registry, key, nil)
    :ok
  end
end
