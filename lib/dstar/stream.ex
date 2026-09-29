defmodule Dstar.Stream do
  @moduledoc """
  Opens a long-lived SSE stream and owns its receive loop.

  `Dstar.Page` streams run on this module; plain controllers use it the same
  way. It owns the parts of a stream's lifecycle that are easy to get subtly
  wrong in a hand-rolled `receive`:

  - **Keyed claims.** With `key:`, `open/2` claims `{key, tabId}` through the
    opt-in `Dstar.Utility.StreamRegistry` before SSE starts, and reports a
    refused claim as `{:error, conn}`.
  - **Takeover.** When a newer stream for the same tab claims the key, the
    registry signals this stream with its exact claim generation. `run/2`
    recognises only its own generation, releases the claim, then tears down.
    Stale signals from an earlier stream on a reused keep-alive process are
    ignored.
  - **Adapter plumbing.** `{:plug_conn, :sent}` is skipped, and Bandit's
    `{:bandit, _}` flow-control messages are left in the mailbox for Bandit's
    own selective receive. A catch-all `receive` would swallow them and can
    stall an HTTP/2 stream.
  - **Liveness and release.** An idle stream is probed every `:idle_check`
    ms and torn down once the client is gone. The claim is always released
    before `:disconnect` runs, and again if any callback raises.

  ## Example

      def stream(conn, _params) do
        user = conn.assigns.current_user

        case Dstar.Stream.open(conn, key: user.id) do
          {:ok, conn} ->
            Dstar.Stream.run(conn,
              connect: fn conn ->
                Phoenix.PubSub.subscribe(MyApp.PubSub, "user:\#{user.id}")
                conn
              end,
              info: fn
                {:notification, n}, conn -> Dstar.Elements.append(conn, row(n), "#inbox")
                :logout, conn -> {:halt, conn}
              end,
              disconnect: fn _conn ->
                Phoenix.PubSub.unsubscribe(MyApp.PubSub, "user:\#{user.id}")
              end
            )

          {:error, conn} ->
            # 400/413 (bad signals) or 503 (claim refused): plain HTTP, no SSE.
            conn
        end
      end

  `Dstar.start_stream/2,3` and `Dstar.Utility.StreamRegistry.release/1`
  remain available for loops that must own their `receive`.
  """

  require Logger

  alias Dstar.Utility.StreamRegistry

  @default_idle_check 30_000

  @type info_result :: Plug.Conn.t() | {:halt, Plug.Conn.t()}

  @doc """
  Starts SSE on `conn`, claiming a per-tab key first when `:key` is given.

  Returns `{:ok, conn}` with a chunked SSE conn, or `{:error, conn}` with an
  ordinary halted HTTP response already sent: 400/413 when a keyed stream's
  signals cannot be read, 503 when the registry refuses the claim. Never
  start subscriptions on the error path.

  Without `:key`, this is `Dstar.start/1`. With `:key`, it is
  `Dstar.start_stream/3`: a missing or invalid `tabId` signal falls back to an
  ordinary unkeyed stream.

  ## Options

  - `:key` — scope key for per-tab deduplication (any term, e.g. `user.id`).
    Requires `Dstar.Utility.StreamRegistry` in the supervision tree.
  - `:max_bytes` — limit for reading signals on a keyed stream (see
    `Dstar.Signals.fetch/2`).
  """
  @spec open(Plug.Conn.t(), keyword()) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def open(%Plug.Conn{} = conn, opts \\ []) do
    conn =
      case Keyword.fetch(opts, :key) do
        {:ok, key} -> StreamRegistry.start_stream(conn, key, Keyword.take(opts, [:max_bytes]))
        :error -> Dstar.SSE.start(conn)
      end

    if conn.state == :chunked, do: {:ok, conn}, else: {:error, conn}
  end

  @doc """
  Runs the receive loop for a conn returned by `open/2`, until the client
  disconnects, a callback halts, or a newer stream takes over the key.

  Returns the final conn. The stream's claim is released before
  `:disconnect` runs, and on the way out if any callback raises.

  ## Options

  - `:connect` — `(conn -> conn)`, called once before the loop. Subscribe
    here: a raise releases the claim.
  - `:info` — `(message, conn -> conn | {:halt, conn})`, called for every
    application message. `{:halt, conn}` ends the stream. Without it,
    messages are logged and dropped.
  - `:replaced` — `(message, conn -> conn)`, called when a newer stream takes
    over this key, after the claim is released and before `:disconnect`.
    `message` is `{:EXIT, pid, :replaced}`.
  - `:disconnect` — `(conn -> any)`, called once when the loop ends for any
    reason other than a raise.
  - `:idle_check` — ms without messages before probing the connection
    (default #{@default_idle_check}).
  """
  @spec run(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, opts \\ []) do
    callbacks = %{
      info: Keyword.get(opts, :info, &unhandled/2),
      replaced: Keyword.get(opts, :replaced, fn _msg, conn -> conn end),
      disconnect: Keyword.get(opts, :disconnect, fn _conn -> :ok end),
      idle_check: Keyword.get(opts, :idle_check, @default_idle_check)
    }

    connect = Keyword.get(opts, :connect, & &1)

    try do
      conn |> connect.() |> loop(callbacks)
    after
      # Idempotent: a normal exit already released in teardown/2.
      StreamRegistry.release(conn)
    end
  end

  defp loop(conn, callbacks) do
    receive do
      # Plug adapters notify the conn owner when the response is sent;
      # this is internal plumbing, never an application message.
      {:plug_conn, :sent} ->
        loop(conn, callbacks)

      # The coordinator tags replacement signals with the exact claim
      # generation. A matching signal ends this stream; a stale generation
      # left in a reused keep-alive process's mailbox is ignored.
      {:EXIT, _pid, {:replaced, _claim}} = msg ->
        if StreamRegistry.replacement_for?(conn, msg) do
          # Release before application teardown. The coordinator can no
          # longer escalate this generation while a slow callback cleans up.
          StreamRegistry.release(conn)

          StreamRegistry.public_replacement(msg)
          |> callbacks.replaced.(conn)
          |> unwrap_halt()
          |> teardown(callbacks)
        else
          loop(conn, callbacks)
        end

      # Pre-generation replacement messages can only be stale after this
      # implementation is running. Ignore them rather than poisoning the
      # next request on a keep-alive connection.
      {:EXIT, _pid, :replaced} ->
        loop(conn, callbacks)

      # Bandit's HTTP/2 stream consumes its own two-tuple flow-control
      # messages by selective receive inside the send path. Leave them in
      # the mailbox or the stream can stall when its send window drains.
      msg when not is_tuple(msg) or tuple_size(msg) != 2 or elem(msg, 0) != :bandit ->
        case callbacks.info.(msg, conn) do
          {:halt, conn} -> teardown(conn, callbacks)
          conn -> loop(conn, callbacks)
        end
    after
      callbacks.idle_check ->
        case Dstar.SSE.check_connection(conn) do
          {:ok, conn} -> loop(conn, callbacks)
          {:error, conn} -> teardown(conn, callbacks)
        end
    end
  end

  # Registry entries and PubSub subscriptions are released when the owning
  # process dies. Under HTTP/1.1 keep-alive the connection process does NOT
  # die when the stream ends — it is reused for the next request on that
  # socket — so without this everything the stream registered stays
  # registered, owned by a process now serving unrelated traffic.
  defp teardown(conn, callbacks) do
    StreamRegistry.release(conn)
    callbacks.disconnect.(conn)
    conn
  end

  defp unwrap_halt({:halt, conn}), do: conn
  defp unwrap_halt(conn), do: conn

  defp unhandled(msg, conn) do
    Logger.warning("Dstar.Stream received unhandled message: #{inspect(msg)}")
    conn
  end
end
