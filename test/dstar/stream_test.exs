defmodule Dstar.StreamTest do
  # The registry is a single named process shared by every test.
  use ExUnit.Case, async: false

  import Plug.Test

  alias Dstar.Stream
  alias Dstar.Utility.StreamRegistry

  defp keyed_conn(tab_id) do
    conn(:post, "/stream") |> Map.put(:body_params, %{"tabId" => tab_id})
  end

  # Runs `fun` in a process that OUTLIVES the stream, the way a keep-alive
  # connection process is reused for the next request. Process death would
  # otherwise clean the registry up and hide a missing release.
  defp spawn_stream(fun, opts \\ []) do
    parent = self()

    spawn(fn ->
      if Keyword.get(opts, :trap_exits, false), do: Process.flag(:trap_exit, true)

      result =
        try do
          {:returned, fun.(parent)}
        rescue
          exception -> {:raised, exception}
        end

      send(parent, {:stream_done, self(), result})
      Process.sleep(:infinity)
    end)
  end

  defp connected(parent) do
    fn conn ->
      send(parent, {:connected, self()})
      conn
    end
  end

  describe "open/2" do
    test "without :key starts an unkeyed SSE stream" do
      assert {:ok, conn} = Stream.open(conn(:post, "/stream"))
      assert conn.state == :chunked
    end

    test "with :key claims {key, tabId} before SSE starts" do
      key = make_ref()
      assert {:ok, conn} = Stream.open(keyed_conn("tab-open"), key: key)

      assert conn.state == :chunked
      assert {:ok, pid, _claim} = StreamRegistry.owner({key, "tab-open"})
      assert pid == self()

      StreamRegistry.release(conn)
    end

    test "with :key but no usable tabId falls back to an unkeyed stream" do
      assert {:ok, conn} = Stream.open(conn(:post, "/stream"), key: make_ref())
      assert conn.state == :chunked
    end

    test "a refused claim is an {:error, conn} 503, never SSE" do
      :ok = GenServer.stop(StreamRegistry)

      result =
        try do
          Stream.open(keyed_conn("tab-down"), key: make_ref())
        after
          {:ok, _pid} = StreamRegistry.start(grace_ms: 100)
        end

      assert {:error, conn} = result
      assert conn.status == 503
      assert conn.halted
    end

    test "passes :max_bytes to the signal read" do
      body = Jason.encode!(%{tabId: "tab-big", pad: String.duplicate("x", 200)})

      conn =
        conn(:post, "/stream", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      assert {:error, conn} = Stream.open(conn, key: make_ref(), max_bytes: 50)
      assert conn.status == 413
    end
  end

  describe "run/2" do
    test "dispatches messages to :info until it halts, then :disconnect" do
      pid =
        spawn_stream(fn parent ->
          {:ok, conn} = Stream.open(conn(:post, "/stream"))

          Stream.run(conn,
            connect: connected(parent),
            info: fn
              {:tick, n}, conn -> Dstar.Signals.patch(conn, %{tick: n})
              :stop, conn -> {:halt, conn}
            end,
            disconnect: fn _conn -> send(parent, :disconnected) end
          )
        end)

      assert_receive {:connected, ^pid}
      send(pid, {:tick, 1})
      send(pid, :stop)

      assert_receive :disconnected
      assert_receive {:stream_done, ^pid, {:returned, conn}}
      assert Dstar.Test.patched_signals(conn) == %{"tick" => 1}

      Process.exit(pid, :kill)
    end

    test "skips {:plug_conn, :sent} and leaves Bandit messages in the mailbox" do
      pid =
        spawn_stream(fn parent ->
          {:ok, conn} = Stream.open(conn(:post, "/stream"))

          Stream.run(conn,
            connect: connected(parent),
            info: fn
              :ping, conn ->
                send(parent, :pong)
                conn

              other, conn ->
                send(parent, {:dispatched, other})
                {:halt, conn}
            end
          )
        end)

      assert_receive {:connected, ^pid}
      send(pid, {:plug_conn, :sent})
      send(pid, {:bandit, {:send_window_update, 1}})
      send(pid, :ping)

      # The pong proves the loop got past both messages queued before it.
      assert_receive :pong
      assert {:messages, [{:bandit, {:send_window_update, 1}}]} = Process.info(pid, :messages)
      refute_received {:dispatched, _}

      send(pid, :stop)
      assert_receive {:dispatched, :stop}
      assert_receive {:stream_done, ^pid, _}
      Process.exit(pid, :kill)
    end

    test "a takeover releases the claim, then runs :replaced and :disconnect" do
      key = make_ref()
      tab_key = {key, "tab-takeover"}

      old =
        spawn_stream(
          fn parent ->
            {:ok, conn} = Stream.open(keyed_conn("tab-takeover"), key: key)

            Stream.run(conn,
              connect: connected(parent),
              replaced: fn msg, conn ->
                send(parent, {:replaced, msg, StreamRegistry.owner(tab_key)})
                conn
              end,
              disconnect: fn _conn -> send(parent, :old_disconnected) end
            )
          end,
          trap_exits: true
        )

      assert_receive {:connected, ^old}

      new =
        spawn_stream(fn parent ->
          {:ok, conn} = Stream.open(keyed_conn("tab-takeover"), key: key)
          send(parent, {:connected, self()})
          Process.sleep(:infinity)
          conn
        end)

      assert_receive {:connected, ^new}
      assert_receive {:replaced, {:EXIT, _pid, :replaced}, owner}
      # Released before the application callback ran: the new stream owns it.
      assert {:ok, ^new, _claim} = owner
      assert_receive :old_disconnected
      assert_receive {:stream_done, ^old, {:returned, _conn}}

      # Graceful: the old process was left alive, not killed by escalation.
      Process.sleep(150)
      assert Process.alive?(old)

      Enum.each([old, new], &Process.exit(&1, :kill))
    end

    test "ignores replacement signals from a stale generation" do
      key = make_ref()

      pid =
        spawn_stream(
          fn parent ->
            {:ok, conn} = Stream.open(keyed_conn("tab-stale"), key: key)

            Stream.run(conn,
              connect: connected(parent),
              info: fn
                :ping, conn ->
                  send(parent, :pong)
                  conn

                :stop, conn ->
                  {:halt, conn}
              end
            )
          end,
          trap_exits: true
        )

      assert_receive {:connected, ^pid}
      send(pid, {:EXIT, self(), {:replaced, make_ref()}})
      send(pid, {:EXIT, self(), :replaced})
      send(pid, :ping)

      assert_receive :pong
      assert {:ok, ^pid, _claim} = StreamRegistry.owner({key, "tab-stale"})

      send(pid, :stop)
      assert_receive {:stream_done, ^pid, {:returned, _}}
      assert StreamRegistry.owner({key, "tab-stale"}) == :error
      Process.exit(pid, :kill)
    end

    test "a raise in :connect releases the claim on the way out" do
      assert_raise_releases("tab-raise-connect", [connect: fn _conn -> raise "boom" end], nil)
    end

    test "a raise in :info releases the claim on the way out" do
      assert_raise_releases("tab-raise-info", [info: fn _msg, _conn -> raise "boom" end], :go)
    end
  end

  defp assert_raise_releases(tab_id, run_opts, message) do
    key = make_ref()

    pid =
      spawn_stream(fn parent ->
        {:ok, conn} = Stream.open(keyed_conn(tab_id), key: key)
        send(parent, {:connected, self()})
        Stream.run(conn, run_opts)
      end)

    assert_receive {:connected, ^pid}
    if message, do: send(pid, message)

    assert_receive {:stream_done, ^pid, {:raised, %RuntimeError{message: "boom"}}}
    # The process survives, as a reused keep-alive process would.
    assert Process.alive?(pid)
    assert StreamRegistry.owner({key, tab_id}) == :error

    Process.exit(pid, :kill)
  end
end
