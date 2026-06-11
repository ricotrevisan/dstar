defmodule Dstar.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, _params), do: assign(conn, count: 0)

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>counter</div>
      """
    end

    def handle_event(conn, "increment", signals) do
      patch_signals(conn, %{count: (signals["count"] || 0) + 1})
    end
  end

  defmodule Drawer do
    use Dstar.Component

    def handle_event(conn, "ping", _signals) do
      conn |> start() |> patch_signals(%{pong: true})
    end
  end

  defmodule TestRouter do
    use Phoenix.Router
    import Dstar.Router

    dstar("/counter", Dstar.RouterTest.CounterPage)
    dstar_components("/ds", [Dstar.RouterTest.Drawer])
  end

  defmodule ScopedRouter do
    use Phoenix.Router
    import Dstar.Router

    # Aliased scope: the page/component modules are written RELATIVE to the
    # scope alias (like controllers and live views), and the dispatcher
    # plugs must NOT get scope-prefixed. (`RouterTest.CounterPage` rather
    # than bare `CounterPage` because nested defmodules above register
    # lexical aliases that would pre-resolve the bare name — the standard
    # Phoenix scope-aliasing caveat applies.)
    scope "/app", Dstar do
      dstar("/counter", RouterTest.CounterPage)
      dstar_components("/ds", [RouterTest.Drawer])
    end
  end

  defp call(conn), do: TestRouter.call(conn, TestRouter.init([]))

  defp call_scoped(conn), do: ScopedRouter.call(conn, ScopedRouter.init([]))

  test "GET page route renders the page" do
    conn = call(conn(:get, "/counter"))
    assert conn.status == 200
    assert conn.resp_body =~ "counter"
  end

  test "POST event route dispatches handle_event" do
    conn =
      conn(:post, "/counter/_event/increment")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"count" => 1})
      |> call()

    assert conn.state == :chunked
    assert_patched_signals(conn, %{count: 2})
  end

  test "POST stream route 404s when page has no handle_connect" do
    conn = call(conn(:post, "/counter"))
    assert conn.status == 404
  end

  test "dstar_components wires the Dispatch plug" do
    encoded = Dstar.Actions.encode_module(Dstar.RouterTest.Drawer)

    conn =
      conn(:post, "/ds/#{encoded}/ping")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{})
      |> call()

    assert conn.state == :chunked
    assert_patched_signals(conn, %{pong: true})
  end

  describe "inside an aliased scope" do
    test "GET page route resolves the relative page alias and renders" do
      conn = call_scoped(conn(:get, "/app/counter"))
      assert conn.status == 200
      assert conn.resp_body =~ "counter"
    end

    test "POST event route dispatches without scope-prefixing the plug" do
      conn =
        conn(:post, "/app/counter/_event/increment")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"count" => 4})
        |> call_scoped()

      assert conn.state == :chunked
      assert_patched_signals(conn, %{count: 5})
    end

    test "dstar_components resolves relative component aliases" do
      encoded = Dstar.Actions.encode_module(Dstar.RouterTest.Drawer)

      conn =
        conn(:post, "/app/ds/#{encoded}/ping")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{})
        |> call_scoped()

      assert conn.state == :chunked
      assert_patched_signals(conn, %{pong: true})
    end
  end

  test "__event_path__ handles trailing slashes" do
    assert Dstar.Router.__event_path__("/counter") == "/counter/_event/:event"
    assert Dstar.Router.__event_path__("/counter/") == "/counter/_event/:event"
  end

  test "__dispatch_path__ handles trailing slashes" do
    assert Dstar.Router.__dispatch_path__("/ds") == "/ds/:module/:event"
    assert Dstar.Router.__dispatch_path__("/ds/") == "/ds/:module/:event"
  end
end
