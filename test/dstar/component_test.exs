defmodule Dstar.ComponentTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  defmodule DetailDrawer do
    use Dstar.Component

    def drawer(assigns) do
      ~H"""
      <div id="item-detail-drawer">
        <input data-on:change={event("change_title:#{@item.id}")} value={@item.title} />
      </div>
      """
    end

    def handle_event(conn, "change_title:" <> _id, signals) do
      conn
      |> start()
      |> patch_signals(%{saved: true, title: signals["title"]})
    end
  end

  test "event/2 targets the component's dispatch URL with the dsBase dataset" do
    html =
      DetailDrawer.drawer(%{item: %{id: "abc", title: "T"}})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    encoded = Dstar.Actions.encode_module(DetailDrawer)
    assert html =~ "document.body.dataset.dsBase"
    # default base lives in the JS fallback (HEEx-escaped quotes)
    assert html =~ "|| &#39;/ds&#39;"
    assert html =~ "/#{encoded}/change_title%3Aabc"
  end

  test "event/2 supports verb override" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)
    expression = DetailDrawer.event("remove", verb: :delete)

    assert String.starts_with?(expression, "@delete(")
    assert expression =~ ~s|+ "/#{encoded}/remove")|
  end

  test "event/2 passes a raw JS opts string through" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)
    expression = DetailDrawer.event("save", opts: "{retryMaxCount: 5}")

    assert String.starts_with?(expression, "@post(")
    assert expression =~ ~s|+ "/#{encoded}/save", {retryMaxCount: 5})|
  end

  test "event/2 rejects missing and dot event segments" do
    for value <- ["", ".", ".."] do
      assert_raise ArgumentError, ~r/path segment/, fn -> DetailDrawer.event(value) end
    end
  end

  test "event/2 encodes URL-significant names as one literal segment" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)
    expression = DetailDrawer.event("bad'name/..\\?x#y%2f\r\n東京")

    assert expression =~
             ~s|+ "/#{encoded}/bad%27name%2F%2E%2E%5C%3Fx%23y%252f%0D%0A%E6%9D%B1%E4%BA%AC")|
  end

  test "handle_event works through Dstar.Plugs.Dispatch" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)
    opts = Dstar.Plugs.Dispatch.init(modules: [DetailDrawer])

    conn =
      conn(:post, "/ds/#{encoded}/change_title:abc")
      |> Map.put(:path_params, %{"module" => encoded, "event" => "change_title:abc"})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, %{"title" => "New"})

    conn = Dstar.Plugs.Dispatch.call(conn, opts)
    assert conn.state == :chunked
    assert_patched_signals(conn, %{saved: true, title: "New"})
  end
end
