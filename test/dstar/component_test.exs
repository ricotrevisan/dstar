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
    assert html =~ "/#{encoded}/change_title:abc"
  end

  test "event/2 supports verb override" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)

    assert DetailDrawer.event("remove", verb: :delete) ==
             "@delete((document.body.dataset.dsBase || '/ds').replace(/\\/+$/, '') + '/#{encoded}/remove')"
  end

  test "event/2 passes a raw JS opts string through" do
    encoded = Dstar.Actions.encode_module(DetailDrawer)

    assert DetailDrawer.event("save", opts: "{retryMaxCount: 5}") ==
             "@post((document.body.dataset.dsBase || '/ds').replace(/\\/+$/, '') + '/#{encoded}/save', {retryMaxCount: 5})"
  end

  test "event/2 raises on names containing a quote or slash" do
    assert_raise ArgumentError, fn -> DetailDrawer.event("bad'name") end
    assert_raise ArgumentError, fn -> DetailDrawer.event("bad/name") end
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
