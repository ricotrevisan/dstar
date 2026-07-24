defmodule Dstar.Utility.StreamRegistry do
  @moduledoc """
  Opt-in per-tab stream deduplication.

  Tracks active SSE stream processes by a compound key (typically
  `{user_id, tab_id}`). When a new stream registers with an existing key,
  the previous stream is ended immediately — no waiting for keepalive
  timeouts.

  "Ended" rather than "killed": the previous holder is signalled with
  `Process.exit(pid, :replaced)`, which a `Dstar.Page` loop handles by
  halting and unregistering (its connection process survives to serve
  other requests). A holder that ignores the signal and still owns the key
  when the grace window closes is killed outright. Either way the handover
  is bounded — it happens inside a request.

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

      <body data-signals:tab-id="sessionStorage.getItem('_ds_tab') || (() => { const id = crypto.randomUUID(); sessionStorage.setItem('_ds_tab', id); return id; })()">

  `sessionStorage` is per-tab — each tab gets its own UUID that
  persists across full-page navigations but is unique per tab.

  > **Important:** write `tab-id`, not `tabId`. HTML lowercases attribute
  > names, so `data-signals:tabId` reaches Datastar as `tabid` and produces
  > a signal called `tabid` — which never matches the `tabId` this module
  > reads, so dedup silently does nothing. Datastar camelizes on hyphens,
  > so the kebab-case form is what yields `tabId`.

  > **Important:** Do not use a `_` prefix for the signal name.
  > Datastar treats `_`-prefixed signals as local (client-only) and
  > never sends them to the server.

  ## Usage

  In your stream controllers, replace `Dstar.start(conn)` with
  `Dstar.start_stream/2` (or call this module directly):

      def stream(conn, _params) do
        scope = conn.assigns.current_scope

        # Ends any previous stream for this user+tab, then starts SSE
        conn = Dstar.start_stream(conn, scope.user.id)

        loop(conn, state)
      end

  If the request carries no usable `tabId`, falls back to `Dstar.start/1`
  without deduplication — so existing streams keep working while you roll
  out the client-side signal. The signal is client-supplied and validated;
  see `tab_id/1`.
  """

  require Logger

  @registry __MODULE__
  @signal_key "tabId"
  @max_tab_id_bytes 64

  # A takeover happens inside a request, so the whole handover is bounded:
  # @grace_ms for the holder to let go, then @kill_ms for the kill to land.
  @poll_ms 10
  @grace_ms 500
  @kill_ms 500
  @register_attempts 5

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Starts an SSE stream with per-tab deduplication.

  Reads `tabId` from the request signals, ends any previous stream
  registered under `{scope_key, tab_id}`, registers the current process,
  and calls `Dstar.start/1`.

  If the request carries no usable `tabId` (see `tab_id/1` — the signal
  is client-supplied and validated), falls back to `Dstar.start/1`
  without deduplication.

  ## Parameters

    - `conn` — the Plug connection
    - `scope_key` — any term that identifies the user/session
      (e.g., `user.id` or `{user.id, workspace.id}`)

  """
  @spec start_stream(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def start_stream(conn, scope_key) do
    if tab_id = tab_id(conn) do
      case replace_and_register({scope_key, tab_id}) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Dstar.Utility.StreamRegistry: could not claim #{inspect({scope_key, tab_id})} " <>
              "(#{inspect(reason)}) — this stream runs without deduplication"
          )
      end
    end

    Dstar.start(conn)
  end

  @doc """
  Returns the request's `tabId` signal if it is usable as a registry key,
  otherwise `nil`.

  A usable id is a binary of 1..#{@max_tab_id_bytes} bytes that is not
  entirely whitespace. `tabId` is client-supplied, so everything else is
  rejected — notably `""`, which would collide every such tab onto one key
  and make them kill each other in a loop.

  The registry key is `{scope_key, tab_id}` using this exact value (no
  normalization), so an app driving a hand-rolled stream loop can rebuild
  the key it needs:

      key = {scope.user.id, Dstar.Utility.StreamRegistry.tab_id(conn)}

  Pages using `Dstar.Page` do not need this — the library unregisters the
  stream for them when the loop ends.
  """
  @spec tab_id(Plug.Conn.t()) :: String.t() | nil
  def tab_id(conn) do
    case Dstar.Signals.read(conn)[@signal_key] do
      tab_id when is_binary(tab_id) ->
        if byte_size(tab_id) in 1..@max_tab_id_bytes and String.trim(tab_id) != "",
          do: tab_id

      _ ->
        nil
    end
  end

  @doc """
  Releases every key this process holds in the registry.

  `Dstar.Page` calls this when the receive loop ends, so pages need no
  bookkeeping. Hand-rolled stream loops should call it on every exit path:
  the entry is otherwise owned by a connection process that, under
  HTTP/1.1 keep-alive, lives on to serve unrelated requests.

  A no-op when the registry is not running (it is opt-in).
  """
  @spec unregister_self() :: :ok
  def unregister_self do
    if Process.whereis(@registry) do
      for key <- Registry.keys(@registry, self()) do
        Registry.unregister(@registry, key)
      end
    end

    :ok
  end

  @doc """
  Replaces any previous process registered under `key` and registers
  the current process.

  Signals the previous holder with `Process.exit(pid, :replaced)` and
  waits for it to let go of the key before registering the caller. This
  avoids a race where `Registry.register/3` fails because the previous
  holder hasn't been cleaned up yet.

  The signal alone is not enough: Bandit connection processes trap exits,
  so `:replaced` arrives as an ordinary `{:EXIT, _, :replaced}` message.
  `Dstar.Page` halts its loop on that message and unregisters, which is
  the graceful path. A holder still clinging to the key when the grace
  window closes is killed outright — but a holder that released the key
  and stayed alive is left alone, since under keep-alive it may already be
  serving an unrelated request.

  Returns `{:error, reason}` if the key could not be claimed. This fails
  *open*: two streams racing for the same key leave one of them running
  without a registry entry, so nothing can take it over later — it ends
  only when its client disconnects or the idle check notices. A caller that
  gets an error must not assume it is deduplicated; `start_stream/2` logs a
  warning and streams anyway.
  """
  @spec replace_and_register(term()) :: :ok | {:error, term()}
  def replace_and_register(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] when pid != self() -> replace(key, pid)
      _ -> :ok
    end

    register(key, @register_attempts)
  end

  defp replace(key, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :replaced)

    case await_release(key, pid, ref, deadline(@grace_ms)) do
      :released ->
        Process.demonitor(ref, [:flush])
        :ok

      :timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          @kill_ms -> Process.demonitor(ref, [:flush])
        end

        :ok
    end
  end

  # Either the holder dies or it releases the key and lives on — the
  # library loop does the latter, so waiting only on :DOWN would stall for
  # the full grace window on every ordinary takeover.
  defp await_release(key, pid, ref, deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :released
    after
      @poll_ms ->
        cond do
          not holds_key?(key, pid) -> :released
          System.monotonic_time(:millisecond) >= deadline -> :timeout
          true -> await_release(key, pid, ref, deadline)
        end
    end
  end

  defp holds_key?(key, pid) do
    match?([{^pid, _}], Registry.lookup(@registry, key))
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # Registry clears a dead holder's entry via its own monitor, asynchronously,
  # so the key can still be taken for a moment after the holder is gone.
  defp register(key, attempts) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, _}} when attempts > 1 ->
        Process.sleep(@poll_ms)
        register(key, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
