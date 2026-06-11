defmodule Dstar.TestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Test

  defp sse_conn do
    conn(:post, "/") |> Dstar.SSE.start()
  end

  describe "sse_events/1" do
    test "parses events out of a test conn body" do
      conn =
        sse_conn()
        |> Dstar.patch_signals(%{count: 1})
        |> Dstar.patch_elements(~s(<span id="x">hi</span>), [])

      assert [
               %{type: "datastar-patch-signals", data: [~s(signals {"count":1})]},
               %{type: "datastar-patch-elements", data: [~s(elements <span id="x">hi</span>)]}
             ] = sse_events(conn)
    end

    test "ignores comment-only keepalive chunks" do
      {:ok, conn} = Dstar.check_connection(sse_conn())
      assert sse_events(conn) == []
    end
  end

  describe "assert_patched_signals/2" do
    test "passes on a subset match across events" do
      conn =
        sse_conn()
        |> Dstar.patch_signals(%{count: 1})
        |> Dstar.patch_signals(%{name: "rico"})

      assert_patched_signals(conn, %{count: 1})
      assert_patched_signals(conn, %{count: 1, name: "rico"})
    end

    test "fails on a wrong value" do
      conn = sse_conn() |> Dstar.patch_signals(%{count: 1})

      assert_raise ExUnit.AssertionError, fn ->
        assert_patched_signals(conn, %{count: 2})
      end
    end

    test "deep-merges nested signal patches like the Datastar client" do
      conn =
        sse_conn()
        |> Dstar.patch_signals(%{user: %{name: "rico"}})
        |> Dstar.patch_signals(%{user: %{count: 5}})

      assert_patched_signals(conn, %{user: %{"name" => "rico", "count" => 5}})
    end
  end

  describe "assert_patched_element/2" do
    test "matches by explicit selector" do
      conn = sse_conn() |> Dstar.patch_elements("<li>x</li>", selector: "#items", mode: :append)
      assert_patched_element(conn, "#items")
    end

    test "matches by element id when no selector was sent" do
      conn = sse_conn() |> Dstar.patch_elements(~s(<span id="history">x</span>), [])
      assert_patched_element(conn, "#history")
    end

    test "fails when nothing matches" do
      conn = sse_conn() |> Dstar.patch_signals(%{a: 1})

      assert_raise ExUnit.AssertionError, fn ->
        assert_patched_element(conn, "#nope")
      end
    end

    test "raises ArgumentError for non-id targets" do
      assert_raise ArgumentError, fn ->
        assert_patched_element(sse_conn(), ".classname")
      end
    end
  end
end
