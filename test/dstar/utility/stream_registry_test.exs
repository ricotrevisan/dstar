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
