defmodule AssigningComponent do
  use Phoenix.Component

  def banner(assigns) do
    assigns = assign(assigns, :label, "n=#{assigns.n}")

    ~H"""
    <div id="banner">{@label}</div>
    """
  end
end

defmodule Dstar.Page.HelpersTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Page.Helpers

  describe "event/1,2" do
    test "builds a page-local @post expression" do
      assert event("increment") ==
               ~S|@post(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/increment")|
    end

    test "supports event names with interpolated ids" do
      assert event("toggle_item:123") ==
               ~S|@post(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/toggle_item%3A123")|
    end

    test "supports verb override" do
      assert event("remove", verb: :delete) ==
               ~S|@delete(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/remove")|
    end

    test "raises on unknown verb" do
      assert_raise ArgumentError, fn -> event("x", verb: :head) end
    end

    test "appends raw options object" do
      assert event("save", opts: "{retryMaxCount: 5}") ==
               ~S|@post(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/save", {retryMaxCount: 5})|
    end

    test "rejects missing and dot event segments" do
      for value <- ["", ".", ".."] do
        assert_raise ArgumentError, ~r/path segment/, fn -> event(value) end
      end
    end

    test "requires raw options to be a trusted JavaScript string" do
      assert_raise ArgumentError, ~r/:opts must be a trusted JavaScript string/, fn ->
        event("save", opts: %{retryMaxCount: 5})
      end
    end

    test "encodes URL-significant event names as one literal segment" do
      assert event("bad'name/..\\?x#y%2f\r\n東京") ==
               ~S|@post(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/bad%27name%2F%2E%2E%5C%3Fx%23y%252f%0D%0A%E6%9D%B1%E4%BA%AC")|
    end
  end

  describe "connect/0,1" do
    test "builds the stream connect expression" do
      assert connect() ==
               ~S|@post(location.pathname.replace(/^\/+/, '/'), {retryMaxCount: Infinity})|
    end

    test "allows overriding the options object" do
      assert connect(opts: "{retryMaxCount: 3}") ==
               ~S|@post(location.pathname.replace(/^\/+/, '/'), {retryMaxCount: 3})|
    end

    test "requires an override to be a trusted JavaScript string" do
      assert_raise ArgumentError, ~r/:opts must be a trusted JavaScript string/, fn ->
        connect(opts: %{retryMaxCount: 3})
      end
    end

    test "include_search appends location.search" do
      assert connect(include_search: true) ==
               ~S|@post(location.pathname.replace(/^\/+/, '/') + location.search, {retryMaxCount: Infinity})|
    end
  end

  describe "patch/3,4" do
    defp history(assigns) do
      # A function component without ~H: returns safe HTML directly.
      {:safe, ~s(<span id="history">Last: #{assigns.value}</span>)}
    end

    test "renders a component fun into a patch-elements event" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, value: 3)

      assert conn.resp_body =~ "event: datastar-patch-elements"
      assert conn.resp_body =~ ~s(<span id="history">Last: 3</span>)
    end

    test "passes opts through to Dstar.Elements.patch" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, [value: 1], selector: "#slot", mode: :inner)

      assert conn.resp_body =~ "data: selector #slot"
      assert conn.resp_body =~ "data: mode inner"
    end

    test "accepts a map of assigns" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&history/1, %{value: 9})

      assert conn.resp_body =~ "Last: 9"
    end

    test "renders components that call assign/3 internally" do
      conn =
        conn(:post, "/")
        |> Dstar.SSE.start()
        |> patch(&AssigningComponent.banner/1, n: 7)

      assert conn.resp_body =~ "n=7"
    end
  end

  describe "on_nudge/2" do
    test "is available to templates alongside event/2" do
      assert on_nudge("posts", event("reload")) ==
               Dstar.Actions.on_nudge("posts", event("reload"))
    end
  end
end
