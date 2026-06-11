defmodule Dstar.PageTest do
  use ExUnit.Case, async: true

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> assign(count: 0)
      |> assign_new(:title, fn -> "Counter" end)
      |> update(:count, & &1)
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

  defmodule TunedPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="t">tuned</div>'
  end

  defp render_to_string(rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  test "render/1 produces HEEx with the page-local event helper" do
    html = render_to_string(CounterPage.render(%{count: 0}))
    assert html =~ "data-signals:count"

    assert html =~
             "@post(location.pathname.replace(/\\/+$/, &#39;&#39;) + &#39;/_event/increment&#39;)"
  end

  test "the assign shim works on conns inside mount" do
    conn = Plug.Test.conn(:get, "/") |> CounterPage.mount(%{})
    assert conn.assigns.count == 0
    assert conn.assigns.title == "Counter"
  end

  test "handle_event pipes conn helpers and patch" do
    conn =
      Plug.Test.conn(:post, "/")
      |> Dstar.SSE.start()
      |> CounterPage.handle_event("increment", %{"count" => 2})

    assert conn.resp_body =~ ~s(signals {"count":3})
    assert conn.resp_body =~ "Last: 3"
  end

  test "__dstar__(:idle_check) defaults to 30_000" do
    assert CounterPage.__dstar__(:idle_check) == 30_000
  end

  test "__dstar__(:idle_check) is overridable via use options" do
    assert TunedPage.__dstar__(:idle_check) == 50
  end
end
