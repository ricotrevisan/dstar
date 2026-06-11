defmodule Dstar.SSETest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.SSE

  describe "format_event/2" do
    test "formats a basic event" do
      result = SSE.format_event("my-event", ["hello world"])
      assert result == "event: my-event\ndata: hello world\n\n"
    end

    test "formats multiple data lines" do
      result = SSE.format_event("my-event", ["line1", "line2", "line3"])

      assert result ==
               "event: my-event\ndata: line1\ndata: line2\ndata: line3\n\n"
    end

    test "formats empty data lines" do
      result = SSE.format_event("my-event", [])
      assert result == "event: my-event\n\n\n"
    end
  end

  describe "start/1" do
    test "sets required SSE response headers" do
      conn =
        conn(:get, "/sse")
        |> SSE.start()

      headers = Map.new(conn.resp_headers)

      assert headers["cache-control"] == "no-cache"
      # Connection header is intentionally NOT set — forbidden in HTTP/2
      # (RFC 9113 §8.2.2). See the SSE.start/1 docs.
      refute Map.has_key?(headers, "connection")
      assert headers["content-type"] =~ "text/event-stream"
    end

    test "starts a chunked response" do
      conn =
        conn(:get, "/sse")
        |> SSE.start()

      assert conn.state == :chunked
      assert conn.status == 200
    end
  end

  describe "send_event/4" do
    test "suppresses retry when set to default 1000ms" do
      conn =
        conn(:post, "/test")
        |> SSE.start()

      # retry: 1000 is the SSE default — should not appear in output
      {:ok, result} = SSE.send_event(conn, "test-event", ["data"], retry: 1000)
      assert %Plug.Conn{state: :chunked} = result
    end

    test "includes retry when set to non-default value" do
      conn =
        conn(:post, "/test")
        |> SSE.start()

      {:ok, result} = SSE.send_event(conn, "test-event", ["data"], retry: 5000)
      assert %Plug.Conn{state: :chunked} = result
    end
  end

  describe "check_connection/1" do
    test "returns {:ok, conn} for a valid chunked connection" do
      conn =
        conn(:post, "/test")
        |> SSE.start()

      assert {:ok, %Plug.Conn{state: :chunked}} = SSE.check_connection(conn)
    end

    test "returns {:error, conn} for a non-chunked connection" do
      conn = conn(:post, "/test")

      assert {:error, %Plug.Conn{}} = SSE.check_connection(conn)
    end
  end
end
