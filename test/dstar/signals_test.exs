defmodule Dstar.SignalsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.{Signals, SSE}

  # Helper to create a chunked SSE conn
  defp chunked_conn do
    conn(:post, "/test")
    |> SSE.start()
  end

  describe "frame safety (S1)" do
    test "carriage returns in signal values stay JSON-escaped and never reach the wire" do
      frame = Signals.format_patch(%{name: "a\rb\nc"})

      # Jason escapes control chars, so no raw CR/LF can break the SSE frame.
      refute frame =~ "\r"

      blank_before_terminator? =
        frame
        |> String.replace_suffix("\n\n", "")
        |> String.split(["\r\n", "\r", "\n"])
        |> Enum.any?(&(&1 == ""))

      refute blank_before_terminator?
    end
  end

  describe "read/1" do
    test "reads signals from GET query params" do
      conn = %Plug.Conn{
        method: "GET",
        query_params: %{"datastar" => ~s({"count":42})}
      }

      assert Signals.read(conn) == %{"count" => 42}
    end

    test "returns empty map when no datastar param on GET" do
      conn = %Plug.Conn{method: "GET", query_params: %{}}
      assert Signals.read(conn) == %{}
    end

    test "reads signals from DELETE query params" do
      conn = %Plug.Conn{
        method: "DELETE",
        query_params: %{"datastar" => ~s({"id":7})}
      }

      assert Signals.read(conn) == %{"id" => 7}
    end

    test "returns empty map when no datastar param on DELETE" do
      conn = %Plug.Conn{method: "DELETE", query_params: %{}}
      assert Signals.read(conn) == %{}
    end

    test "reads signals from POST body params" do
      conn = %Plug.Conn{
        method: "POST",
        body_params: %{"count" => 10, "name" => "test"}
      }

      assert Signals.read(conn) == %{"count" => 10, "name" => "test"}
    end

    test "returns empty map for empty body" do
      conn = %Plug.Conn{method: "POST", body_params: %{}}
      assert Signals.read(conn) == %{}
    end
  end

  describe "format_patch/2" do
    test "formats a basic signal patch" do
      result = Signals.format_patch(%{count: 42})

      assert result ==
               "event: datastar-patch-signals\ndata: signals {\"count\":42}\n\n"
    end

    test "formats with only_if_missing" do
      result = Signals.format_patch(%{count: 0}, only_if_missing: true)
      assert result =~ "onlyIfMissing true"
      assert result =~ "signals {\"count\":0}"
    end
  end

  describe "remove_signals/3" do
    test "removes a single top-level signal" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "count")

      assert result.state == :chunked
    end

    test "removes a nested signal with dot notation" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "user.profile.theme")

      assert result.state == :chunked
    end

    test "removes multiple signals with shared prefix" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, ["user.name", "user.email"])

      assert result.state == :chunked
    end

    test "passes through options" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "count", event_id: "remove-1")

      assert result.state == :chunked
    end

    test "raises on empty path" do
      conn = chunked_conn()

      assert_raise ArgumentError, "Signal path cannot be empty", fn ->
        Signals.remove_signals(conn, "")
      end
    end

    test "raises on path with leading dot" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot start with a dot/, fn ->
        Signals.remove_signals(conn, ".user")
      end
    end

    test "raises on path with trailing dot" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot end with a dot/, fn ->
        Signals.remove_signals(conn, "user.")
      end
    end

    test "raises on path with consecutive dots" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot contain consecutive dots/, fn ->
        Signals.remove_signals(conn, "user..profile")
      end
    end
  end

  describe "format_remove/2" do
    test "formats removal of a single signal" do
      result = Signals.format_remove("count")

      assert result =~ "\"count\":null"
    end

    test "formats removal of nested signal" do
      result = Signals.format_remove("user.profile")

      assert result =~ "\"user\""
      assert result =~ "\"profile\":null"
    end

    test "formats removal of multiple signals with shared prefix" do
      result = Signals.format_remove(["user.name", "user.email"])

      assert result =~ "\"name\":null"
      assert result =~ "\"email\":null"
    end

    test "formats with only_if_missing option" do
      result = Signals.format_remove("count", only_if_missing: true)

      assert result =~ "onlyIfMissing true"
      assert result =~ "\"count\":null"
    end

    test "raises on invalid path" do
      assert_raise ArgumentError, "Signal path cannot be empty", fn ->
        Signals.format_remove("")
      end
    end
  end
end
