defmodule Dstar.Utility.StreamRegistry do
  @moduledoc """
  Opt-in per-tab stream deduplication with linearizable claims.

  The registry is a single coordinator process. It serializes the small,
  non-blocking state transition for every claim, while handover remains
  asynchronous and bounded per key. A successful claim means the caller owns
  the key at that linearization point; later contenders replace it in the same
  total order.

  ## Problem

  With full-page navigation, SSE stream processes do not learn that the client
  disconnected until their next write. Stale processes keep subscriptions,
  perform wasted work, and can exhaust HTTP/1.1's per-origin connection limit.

  ## Setup

  Add the registry to your application's supervision tree:

      children = [
        Dstar.Utility.StreamRegistry,
        # ...
      ]

  Then put a per-tab id in your root layout:

      <body data-signals:tab-id="sessionStorage.getItem('_ds_tab') || (() => { const id = crypto.randomUUID(); sessionStorage.setItem('_ds_tab', id); return id; })()">

  `sessionStorage` is per-tab. Use `data-signals:tab-id`, not `tabId` (HTML
  lowercases attribute names and Datastar camelizes the hyphenated form), and
  do not prefix the signal with `_` because Datastar keeps underscore-prefixed
  signals client-side.

  ## Claim and handover contract

  `start_stream/2,3` reads the validated `tabId`, atomically claims
  `{scope_key, tab_id}`, and only then starts SSE. Missing or invalid `tabId`
  intentionally falls back to an ordinary, non-deduplicated stream for rollout
  compatibility. A valid keyed request whose claim fails instead returns a
  halted, non-SSE 503 response — it never starts an untracked stream.

  On replacement, the old holder receives a generation-tagged exit signal.
  `Dstar.Page` recognizes only the generation stored on its conn,
  synchronously releases it, and then performs graceful application teardown.
  A trapping holder that does not release is killed after the grace period.
  Release and escalation
  are serialized by this coordinator, so a release that has returned cannot be
  followed by a stale kill against a keep-alive process now serving unrelated
  work. Stale replacement messages from an older generation cannot stop a newer
  stream in the same process.

  The coordinator monitors every claim, so process death also cleans it up.
  It remains the package's only opt-in process.
  """

  use GenServer

  require Logger

  @registry __MODULE__
  @signal_key "tabId"
  @claim_private :dstar_stream_claim
  @max_tab_id_bytes 64
  @default_grace_ms 500

  @type claim :: reference()
  @type key :: term()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @registry)
  end

  @doc false
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: @registry)
  end

  @impl GenServer
  def init(opts) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    unless is_integer(grace_ms) and grace_ms > 0 do
      raise ArgumentError, ":grace_ms must be a positive integer"
    end

    {:ok, %{active: %{}, claims: %{}, monitors: %{}, grace_ms: grace_ms}}
  end

  @doc """
  Starts an SSE stream with per-tab deduplication.

  Signals are fetched through `Dstar.Signals.fetch/2`. Malformed/non-object
  input receives 400 and oversized input receives 413 before any claim or SSE
  start. Pass `max_bytes: n` as the third argument to change that input limit.

  With a usable `tabId`, the claim is fail-closed: success stores its ownership
  generation in `conn.private` and starts SSE; coordinator failure returns a
  halted plain-text 503 conn without calling `Dstar.start/1`. With no usable
  `tabId`, the documented non-deduplicated fallback still starts ordinary SSE.
  """
  @spec start_stream(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def start_stream(conn, scope_key, opts \\ []) do
    case Dstar.Signals.fetch(conn, opts) do
      {:ok, signals, conn} ->
        start_fetched_stream(conn, scope_key, signals)

      {:error, reason, conn} ->
        Dstar.Signals.send_error(conn, reason)
    end
  end

  defp start_fetched_stream(conn, scope_key, signals) do
    case tab_id(signals) do
      nil ->
        Dstar.start(conn)

      tab_id ->
        key = {scope_key, tab_id}

        case claim(key) do
          {:ok, generation} ->
            conn = Plug.Conn.put_private(conn, @claim_private, %{key: key, claim: generation})

            try do
              Dstar.start(conn)
            catch
              kind, reason ->
                release(conn)
                :erlang.raise(kind, reason, __STACKTRACE__)
            end

          {:error, reason} ->
            Logger.warning(
              "Dstar.Utility.StreamRegistry: could not claim #{inspect(key)} " <>
                "(#{inspect(reason)}) — refusing to start an undeduplicated keyed stream"
            )

            claim_error(conn)
        end
    end
  end

  defp claim_error(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(503, "Stream registry unavailable")
    |> Plug.Conn.halt()
  end

  @doc """
  Replaces the active owner of `key` and atomically claims it for the caller.

  Returns `:ok` only after the coordinator has made the caller the active owner
  at a linearization point. Concurrent contenders are ordered by the
  coordinator; each may succeed and then be replaced by a later claim. The
  displaced generation remains tracked through its bounded handover until it
  releases or is escalated.

  The holder's internal exit signal is
  `{:EXIT, registry_pid, {:replaced, claim_generation}}`. `Dstar.Page`
  validates the generation and presents the legacy
  `{:EXIT, registry_pid, :replaced}` shape to application callbacks.
  Hand-rolled loops should use `start_stream/2,3` and `release/1` rather than
  consuming this internal signal directly.
  """
  @spec replace_and_register(key()) :: :ok | {:error, term()}
  def replace_and_register(key) do
    case claim(key) do
      {:ok, _generation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim(key) do
    case Process.whereis(@registry) do
      nil ->
        {:error, :not_running}

      registry ->
        try do
          GenServer.call(registry, {:claim, key}, :infinity)
        catch
          :exit, reason -> {:error, {:registry_exit, reason}}
        end
    end
  end

  @doc """
  Synchronously releases the exact stream claim stored on `conn`.

  This is the preferred teardown operation for keyed streams. A stale conn can
  release only its own generation and can never clear a newer claim held by a
  reused keep-alive process. Unkeyed conns are a no-op.
  """
  @spec release(Plug.Conn.t()) :: :ok
  def release(%Plug.Conn{} = conn) do
    case conn.private[@claim_private] do
      %{claim: claim} -> release_claim(claim)
      _unkeyed -> :ok
    end
  end

  defp release_claim(claim) do
    case Process.whereis(@registry) do
      nil ->
        :ok

      registry ->
        try do
          GenServer.call(registry, {:release_claim, claim}, :infinity)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  @doc """
  Releases every active or handing-over claim owned by the calling process.

  The call is synchronous. Once it returns, no escalation for a released
  generation can kill that process. This remains as a compatibility helper for
  code that can hold multiple manual claims; new hand-rolled loops should call
  `release/1` with their stream conn. It is a no-op when the opt-in coordinator
  is not running.
  """
  @spec unregister_self() :: :ok
  def unregister_self do
    case Process.whereis(@registry) do
      nil ->
        :ok

      registry ->
        try do
          GenServer.call(registry, :release, :infinity)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  @doc """
  Returns a fetched signal map's (or already-fetched conn's) usable `tabId`.

  A usable id is a non-whitespace binary of 1..#{@max_tab_id_bytes} bytes. The
  exact client-supplied value becomes part of the key; no normalization occurs.
  This helper does not own raw bodies — call `start_stream/2,3` or
  `Dstar.Signals.fetch/2` first when params are unfetched.
  """
  @spec tab_id(Plug.Conn.t() | map()) :: String.t() | nil
  def tab_id(%Plug.Conn{} = conn), do: conn |> Dstar.Signals.read() |> tab_id()

  def tab_id(signals) when is_map(signals) do
    case signals[@signal_key] do
      tab_id when is_binary(tab_id) ->
        if byte_size(tab_id) in 1..@max_tab_id_bytes and String.trim(tab_id) != "",
          do: tab_id

      _ ->
        nil
    end
  end

  @doc false
  @spec owner(key()) :: {:ok, pid(), claim()} | :error
  def owner(key) do
    case Process.whereis(@registry) do
      nil ->
        :error

      registry ->
        try do
          GenServer.call(registry, {:owner, key})
        catch
          :exit, _reason -> :error
        end
    end
  end

  @doc false
  def replacement_for?(%Plug.Conn{} = conn, {:EXIT, _pid, {:replaced, claim}}) do
    match?(%{claim: ^claim}, conn.private[@claim_private])
  end

  def replacement_for?(%Plug.Conn{}, _message), do: false

  @doc false
  def public_replacement({:EXIT, pid, {:replaced, _claim}}), do: {:EXIT, pid, :replaced}

  @impl GenServer
  def handle_call({:claim, key}, {pid, _tag}, state) do
    case active_claim(state, key) do
      %{pid: ^pid, token: token} ->
        {:reply, {:ok, token}, state}

      _current ->
        state = retire_active(state, key)
        token = make_ref()
        monitor = Process.monitor(pid)

        claim_entry = %{
          token: token,
          key: key,
          pid: pid,
          monitor: monitor,
          status: :active,
          timer: nil
        }

        state = %{
          state
          | active: Map.put(state.active, key, token),
            claims: Map.put(state.claims, token, claim_entry),
            monitors: Map.put(state.monitors, monitor, token)
        }

        {:reply, {:ok, token}, state}
    end
  end

  def handle_call({:release_claim, token}, {pid, _tag}, state) do
    state =
      case Map.get(state.claims, token) do
        %{pid: ^pid} -> drop_claim(state, token)
        _stale_or_foreign -> state
      end

    {:reply, :ok, state}
  end

  def handle_call(:release, {pid, _tag}, state) do
    tokens =
      for {token, %{pid: claim_pid}} <- state.claims, claim_pid == pid, do: token

    state = Enum.reduce(tokens, state, &drop_claim(&2, &1))
    {:reply, :ok, state}
  end

  def handle_call({:owner, key}, _from, state) do
    reply =
      case active_claim(state, key) do
        %{pid: pid, token: token} -> {:ok, pid, token}
        nil -> :error
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, token} -> {:noreply, drop_claim(state, token)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:escalate, token}, state) do
    case Map.get(state.claims, token) do
      %{status: :retired, pid: pid} ->
        # The capability is still live and release cannot interleave with this
        # callback. Exact release removes the token and cancels this timer, so
        # any claim still present here is safe to escalate even if the process
        # has since acquired some other, unreleased claim.
        Process.exit(pid, :kill)
        {:noreply, drop_claim(state, token)}

      _ ->
        {:noreply, state}
    end
  end

  defp active_claim(state, key) do
    with {:ok, token} <- Map.fetch(state.active, key) do
      Map.get(state.claims, token)
    else
      :error -> nil
    end
  end

  defp retire_active(state, key) do
    case active_claim(state, key) do
      nil ->
        state

      claim_entry ->
        timer = Process.send_after(self(), {:escalate, claim_entry.token}, state.grace_ms)
        retired = %{claim_entry | status: :retired, timer: timer}
        Process.exit(claim_entry.pid, {:replaced, claim_entry.token})

        %{state | claims: Map.put(state.claims, claim_entry.token, retired)}
    end
  end

  defp drop_claim(state, token) do
    case Map.pop(state.claims, token) do
      {nil, _claims} ->
        state

      {claim_entry, claims} ->
        if claim_entry.timer, do: Process.cancel_timer(claim_entry.timer)
        Process.demonitor(claim_entry.monitor, [:flush])

        active =
          case Map.get(state.active, claim_entry.key) do
            ^token -> Map.delete(state.active, claim_entry.key)
            _other -> state.active
          end

        %{
          state
          | active: active,
            claims: claims,
            monitors: Map.delete(state.monitors, claim_entry.monitor)
        }
    end
  end
end
