defmodule Dstar.LiveCollectionsTest do
  @moduledoc """
  Acceptance test for the live-collections helpers: a page subscribed to a
  plain `Phoenix.PubSub` topic drives append/upsert/remove and a nudge through
  the real `Dstar.Page.Plug` receive loop. No Ash, no framework awareness.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Dstar.Test

  alias Dstar.Page.Plug, as: PagePlug

  @pubsub Dstar.LiveCollectionsTest.PubSub
  @topic "posts"

  defmodule FeedPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<ul id="posts"></ul>'

    def handle_connect(conn, _params) do
      Phoenix.PubSub.subscribe(Dstar.LiveCollectionsTest.PubSub, "posts")
      send(:dstar_live_collections_test, {:connected, self()})
      conn
    end

    # Fast path — plain feed.
    def handle_info({:created, id}, conn),
      do: append_elements(conn, ~s(<li id="post-#{id}">post #{id}</li>), "#posts")

    def handle_info({:updated, id}, conn),
      do: upsert_elements(conn, ~s(<li id="post-#{id}">post #{id} edited</li>))

    def handle_info({:deleted, id}, conn), do: remove_elements(conn, "#post-#{id}")

    # Default for filtered/sorted/paginated views.
    def handle_info(:changed, conn), do: nudge(conn, "posts")

    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    Process.register(self(), :dstar_live_collections_test)

    on_exit(fn ->
      try do
        Process.unregister(:dstar_live_collections_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp stream_conn do
    task =
      Task.async(fn ->
        PagePlug.call(conn(:post, "/feed"), PagePlug.init({:stream, FeedPage}))
      end)

    assert_receive {:connected, stream_pid}, 1_000
    {task, stream_pid}
  end

  defp finish({task, stream_pid}) do
    send(stream_pid, :halt_now)
    Task.await(task, 2_000)
  end

  test "a broadcast appends a row to the feed container" do
    stream = stream_conn()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:created, 1})
    conn = finish(stream)

    assert conn.resp_body =~
             "event: datastar-patch-elements\n" <>
               "data: selector #posts\n" <>
               "data: mode append\n" <>
               "data: elements <li id=\"post-1\">post 1</li>\n\n"
  end

  test "a broadcast upserts a row by id, with no selector" do
    stream = stream_conn()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:updated, 1})
    conn = finish(stream)

    assert conn.resp_body =~
             "event: datastar-patch-elements\n" <>
               "data: elements <li id=\"post-1\">post 1 edited</li>\n\n"

    refute conn.resp_body =~ "data: selector"
  end

  test "a broadcast removes a row by id" do
    stream = stream_conn()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:deleted, 1})
    conn = finish(stream)

    assert conn.resp_body =~
             "event: datastar-patch-elements\n" <>
               "data: selector #post-1\n" <>
               "data: mode remove\n\n"
  end

  test "a broadcast nudges, and repeated nudges carry changing values" do
    stream = stream_conn()
    Phoenix.PubSub.broadcast(@pubsub, @topic, :changed)
    Phoenix.PubSub.broadcast(@pubsub, @topic, :changed)
    conn = finish(stream)

    values =
      conn
      |> sse_events()
      |> Enum.filter(&(&1.type == "datastar-patch-signals"))
      |> Enum.flat_map(& &1.data)
      |> Enum.map(fn "signals " <> json -> get_in(Jason.decode!(json), ["nudges", "posts"]) end)

    assert [first, second] = values
    assert is_integer(first) and is_integer(second)
    assert first != second
  end

  test "the whole lifecycle rides one stream in order" do
    stream = stream_conn()

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:created, 1})
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:updated, 1})
    Phoenix.PubSub.broadcast(@pubsub, @topic, :changed)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:deleted, 1})

    conn = finish(stream)

    types = conn |> sse_events() |> Enum.map(& &1.type)

    assert types == [
             "datastar-patch-elements",
             "datastar-patch-elements",
             "datastar-patch-signals",
             "datastar-patch-elements"
           ]
  end
end
