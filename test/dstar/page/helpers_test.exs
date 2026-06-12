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
               "@post(location.pathname.replace(/\\/+$/, '') + '/_event/increment')"
    end

    test "supports event names with interpolated ids" do
      assert event("toggle_item:123") ==
               "@post(location.pathname.replace(/\\/+$/, '') + '/_event/toggle_item:123')"
    end

    test "supports verb override" do
      assert event("remove", verb: :delete) ==
               "@delete(location.pathname.replace(/\\/+$/, '') + '/_event/remove')"
    end

    test "raises on unknown verb" do
      assert_raise ArgumentError, fn -> event("x", verb: :head) end
    end

    test "appends raw options object" do
      assert event("save", opts: "{retryMaxCount: 5}") ==
               "@post(location.pathname.replace(/\\/+$/, '') + '/_event/save', {retryMaxCount: 5})"
    end

    test "raises on event name containing a single quote" do
      assert_raise ArgumentError, fn -> event("bad'name") end
    end

    test "raises on event name containing a slash" do
      assert_raise ArgumentError, fn -> event("bad/name") end
    end
  end

  describe "connect/0,1" do
    test "builds the stream connect expression" do
      assert connect() == "@post(location.pathname, {retryMaxCount: Infinity})"
    end

    test "allows overriding the options object" do
      assert connect(opts: "{retryMaxCount: 3}") ==
               "@post(location.pathname, {retryMaxCount: 3})"
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
end
