defmodule Dstar.Utility.StreamRegistryTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Dstar.Utility.StreamRegistry

  @grace_wait 250

  defp owner_claim(key, pid) do
    case StreamRegistry.owner(key) do
      {:ok, ^pid, claim} -> claim
      other -> flunk("expected #{inspect(pid)} to own #{inspect(key)}, got: #{inspect(other)}")
    end
  end

  defp assert_no_owner(key, attempts \\ 20)
  defp assert_no_owner(key, 0), do: assert(StreamRegistry.owner(key) == :error)

  defp assert_no_owner(key, attempts) do
    case StreamRegistry.owner(key) do
      :error ->
        :ok

      _owner ->
        Process.sleep(10)
        assert_no_owner(key, attempts - 1)
    end
  end

  describe "linearizable claims" do
    test "a successful claim makes the caller the sole active owner" do
      key = {make_ref(), make_ref()}

      assert :ok = StreamRegistry.replace_and_register(key)
      claim = owner_claim(key, self())
      assert is_reference(claim)
    end

    test "claiming the same key twice from one process is idempotent" do
      key = {make_ref(), make_ref()}

      assert :ok = StreamRegistry.replace_and_register(key)
      claim = owner_claim(key, self())
      assert :ok = StreamRegistry.replace_and_register(key)
      assert owner_claim(key, self()) == claim
    end

    test "barrier-released contenders all have defined linearizable outcomes" do
      key = {make_ref(), make_ref()}
      parent = self()

      contenders =
        for _ <- 1..12 do
          spawn(fn ->
            Process.flag(:trap_exit, true)

            receive do
              :claim -> :ok
            end

            result = StreamRegistry.replace_and_register(key)
            send(parent, {:claim_result, self(), result})

            receive do
              {:EXIT, _registry, {:replaced, claim}} ->
                send(parent, {:replaced, self(), claim})
                StreamRegistry.unregister_self()
                Process.sleep(:infinity)

              :stop ->
                StreamRegistry.unregister_self()
            end
          end)
        end

      Enum.each(contenders, &send(&1, :claim))

      results =
        for _ <- contenders do
          assert_receive {:claim_result, pid, :ok}, 1_000
          pid
        end

      assert MapSet.new(results) == MapSet.new(contenders)
      assert {:ok, final_pid, final_claim} = StreamRegistry.owner(key)
      assert final_pid in results

      replaced =
        for _ <- 1..(length(contenders) - 1), into: MapSet.new() do
          assert_receive {:replaced, pid, _claim}, 1_000
          assert pid in results
          pid
        end

      assert MapSet.equal?(replaced, MapSet.new(contenders -- [final_pid]))
      assert {:ok, ^final_pid, ^final_claim} = StreamRegistry.owner(key)

      Enum.each(contenders, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end

    test "different keys coexist" do
      key1 = {make_ref(), make_ref()}
      key2 = {make_ref(), make_ref()}
      parent = self()

      pid =
        spawn(fn ->
          :ok = StreamRegistry.replace_and_register(key1)
          {:ok, _, claim} = StreamRegistry.owner(key1)
          send(parent, {:claimed, self(), claim})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, ^pid, claim1}
      assert :ok = StreamRegistry.replace_and_register(key2)
      assert {:ok, ^pid, ^claim1} = StreamRegistry.owner(key1)
      claim2 = owner_claim(key2, self())
      assert is_reference(claim2)

      Process.exit(pid, :kill)
    end
  end

  describe "generation-safe takeover" do
    test "a non-trapping holder exits and the new caller remains sole owner" do
      key = {make_ref(), make_ref()}
      parent = self()

      holder =
        spawn(fn ->
          :ok = StreamRegistry.replace_and_register(key)
          {:ok, _, claim} = StreamRegistry.owner(key)
          send(parent, {:claimed, self(), claim})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, ^holder, old_claim}
      ref = Process.monitor(holder)

      assert :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert_receive {:DOWN, ^ref, :process, ^holder, {:replaced, ^old_claim}}, 1_000
      assert owner_claim(key, self()) == new_claim
    end

    test "a trapping holder that ignores replacement is killed after the grace period" do
      key = {make_ref(), make_ref()}
      parent = self()

      holder =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          :ok = StreamRegistry.replace_and_register(key)
          {:ok, _, claim} = StreamRegistry.owner(key)
          send(parent, {:claimed, self(), claim})

          receive do
            {:EXIT, _registry, {:replaced, ^claim}} ->
              send(parent, {:replacement_received, self()})
              Process.sleep(:infinity)
          end
        end)

      assert_receive {:claimed, ^holder, _claim}
      ref = Process.monitor(holder)
      assert :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert_receive {:replacement_received, ^holder}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, @grace_wait
      assert owner_claim(key, self()) == new_claim
    end

    test "another unreleased claim cannot suppress escalation" do
      key = {make_ref(), make_ref()}
      other_key = {make_ref(), make_ref()}
      parent = self()

      holder =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          :ok = StreamRegistry.replace_and_register(key)
          {:ok, _, claim} = StreamRegistry.owner(key)
          send(parent, {:claimed, self(), claim})

          receive do
            {:EXIT, _registry, {:replaced, ^claim}} ->
              # Acquiring another claim is not a substitute for releasing this
              # generation; otherwise the old stream becomes an untracked
              # zombie when escalation drops it.
              :ok = StreamRegistry.replace_and_register(other_key)
              send(parent, {:claimed_other, self()})
              Process.sleep(:infinity)
          end
        end)

      assert_receive {:claimed, ^holder, _claim}
      ref = Process.monitor(holder)
      assert :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert_receive {:claimed_other, ^holder}, 1_000
      assert {:ok, ^holder, _other_claim} = StreamRegistry.owner(other_key)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, @grace_wait
      assert owner_claim(key, self()) == new_claim
      assert_no_owner(other_key)
    end

    test "a trapping holder that releases is left alive" do
      key = {make_ref(), make_ref()}
      parent = self()

      holder =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          :ok = StreamRegistry.replace_and_register(key)
          {:ok, _, claim} = StreamRegistry.owner(key)
          send(parent, {:claimed, self(), claim})

          receive do
            {:EXIT, _registry, {:replaced, ^claim}} ->
              StreamRegistry.unregister_self()
              send(parent, {:released, self()})
              Process.sleep(:infinity)
          end
        end)

      assert_receive {:claimed, ^holder, _claim}
      assert :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert_receive {:released, ^holder}, 1_000
      Process.sleep(@grace_wait)

      assert Process.alive?(holder)
      assert owner_claim(key, self()) == new_claim
      Process.exit(holder, :kill)
    end

    test "an old conn releases only its generation, not a newer claim on the same process" do
      previous_trap = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap) end)

      scope = make_ref()
      key = {scope, "same-process"}
      old_conn = StreamRegistry.start_stream(stream_conn("same-process"), scope)
      assert %{claim: old_claim} = old_conn.private[:dstar_stream_claim]

      parent = self()

      taker =
        spawn(fn ->
          :ok = StreamRegistry.replace_and_register(key)
          send(parent, {:taker_claimed, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:EXIT, _registry, {:replaced, ^old_claim}}, 1_000
      assert_receive {:taker_claimed, ^taker}, 1_000

      :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert new_claim != old_claim

      assert :ok = StreamRegistry.release(old_conn)
      assert owner_claim(key, self()) == new_claim

      StreamRegistry.unregister_self()
      if Process.alive?(taker), do: Process.exit(taker, :kill)
    end

    test "a release queued immediately before escalation cannot kill a reused process" do
      key = {make_ref(), make_ref()}
      parent = self()

      holder =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          :ok = StreamRegistry.replace_and_register(key)
          {:ok, _, claim} = StreamRegistry.owner(key)
          send(parent, {:claimed, self(), claim})

          receive do
            {:EXIT, _registry, {:replaced, ^claim}} ->
              send(parent, {:ready_to_release, self()})

              receive do
                :release ->
                  send(parent, {:release_calling, self()})
                  StreamRegistry.unregister_self()
                  send(parent, {:released, self()})
                  Process.sleep(:infinity)
              end
          end
        end)

      assert_receive {:claimed, ^holder, _claim}
      assert :ok = StreamRegistry.replace_and_register(key)
      new_claim = owner_claim(key, self())
      assert_receive {:ready_to_release, ^holder}, 1_000

      registry = Process.whereis(StreamRegistry)
      :ok = :sys.suspend(registry)
      send(holder, :release)
      assert_receive {:release_calling, ^holder}, 1_000
      Process.sleep(@grace_wait)
      :ok = :sys.resume(registry)

      assert_receive {:released, ^holder}, 1_000
      Process.sleep(20)
      assert Process.alive?(holder)
      assert owner_claim(key, self()) == new_claim
      Process.exit(holder, :kill)
    end
  end

  describe "start_stream/2" do
    defp stream_conn(tab_id) do
      conn(:post, "/stream")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"tabId" => tab_id})
    end

    test "claims a validated tabId before starting SSE" do
      scope = make_ref()
      conn = StreamRegistry.start_stream(stream_conn("6f1c9b3e-tab"), scope)

      assert conn.state == :chunked

      assert %{key: {^scope, "6f1c9b3e-tab"}, claim: claim} =
               conn.private[:dstar_stream_claim]

      assert owner_claim({scope, "6f1c9b3e-tab"}, self()) == claim
    end

    test "safely reads a raw object and threads the conn into SSE" do
      scope = make_ref()

      conn =
        conn(:post, "/stream", ~s({"tabId":"raw-tab"}))
        |> StreamRegistry.start_stream(scope)

      assert conn.state == :chunked
      assert conn.body_params == %{"tabId" => "raw-tab"}
      assert is_reference(owner_claim({scope, "raw-tab"}, self()))
    end

    test "a missing or invalid tabId uses the documented non-deduplicated path" do
      for signals <- [
            %{},
            %{"tabId" => ""},
            %{"tabId" => "   "},
            %{"tabId" => 42},
            %{"tabId" => true},
            %{"tabId" => ["a"]},
            %{"tabId" => %{"a" => 1}},
            %{"tabId" => String.duplicate("x", 65)}
          ] do
        scope = make_ref()
        conn = conn(:post, "/stream") |> Map.put(:body_params, signals)
        conn = StreamRegistry.start_stream(conn, scope)

        assert conn.state == :chunked
        refute Map.has_key?(conn.private, :dstar_stream_claim)
        assert :error = StreamRegistry.owner({scope, Map.get(signals, "tabId")})
      end
    end

    test "signal input errors return before registry claim or SSE" do
      for body <- ["{", "[]", "null"] do
        scope = make_ref()
        conn = conn(:post, "/stream", body) |> StreamRegistry.start_stream(scope)

        assert conn.status == 400
        assert conn.state == :sent
        assert conn.halted
      end

      scope = make_ref()

      conn =
        conn(:post, "/stream", ~s({"tabId":"too-long"}))
        |> StreamRegistry.start_stream(scope, max_bytes: 8)

      assert conn.status == 413
      assert conn.state == :sent
      assert conn.halted
    end

    test "a failed claim returns 503 without starting SSE" do
      registry = Process.whereis(StreamRegistry)
      :ok = GenServer.stop(registry)

      conn =
        try do
          StreamRegistry.start_stream(stream_conn("registry-down"), make_ref())
        after
          {:ok, _pid} = StreamRegistry.start(grace_ms: 100)
        end

      assert conn.status == 503
      assert conn.state == :sent
      assert conn.halted
      refute conn.state == :chunked

      refute Plug.Conn.get_resp_header(conn, "content-type") == [
               "text/event-stream; charset=utf-8"
             ]

      refute Map.has_key?(conn.private, :dstar_stream_claim)
    end
  end

  describe "tab_id/1" do
    test "returns a validated id from fetched signals" do
      assert StreamRegistry.tab_id(%{"tabId" => "tab-1"}) == "tab-1"

      for bad <- ["", "  ", 42, nil, String.duplicate("x", 65)] do
        assert StreamRegistry.tab_id(%{"tabId" => bad}) == nil
      end
    end
  end
end
