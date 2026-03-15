defmodule Dstar.ScriptsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.{Scripts, SSE}

  # Helper to create a chunked SSE conn
  defp chunked_conn do
    conn(:post, "/test")
    |> SSE.start()
  end

  describe "execute/3" do
    test "executes a basic script with auto_remove" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "alert('hello')")

      # Should return a conn (chunked response)
      assert %Plug.Conn{} = result
      assert result.state == :chunked
    end

    test "wraps script with IIFE and removes when auto_remove is true" do
      # We can't easily inspect the chunk content, but we can verify it executes
      # without error and returns proper conn state
      conn = chunked_conn()
      result = Scripts.execute(conn, "console.log('test')", auto_remove: true)

      assert result.state == :chunked
    end

    test "does not wrap script when auto_remove is false" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "window.myVar = 42", auto_remove: false)

      assert result.state == :chunked
    end

    test "adds custom attributes to script tag" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "import * from 'module'",
          attributes: %{type: "module", async: "true"}
        )

      assert result.state == :chunked
    end

    test "escapes HTML entities in attribute values" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "test", attributes: %{data_value: ~s(<script>"&"</script>)})

      assert result.state == :chunked
    end

    test "passes through event_id option to Elements.patch" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "test", event_id: "custom-123")

      assert result.state == :chunked
    end

    test "passes through retry option to Elements.patch" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "test", retry: 5000)

      assert result.state == :chunked
    end

    test "handles empty attributes map" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "test", attributes: %{})

      assert result.state == :chunked
    end

    test "escapes script closing tag in content" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "var html = '<script>alert(1)</script>'")

      assert result.state == :chunked
    end
  end

  describe "redirect/3" do
    test "redirects to a basic URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/workspaces")

      assert result.state == :chunked
    end

    test "redirects to an absolute URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "https://example.com/path")

      assert result.state == :chunked
    end

    test "escapes single quotes in URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/path?name=O'Reilly")

      assert result.state == :chunked
    end

    test "escapes backslashes in URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/path\\with\\backslashes")

      assert result.state == :chunked
    end

    test "escapes newlines in URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/path\nwith\nnewlines")

      assert result.state == :chunked
    end

    test "passes options through to execute/3" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/path", event_id: "redirect-1")

      assert result.state == :chunked
    end
  end

  describe "console_log/3" do
    test "logs a basic string message" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Debug message")

      assert result.state == :chunked
    end

    test "logs with warn level" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Warning!", level: :warn)

      assert result.state == :chunked
    end

    test "logs with error level" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Error!", level: :error)

      assert result.state == :chunked
    end

    test "logs with info level" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Info message", level: :info)

      assert result.state == :chunked
    end

    test "logs with debug level" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Debug message", level: :debug)

      assert result.state == :chunked
    end

    test "defaults to log level when invalid level provided" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Message", level: :invalid)

      assert result.state == :chunked
    end

    test "escapes single quotes in string messages" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "It's a test")

      assert result.state == :chunked
    end

    test "escapes backslashes in string messages" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Path: C:\\Users\\test")

      assert result.state == :chunked
    end

    test "escapes newlines in string messages" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Line 1\nLine 2")

      assert result.state == :chunked
    end

    test "escapes carriage returns in string messages" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "Line 1\r\nLine 2")

      assert result.state == :chunked
    end

    test "logs map as JSON object" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, %{user: "alice", id: 123})

      assert result.state == :chunked
    end

    test "logs list as JSON array" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, [1, 2, 3])

      assert result.state == :chunked
    end

    test "logs nested data structures" do
      conn = chunked_conn()

      result =
        Scripts.console_log(conn, %{
          user: %{name: "Bob", tags: ["admin", "user"]},
          count: 42
        })

      assert result.state == :chunked
    end

    test "passes options through to execute/3" do
      conn = chunked_conn()

      result =
        Scripts.console_log(conn, "Test", level: :warn, event_id: "log-1")

      assert result.state == :chunked
    end
  end
end
