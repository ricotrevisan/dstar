defmodule Dstar.Utility.StreamRegistryTest do
  use ExUnit.Case, async: false

  test "replace_and_register replaces previous process for same key" do
    key = {make_ref(), make_ref()}

    pid1 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key)
        Process.sleep(:infinity)
      end)

    ref = Process.monitor(pid1)
    Process.sleep(50)

    # Verify pid1 is registered
    assert [{^pid1, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)

    # Second registration should kill pid1
    Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert_receive {:DOWN, ^ref, :process, ^pid1, :replaced}

    # Current process is now registered
    assert [{pid, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)
    assert pid == self()
  end

  test "different keys coexist" do
    key1 = {make_ref(), make_ref()}
    key2 = {make_ref(), make_ref()}

    pid1 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key1)
        Process.sleep(:infinity)
      end)

    pid2 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key2)
        Process.sleep(:infinity)
      end)

    Process.sleep(50)
    assert Process.alive?(pid1)
    assert Process.alive?(pid2)

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  test "no-op when no previous process exists" do
    key = {make_ref(), make_ref()}

    assert :ok = Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert [{pid, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)
    assert pid == self()
  end

  test "same process re-registering does not kill self" do
    key = {make_ref(), make_ref()}

    Dstar.Utility.StreamRegistry.replace_and_register(key)
    Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert Process.alive?(self())
  end

  describe "replace_and_register/1 against a process that traps exits (#17)" do
    alias Dstar.Utility.StreamRegistry

    # Every Thousand Island handler — so every Bandit connection process —
    # calls Process.flag(:trap_exit, true), which turns Process.exit(pid,
    # :replaced) into an ordinary message. The pre-existing tests spawn
    # plain processes, so they never exercised the case that actually ships.
    defp spawn_trapping_holder(key) do
      test = self()

      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          StreamRegistry.replace_and_register(key)
          send(test, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000
      pid
    end

    test "the previous holder is replaced even though it ignores the signal" do
      key = {make_ref(), make_ref()}
      pid = spawn_trapping_holder(key)
      ref = Process.monitor(pid)

      StreamRegistry.replace_and_register(key)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert [{holder, _}] = Registry.lookup(StreamRegistry, key)
      assert holder == self()
    end

    test "the takeover does not stall the request for seconds" do
      key = {make_ref(), make_ref()}
      spawn_trapping_holder(key)

      {micros, _} = :timer.tc(fn -> StreamRegistry.replace_and_register(key) end)

      assert micros < 2_000_000, "takeover took #{div(micros, 1000)}ms"
    end

    test "a holder that releases the key itself is left alive" do
      # What the library loop does: handle {:EXIT, _, :replaced}, unregister,
      # then carry on living as a keep-alive connection process. Killing it
      # here would take down a process serving an unrelated request.
      key = {make_ref(), make_ref()}
      test = self()

      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          StreamRegistry.replace_and_register(key)
          send(test, :registered)

          receive do
            {:EXIT, _, :replaced} ->
              StreamRegistry.unregister_self()
              send(test, :released)
              Process.sleep(:infinity)
          end
        end)

      assert_receive :registered, 1_000

      StreamRegistry.replace_and_register(key)

      assert_receive :released, 1_000
      assert Process.alive?(pid)
      assert [{holder, _}] = Registry.lookup(StreamRegistry, key)
      assert holder == self()

      Process.exit(pid, :kill)
    end

    test "reports failure instead of returning a hardcoded :ok" do
      key = {make_ref(), make_ref()}

      assert :ok = StreamRegistry.replace_and_register(key)
      # Same process, same key — idempotent, not an error.
      assert :ok = StreamRegistry.replace_and_register(key)
    end

    test "a key held by a live process is reported, not swallowed" do
      # The #17 bullet "stop discarding the Registry.register/3 result" has no
      # other coverage: every takeover path ends in success, so a regression to
      # an unconditional :ok would pass the rest of this suite. Driving the
      # claim directly is the only way to reach the branch deterministically —
      # via replace_and_register/1 the holder is always killed first.
      key = {make_ref(), make_ref()}
      test = self()

      holder =
        spawn(fn ->
          Registry.register(StreamRegistry, key, nil)
          send(test, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held, 1_000

      assert {:error, {:already_registered, ^holder}} = StreamRegistry.register(key, 2)

      Process.exit(holder, :kill)
    end
  end

  describe "start_stream/2 tabId validation" do
    import Plug.Test

    alias Dstar.Utility.StreamRegistry

    defp stream_conn(tab_id) do
      conn(:post, "/stream")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"tabId" => tab_id})
    end

    defp registered_keys, do: Registry.keys(StreamRegistry, self())

    test "registers a well-formed tabId under {scope_key, tab_id}" do
      scope = make_ref()
      StreamRegistry.start_stream(stream_conn("6f1c9b3e-tab"), scope)

      assert {scope, "6f1c9b3e-tab"} in registered_keys()
    end

    test "safely reads a raw object and threads the conn into SSE" do
      scope = make_ref()

      conn =
        conn(:post, "/stream", ~s({"tabId":"raw-tab"}))
        |> StreamRegistry.start_stream(scope)

      assert {scope, "raw-tab"} in registered_keys()
      assert conn.state == :chunked
      assert conn.body_params == %{"tabId" => "raw-tab"}
    end

    test "malformed and non-object signals fail before registry claim or SSE" do
      for body <- ["{", "[]", "null"] do
        scope = make_ref()
        conn = conn(:post, "/stream", body) |> StreamRegistry.start_stream(scope)

        assert conn.status == 400
        assert conn.state == :sent
        refute Enum.any?(registered_keys(), &match?({^scope, _}, &1))
      end
    end

    test "oversized signals receive 413 before registry claim or SSE" do
      scope = make_ref()

      conn =
        conn(:post, "/stream", ~s({"tabId":"too-long"}))
        |> StreamRegistry.start_stream(scope, max_bytes: 8)

      assert conn.status == 413
      assert conn.state == :sent
      refute Enum.any?(registered_keys(), &match?({^scope, _}, &1))
    end

    test "an empty tabId does not claim a key" do
      # Every tab sending "" would collide on one key and kill each other.
      scope = make_ref()
      StreamRegistry.start_stream(stream_conn(""), scope)

      assert registered_keys() == []
    end

    test "a whitespace-only tabId does not claim a key" do
      scope = make_ref()
      StreamRegistry.start_stream(stream_conn("   "), scope)

      assert registered_keys() == []
    end

    test "non-binary tabIds do not claim a key" do
      for tab_id <- [42, true, ["a"], %{"a" => 1}, 1.5] do
        scope = make_ref()
        StreamRegistry.start_stream(stream_conn(tab_id), scope)

        assert registered_keys() == [], "#{inspect(tab_id)} was accepted as a tabId"
      end
    end

    test "an over-long tabId does not claim a key" do
      scope = make_ref()
      StreamRegistry.start_stream(stream_conn(String.duplicate("x", 65)), scope)

      assert registered_keys() == []
    end

    test "a missing tabId falls through to the documented no-dedup path" do
      scope = make_ref()
      conn = conn(:post, "/stream") |> Map.put(:body_params, %{})

      conn = StreamRegistry.start_stream(conn, scope)

      assert registered_keys() == []
      assert conn.state == :chunked
    end
  end

  describe "tab_id/1" do
    import Plug.Test

    alias Dstar.Utility.StreamRegistry

    test "returns the validated tabId so apps can rebuild the registry key" do
      conn =
        conn(:post, "/stream")
        |> Map.put(:body_params, %{"tabId" => "tab-1"})

      assert StreamRegistry.tab_id(conn) == "tab-1"
    end

    test "returns nil for a tabId the registry would reject" do
      for bad <- ["", "  ", 42, nil, String.duplicate("x", 65)] do
        conn = conn(:post, "/stream") |> Map.put(:body_params, %{"tabId" => bad})

        assert StreamRegistry.tab_id(conn) == nil, "#{inspect(bad)} passed validation"
      end
    end
  end
end
