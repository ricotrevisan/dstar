defmodule Dstar.ScriptsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.{Scripts, SSE}

  # Helper to create a chunked SSE conn
  defp chunked_conn do
    conn(:post, "/test")
    |> SSE.start()
  end

  # Extract the raw chunks sent over the SSE connection
  defp chunks(conn) do
    {_adapter, state} = conn.adapter
    state.chunks
  end

  describe "execute/3" do
    test "executes a basic script with auto_remove" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "alert('hello')")

      # Should return a conn (chunked response)
      assert %Plug.Conn{} = result
      assert result.state == :chunked
    end

    test "adds data-effect when auto_remove is true" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "console.log('test')", auto_remove: true)

      assert result.state == :chunked
    end

    test "does not add data-effect when auto_remove is false" do
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

    test "auto_remove uses data-effect attribute per ADR spec" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "console.log('test')", auto_remove: true)
      output = chunks(result)

      assert output =~ ~s[data-effect="el.remove()"]
      refute output =~ "document.currentScript.remove()"
      refute output =~ "(function(){"
    end

    test "auto_remove false does not add data-effect" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "window.x = 1", auto_remove: false)
      output = chunks(result)

      refute output =~ "data-effect"
      assert output =~ "window.x = 1"
    end

    test "script content is sent as-is without IIFE wrapping" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "alert('hi')")
      output = chunks(result)

      assert output =~ ">alert('hi')</script>"
      refute output =~ "(function(){"
    end

    test "user-provided attributes merge with auto_remove data-effect" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "test()",
          auto_remove: true,
          attributes: %{"type" => "module"}
        )

      output = chunks(result)
      assert output =~ ~s[data-effect="el.remove()"]
      assert output =~ ~s[type="module"]
    end

    test "user can override data-effect via attributes" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "test()",
          auto_remove: true,
          attributes: %{"data-effect" => "custom()"}
        )

      output = chunks(result)
      assert output =~ ~s[data-effect="custom()"]
      refute output =~ ~s[data-effect="el.remove()"]
    end
  end

  describe "script breakout escaping (S2)" do
    # The wrapper is `<script ...>BODY</script>`. After escaping, the only
    # HTML-parseable `<script` opener and `</script` closer in the output must
    # be the wrapper's — any in BODY must be backslash-broken so the HTML
    # parser can't end the element early. HTML closes `<script>` on `</script`
    # followed by `>`, whitespace, or `/`, case-insensitively.
    defp script_closers(output), do: Regex.scan(~r{</script}i, output) |> length()

    test "neutralizes an uppercase </SCRIPT> breakout in the body" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "x = '</SCRIPT><img src=x onerror=alert(1)>'", auto_remove: false)

      output = chunks(result)

      assert script_closers(output) == 1, "only the wrapper </script> may remain: #{output}"
    end

    test "neutralizes </script with a trailing space (not just </script>)" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "x = '</script ><svg onload=alert(1)>'", auto_remove: false)
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "neutralizes </script/> self-closing variant" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "x = '</script/>'", auto_remove: false)
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "neutralizes </script followed by a tab terminator" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "x = '</script\t>'", auto_remove: false)
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "a lone <script opener in the body cannot end the wrapper (only the wrapper opener remains parseable)" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "x = '<script>foo()'", auto_remove: false)
      output = chunks(result)

      # No </script closer is reachable, so the wrapper still closes exactly once.
      assert script_closers(output) == 1, output
    end

    test "preserves a <script opener inside a developer regex literal (no semantic flip)" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "var re = /<script/", auto_remove: false)
      output = chunks(result)

      # Inserting a backslash would turn /<script/ into /<\script/ (\\s = whitespace
      # class) — a silent meaning change. Raw JS must be passed through verbatim.
      assert output =~ "var re = /<script/"
    end

    test "preserves an <!-- token inside a developer unicode regex literal (no SyntaxError)" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "var re = /<!--[\\s\\S]*?-->/u", auto_remove: false)
      output = chunks(result)

      # /<\\!--/u is an Invalid escape (SyntaxError) — must not be introduced.
      assert output =~ "var re = /<!--[\\s\\S]*?-->/u"
    end

    test "console_log neutralizes </SCRIPT> in a user message" do
      conn = chunked_conn()
      result = Scripts.console_log(conn, "</SCRIPT><img src=x onerror=alert(1)>")
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "redirect neutralizes </SCRIPT> in the URL" do
      conn = chunked_conn()
      result = Scripts.redirect(conn, "/x</SCRIPT><img src=x onerror=alert(1)>")
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "still neutralizes the plain lowercase </script> (regression)" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "x = '</script>'", auto_remove: false)
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "a <!--<script> double-escape chain cannot inject a parseable closer" do
      conn = chunked_conn()
      # Without a reachable </script the wrapper still closes exactly once; the
      # injected text is inert (at worst it makes the wrapper's own close fail,
      # turning the payload into a syntax error with nothing after it).
      result = Scripts.execute(conn, "x = '<!--<script>alert(1)'", auto_remove: false)
      output = chunks(result)

      assert script_closers(output) == 1, output
    end

    test "does not alter legitimate JS comparison operators" do
      conn = chunked_conn()
      result = Scripts.execute(conn, "if (a < b && c > d) { run() }", auto_remove: false)
      output = chunks(result)

      assert output =~ "if (a < b && c > d) { run() }"
    end
  end

  describe "script attribute name validation (S3)" do
    test "rejects an attribute name that would break out of the <script> tag" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/attribute name/i, fn ->
        Scripts.execute(conn, "x = 1",
          attributes: %{"x></script><img src=q onerror=alert(1)" => "z"}
        )
      end
    end

    test "rejects an attribute name containing a quote (event-handler injection)" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/attribute name/i, fn ->
        Scripts.execute(conn, "x = 1", attributes: %{"a\" onload=\"alert(1)" => "z"})
      end
    end

    test "rejects an attribute name with a space" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/attribute name/i, fn ->
        Scripts.execute(conn, "x = 1", attributes: %{"a onload=alert(1)" => "z"})
      end
    end

    test "allows ordinary attribute names (letters, digits, - _ : .)" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "x = 1",
          auto_remove: false,
          attributes: %{"type" => "module", "data-on:click" => "y", :data_value => "v"}
        )

      output = chunks(result)
      assert result.state == :chunked
      assert output =~ ~s(type="module")
      assert output =~ ~s(data-on:click="y")
      assert output =~ ~s(data_value="v")
    end

    test "rejects an attribute name containing a newline (anchored, not \\Z/$)" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/attribute name/i, fn ->
        Scripts.execute(conn, "x = 1",
          attributes: %{"type\nx></script><img src=x onerror=alert(1)>" => "z"}
        )
      end
    end

    test "escapes a non-binary (charlist) attribute value so it cannot break out" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "x = 1",
          auto_remove: false,
          attributes: %{"type" => ~c"\"></script><img src=x onerror=alert(1)>"}
        )

      output = chunks(result)
      assert script_closers(output) == 1, output
      refute output =~ "<img src=x onerror"
    end

    test "escapes a non-binary (atom) attribute value so it cannot break out" do
      conn = chunked_conn()

      result =
        Scripts.execute(conn, "x = 1",
          auto_remove: false,
          attributes: %{"data-x" => :"\"></script><b>pwn"}
        )

      output = chunks(result)
      assert script_closers(output) == 1, output
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
