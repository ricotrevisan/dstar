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
