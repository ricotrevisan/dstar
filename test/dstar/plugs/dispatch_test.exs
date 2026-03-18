defmodule Dstar.Plugs.DispatchTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.Plugs.Dispatch
  alias Dstar.{SSE, Signals}

  # Test handler modules
  defmodule TestCounterHandler do
    def handle_event(conn, event, signals) do
      count = signals["count"] || 0

      new_count =
        case event do
          "increment" -> count + 1
          "decrement" -> count - 1
          "reset" -> 0
          _ -> count
        end

      conn
      |> SSE.start()
      |> Signals.patch(%{count: new_count})
    end
  end

  defmodule TestChatHandler do
    def handle_event(conn, "send_message", signals) do
      message = signals["message"] || ""

      conn
      |> SSE.start()
      |> Signals.patch(%{message: message, sent: true})
    end

    def handle_event(conn, "clear", _signals) do
      conn
      |> SSE.start()
      |> Signals.patch(%{message: "", sent: false})
    end
  end

  describe "init/1" do
    test "raises when :modules option is missing" do
      assert_raise KeyError, fn ->
        Dispatch.init([])
      end
    end

    test "builds a lookup map from modules" do
      opts = Dispatch.init(modules: [TestCounterHandler, TestChatHandler])

      assert %{lookup: lookup} = opts
      assert is_map(lookup)
      assert map_size(lookup) == 2

      # Verify the lookup contains encoded module names
      counter_encoded = Dstar.Actions.encode_module(TestCounterHandler)
      chat_encoded = Dstar.Actions.encode_module(TestChatHandler)

      assert Map.has_key?(lookup, counter_encoded)
      assert Map.has_key?(lookup, chat_encoded)
      assert lookup[counter_encoded] == TestCounterHandler
      assert lookup[chat_encoded] == TestChatHandler
    end

    test "handles empty modules list" do
      opts = Dispatch.init(modules: [])
      assert %{lookup: lookup} = opts
      assert lookup == %{}
    end

    test "handles single module" do
      opts = Dispatch.init(modules: [TestCounterHandler])
      assert %{lookup: lookup} = opts
      assert map_size(lookup) == 1
    end
  end

  describe "call/2" do
    setup do
      opts = Dispatch.init(modules: [TestCounterHandler, TestChatHandler])
      %{opts: opts}
    end

    test "dispatches to correct handler via path params", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      conn =
        conn(:post, "/ds/#{module_name}/increment")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "increment"})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"count" => 5})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
      assert result.status == 200
    end

    test "reads signals from GET request", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      conn =
        conn(
          :get,
          "/ds/#{module_name}/increment?datastar=" <> URI.encode_www_form(~s({"count":10}))
        )
        |> Map.put(:path_params, %{"module" => module_name, "event" => "increment"})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
      assert result.status == 200
    end

    test "reads signals from POST request body", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestChatHandler)

      conn =
        conn(:post, "/ds/#{module_name}/send_message")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "send_message"})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"message" => "Hello world"})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
      assert result.status == 200
    end

    test "handles different events on same handler", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      # Test increment
      conn1 =
        conn(:post, "/ds/#{module_name}/increment")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "increment"})
        |> Map.put(:body_params, %{"count" => 0})

      result1 = Dispatch.call(conn1, opts)
      assert result1.state == :chunked

      # Test decrement
      conn2 =
        conn(:post, "/ds/#{module_name}/decrement")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "decrement"})
        |> Map.put(:body_params, %{"count" => 5})

      result2 = Dispatch.call(conn2, opts)
      assert result2.state == :chunked

      # Test reset
      conn3 =
        conn(:post, "/ds/#{module_name}/reset")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "reset"})
        |> Map.put(:body_params, %{"count" => 42})

      result3 = Dispatch.call(conn3, opts)
      assert result3.state == :chunked
    end

    test "returns 404 for unknown module", %{opts: opts} do
      conn =
        conn(:post, "/ds/unknown-module/increment")
        |> Map.put(:path_params, %{"module" => "unknown-module", "event" => "increment"})

      result = Dispatch.call(conn, opts)

      assert result.status == 404
      assert result.state == :sent
      assert result.resp_body == "Not found"
    end

    test "returns 404 for module not in allowed list", %{opts: opts} do
      # Create a module that exists but wasn't registered
      defmodule UnregisteredHandler do
        def handle_event(conn, _event, _signals), do: conn
      end

      module_name = Dstar.Actions.encode_module(UnregisteredHandler)

      conn =
        conn(:post, "/ds/#{module_name}/test")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "test"})

      result = Dispatch.call(conn, opts)

      assert result.status == 404
      assert result.resp_body == "Not found"
    end

    test "fetches query params before reading signals", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      conn =
        conn(
          :get,
          "/ds/#{module_name}/increment?datastar=" <> URI.encode_www_form(~s({"count":7}))
        )
        |> Map.put(:path_params, %{"module" => module_name, "event" => "increment"})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
      # Verify query_params were fetched
      assert is_map(result.query_params)
    end

    test "reads module and event from params fallback", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      # When path_params are empty, should try regular params
      conn =
        conn(:post, "/ds")
        |> Map.put(:path_params, %{})
        |> Map.put(:params, %{"module" => module_name, "event" => "increment"})
        |> Map.put(:body_params, %{"count" => 1})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
    end

    test "passes empty signals when no signals present", %{opts: opts} do
      module_name = Dstar.Actions.encode_module(TestCounterHandler)

      conn =
        conn(:post, "/ds/#{module_name}/reset")
        |> Map.put(:path_params, %{"module" => module_name, "event" => "reset"})
        |> Map.put(:body_params, %{})

      result = Dispatch.call(conn, opts)

      assert result.state == :chunked
    end
  end
end
