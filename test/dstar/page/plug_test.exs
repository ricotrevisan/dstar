defmodule Dstar.Page.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  alias Dstar.Page.Plug, as: PagePlug

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, params) do
      assign(conn, count: String.to_integer(params["start"] || "0"))
    end

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>
        <button data-on:click={event("increment")}>+1</button>
      </div>
      """
    end

    def handle_event(conn, "increment", signals) do
      count = (signals["count"] || 0) + 1

      conn
      |> patch_signals(%{count: count})
      |> patch(&history/1, value: count)
    end

    defp history(assigns) do
      ~H"""
      <span id="history">Last: {@value}</span>
      """
    end
  end

  defmodule RedirectPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> Plug.Conn.put_resp_header("location", "/login")
      |> Plug.Conn.send_resp(302, "")
    end

    def render(assigns), do: ~H'<div id="never">never rendered</div>'
  end

  defmodule BarePage do
    use Dstar.Page

    def render(assigns), do: ~H'<div id="bare">bare</div>'
  end

  defmodule HaltedPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> Plug.Conn.send_resp(401, "unauthorized")
      |> Plug.Conn.halt()
    end

    def render(assigns), do: ~H'<div id="never-halted">never rendered</div>'
  end

  defmodule StreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="s">stream</div>'

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:connected, self()})
      conn
    end

    def handle_info({:tick, n}, conn), do: patch_signals(conn, %{tick: n})
    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  defmodule KeyedStreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="k">keyed</div>'

    def stream_key(_conn), do: :test_scope

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:keyed_connected, self()})
      conn
    end

    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  describe "event action (POST _event/:event)" do
    defp event_conn(event, signals) do
      conn(:post, "/counter/_event/#{event}")
      |> Map.put(:path_params, %{"event" => event})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, signals)
    end

    test "starts SSE and dispatches to handle_event with signals" do
      conn = event_conn("increment", %{"count" => 2})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))

      assert conn.state == :chunked
      assert conn.status == 200
      assert_patched_signals(conn, %{count: 3})
      assert_patched_element(conn, "#history")
    end

    test "handlers never call Dstar.start themselves" do
      # CounterPage.handle_event has no Dstar.start — reaching :chunked
      # proves the plug started SSE.
      conn = event_conn("increment", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      assert conn.state == :chunked
    end

    test "with debug_errors, a crash is relayed to the browser console and re-raised" do
      Application.put_env(:dstar, :debug_errors, true)
      on_exit(fn -> Application.delete_env(:dstar, :debug_errors) end)

      conn = event_conn("explode", %{})

      assert_raise FunctionClauseError, fn ->
        PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      end
    end
  end

  describe "stream action (POST)" do
    test "404s when the page has no handle_connect" do
      conn = PagePlug.call(conn(:post, "/bare"), PagePlug.init({:stream, BarePage}))
      assert conn.status == 404
    end

    test "connects, dispatches handle_info, tolerates strays, halts on demand" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/stream"), PagePlug.init({:stream, StreamPage}))
        end)

      assert_receive {:connected, stream_pid}, 1_000

      send(stream_pid, {:tick, 7})
      send(stream_pid, :unmatched_stray_message)
      send(stream_pid, {:tick, 8})
      send(stream_pid, :halt_now)

      conn = Task.await(task, 2_000)

      assert conn.state == :chunked
      assert_patched_signals(conn, %{tick: 8})
      # The stray message did not kill the loop: tick 8 arrived after it.
    end

    test "opens via start_stream when stream_key/1 is defined" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/keyed"), PagePlug.init({:stream, KeyedStreamPage}))
        end)

      assert_receive {:keyed_connected, stream_pid}, 1_000
      send(stream_pid, :halt_now)

      conn = Task.await(task, 2_000)
      assert conn.state == :chunked
    end
  end

  describe "page action (GET)" do
    test "mounts and renders HTML 200" do
      conn = conn(:get, "/counter?start=5")
      conn = PagePlug.call(conn, PagePlug.init({:page, CounterPage}))

      assert conn.status == 200
      assert conn.state == :sent

      assert {"content-type", "text/html" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert conn.resp_body =~ "data-signals:count=\"5\""
    end

    test "works without a mount callback" do
      conn = PagePlug.call(conn(:get, "/bare"), PagePlug.init({:page, BarePage}))
      assert conn.status == 200
      assert conn.resp_body =~ "bare"
    end

    test "skips render when mount already sent a response" do
      conn = PagePlug.call(conn(:get, "/r"), PagePlug.init({:page, RedirectPage}))
      assert conn.status == 302
      refute conn.resp_body =~ "never rendered"
    end

    test "skips render when mount halts after sending (auth pattern)" do
      conn = PagePlug.call(conn(:get, "/h"), PagePlug.init({:page, HaltedPage}))
      assert conn.status == 401
      assert conn.halted
      refute conn.resp_body =~ "never rendered"
    end
  end
end
