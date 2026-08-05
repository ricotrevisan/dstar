defmodule Dstar.SSETest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.SSE

  # Raw SSE bytes accumulated on a chunked test conn.
  defp sent_frame(conn) do
    {_adapter, state} = conn.adapter
    state.chunks
  end

  # True if a blank line appears before the terminating "\n\n" — i.e. a value
  # broke out of its field and would dispatch a forged event. EventSource
  # splits on CR, LF, or CRLF (WHATWG spec).
  defp forged_dispatch?(frame) do
    frame
    |> String.replace_suffix("\n\n", "")
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.any?(&(&1 == ""))
  end

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

    test "splits a data value containing CR/LF into separate data lines (S1)" do
      # A data: field cannot contain a line terminator; an embedded CR, LF,
      # or CRLF must start a new data: line so it cannot inject a blank line
      # or a forged field into the stream.
      result = SSE.format_event("e", ["a\rb\nc\r\nd"])

      refute result =~ "\r"
      assert result == "event: e\ndata: a\ndata: b\ndata: c\ndata: d\n\n"
    end

    test "a CR-laden data value cannot inject a blank line (S1)" do
      result = SSE.format_event("e", ["x\r\revent: forged"])

      refute result =~ "\r"
      # Strip the terminating blank line; nothing else may be blank.
      refute result
             |> String.replace_suffix("\n\n", "")
             |> String.split(["\r\n", "\r", "\n"])
             |> Enum.any?(&(&1 == ""))
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

  describe "control-field frame injection (S1)" do
    test "event_id cannot inject a forged frame" do
      conn = conn(:post, "/t") |> SSE.start()

      conn =
        SSE.send_event!(conn, "evt", ["data"],
          event_id: "1\r\revent: datastar-patch-signals\rdata: signals {\"isAdmin\":true}"
        )

      frame = sent_frame(conn)
      refute frame =~ "\r"
      refute forged_dispatch?(frame)
    end

    test "retry cannot inject a forged frame" do
      conn = conn(:post, "/t") |> SSE.start()
      conn = SSE.send_event!(conn, "evt", ["data"], retry: "5000\r\revent: forged")

      frame = sent_frame(conn)
      refute frame =~ "\r"
      refute forged_dispatch?(frame)
    end

    test "format_event strips line breaks from the event type" do
      result = SSE.format_event("evt\r\revent: forged", ["data"])

      refute result =~ "\r"
      refute forged_dispatch?(result)
    end

    test "send_event strips line breaks from the event type" do
      conn = conn(:post, "/t") |> SSE.start()
      conn = SSE.send_event!(conn, "evt\r\revent: forged", ["data"])

      frame = sent_frame(conn)
      refute frame =~ "\r"
      refute forged_dispatch?(frame)
    end
  end

  describe "send_event/4" do
    # Per the Datastar SDK ADR, `retry:` is emitted only when it differs from
    # the SDK default of 1000. The official Go golden suite asserts this.
    test "omits retry when it equals the Datastar default of 1000" do
      conn = conn(:post, "/test") |> SSE.start()

      {:ok, result} = SSE.send_event(conn, "test-event", ["data"], retry: 1000)
      assert result.resp_body == "event: test-event\ndata: data\n\n"
    end

    # Documents the known consequence of the rule above: EventSource persists
    # the reconnection time, so an elevated retry cannot be lowered back to
    # the default — the field is omitted rather than re-sent.
    test "retry: 1000 does not reset a previously elevated retry" do
      conn = conn(:post, "/test") |> SSE.start()

      {:ok, conn} = SSE.send_event(conn, "a", ["x"], retry: 5000)
      {:ok, result} = SSE.send_event(conn, "b", ["y"], retry: 1000)

      assert result.resp_body ==
               "event: a\nretry: 5000\ndata: x\n\n" <> "event: b\ndata: y\n\n"
    end

    test "omits retry when none is given" do
      conn = conn(:post, "/test") |> SSE.start()

      {:ok, result} = SSE.send_event(conn, "test-event", ["data"])
      refute result.resp_body =~ "retry:"
    end

    test "includes retry when set to non-default value" do
      conn = conn(:post, "/test") |> SSE.start()

      {:ok, result} = SSE.send_event(conn, "test-event", ["data"], retry: 5000)
      assert result.resp_body == "event: test-event\nretry: 5000\ndata: data\n\n"
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
