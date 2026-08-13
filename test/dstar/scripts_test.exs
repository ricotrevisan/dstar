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
    test "redirects to a path-absolute local URL" do
      output = assert_redirects("/workspaces")

      assert output =~ "setTimeout(function(){window.location.href="
    end

    test "allows query and fragment on a local path" do
      assert_redirects("/search?q=1#results")
    end

    test "allows a query-only reference on the current path" do
      assert_redirects("?x=1")
    end

    test "allows a fragment-only reference on the current path" do
      assert_redirects("#section")
    end

    test "allows query plus fragment without a path" do
      assert_redirects("?x=1#frag")
    end

    test "allows a same-origin absolute URL" do
      assert_redirects("http://www.example.com/path")
    end

    test "allows a same-origin URL with an explicit default port" do
      assert_redirects("http://www.example.com:80/path")
    end

    test "allows backslashes in the middle of a local path" do
      assert_redirects("/path\\with\\backslashes")
    end

    test "JSON-encodes quotes, backslashes, and CR/LF in the emitted JS" do
      url = "/path?name=O'Reilly\\ok"
      output = assert_redirects(url)

      # JSON double-quotes the value, so `'` is fine raw; a lone backslash
      # or line break must not appear unescaped inside the assignment.
      refute output =~ "href='/path"
      assert output =~ ~S|O'Reilly\\ok|
      refute output =~ "/path\n"
      refute output =~ "/path\r"
    end

    test "JSON-encodes CR/LF in a local path so they cannot break the JS string" do
      assert_redirects("/path\nwith\nnewlines\r")
    end

    test "escapes U+2028 and U+2029 in the emitted JS string" do
      url = "/path" <> <<0x2028::utf8, 0x2029::utf8>> <> "more"
      output = assert_redirects(url)

      refute String.contains?(output, <<0x2028::utf8>>)
      refute String.contains?(output, <<0x2029::utf8>>)
      assert output =~ "\\u2028"
      assert output =~ "\\u2029"
    end

    test "passes execute/3 options through" do
      result = Scripts.redirect(chunked_conn(), "/path", event_id: "redirect-1")

      assert chunks(result) =~ "id: redirect-1"
    end

    test "rejects javascript: destinations" do
      assert_rejected("javascript:alert(document.domain)")
    end

    test "rejects mixed-case JavaScript: destinations" do
      assert_rejected("JavaScript:alert(1)")
    end

    test "rejects data: and vbscript: destinations" do
      assert_rejected("data:text/html,x")
      assert_rejected("DATA:text/html,x")
      assert_rejected("vbscript:msgbox(1)")
    end

    test "rejects schemes hidden behind leading whitespace" do
      assert_rejected("  javascript:alert(1)")
      assert_rejected("  DATA:text/html,x")
    end

    test "rejects schemes hidden behind control and Unicode whitespace" do
      assert_rejected("\tjavascript:alert(1)")
      assert_rejected("java\tscript:alert(1)")
      assert_rejected("javascript\t:alert(1)")
      assert_rejected(<<0x00A0::utf8, "javascript:alert(1)">>)
      assert_rejected(<<0x2028::utf8, "javascript:alert(1)">>)
      assert_rejected(<<0xFEFF::utf8, "javascript:alert(1)">>)
    end

    test "rejects protocol-relative URLs" do
      assert_rejected("//evil.example")
      assert_rejected("//evil.example/phish")
    end

    test "rejects misleading userinfo/host forms" do
      assert_rejected("https://trusted.example@evil.example/")
      assert_rejected("https://trusted.example@evil.example/", external: true)
      assert_rejected("https://trusted.example@evil.example/", allow: ["trusted.example"])
    end

    test "rejects ordinary external HTTPS by default" do
      assert_rejected("https://evil.example")
      assert_rejected("https://example.com/path")
    end

    test "rejects a different scheme on the request host" do
      assert_rejected("https://www.example.com/path")
    end

    test "rejects a different port on the request host" do
      assert_rejected("http://www.example.com:4000/path")
    end

    test "rejects a slash-backslash path that browsers may treat as protocol-relative" do
      assert_rejected("/\\evil.example")
    end

    # WHATWG strips ASCII tab/LF/CR anywhere before parsing, so these
    # become `//evil.example` in the browser. Scheme-only checks on the
    # stripped form are not enough — the stripped parse must also fail
    # the protocol-relative / host check.
    test "rejects tab/LF/CR smuggled into a path-absolute URL that browsers treat as protocol-relative" do
      assert_rejected("/\n/evil.example")
      assert_rejected("/\t/evil.example")
      assert_rejected("/\r/evil.example")
      assert_rejected("/\n//evil.example")
    end

    test "a newline inside a local path that does not become protocol-relative is still allowed" do
      # "/\nevil" strips to "/evil" — same-origin path, not "//evil".
      assert_redirects("/path\nwith\nnewlines")
    end

    test "tab/LF/CR smuggling still cannot sneak past external: true" do
      assert_rejected("/\n/evil.example", external: true)
      assert_rejected("/\t/evil.example", allow: ["evil.example"])
    end

    test "rejects non-http(s) schemes" do
      assert_rejected("ftp://files.example/x")
      assert_rejected("file:///etc/passwd")
    end

    test "rejects relative paths that are not path-absolute" do
      assert_rejected("workspaces")
      assert_rejected("./foo")
    end

    test "allows off-origin http(s) with external: true" do
      assert_redirects("https://ok.example/docs", external: true)
      assert_redirects("http://ok.example/docs", external: true)
    end

    test "allows an allowlisted host and rejects a non-matching host" do
      assert_redirects("https://ok.example/docs", allow: ["ok.example"])
      assert_rejected("https://evil.example/docs", allow: ["ok.example"])
    end

    test "allow matches the parsed host exactly, not as a suffix" do
      assert_rejected("https://evil.ok.example/docs", allow: ["ok.example"])
    end

    test "allow is case-insensitive against the parsed host" do
      assert_redirects("HTTPS://OK.EXAMPLE/docs", allow: ["ok.example"])
    end

    test "external: true still rejects dangerous schemes and protocol-relative URLs" do
      assert_rejected("javascript:alert(1)", external: true)
      assert_rejected("//evil.example", external: true)
    end

    test "rejected destinations emit no SSE patch" do
      conn = chunked_conn()
      before = chunks(conn)

      assert_raise ArgumentError, ~r/unsafe redirect destination/, fn ->
        Scripts.redirect(conn, "javascript:alert(document.domain)")
      end

      assert chunks(conn) == before
      refute before =~ "datastar-patch-elements"
      refute chunks(conn) =~ "window.location"
    end

    test "raises a clear error before emitting when the destination is rejected" do
      conn = chunked_conn()

      exception =
        assert_raise ArgumentError, fn ->
          Scripts.redirect(conn, "https://evil.example")
        end

      assert exception.message =~ "unsafe redirect destination"
      assert exception.message =~ "external: true"
      refute chunks(conn) =~ "datastar-patch-elements"
    end
  end

  defp assert_redirects(url, opts \\ []) do
    result = Scripts.redirect(chunked_conn(), url, opts)
    output = chunks(result)
    encoded = encode_redirect_url(url)

    assert result.state == :chunked
    assert output =~ "window.location.href=#{encoded}"
    output
  end

  defp assert_rejected(url, opts \\ []) do
    conn = chunked_conn()
    before = chunks(conn)

    assert_raise ArgumentError, ~r/unsafe redirect destination/, fn ->
      Scripts.redirect(conn, url, opts)
    end

    assert chunks(conn) == before
    refute chunks(conn) =~ "datastar-patch-elements"
  end

  defp encode_redirect_url(url) do
    url
    |> Jason.encode!()
    |> String.replace(<<0x2028::utf8>>, "\\u2028")
    |> String.replace(<<0x2029::utf8>>, "\\u2029")
  end

  describe "console_log/3" do
    test "logs a basic string message" do
      result = Scripts.console_log(chunked_conn(), "Debug message")

      assert result.resp_body =~ "console.log('Debug message')"
    end

    for level <- ~w(log warn error info debug)a do
      test "logs with #{level} level" do
        result = Scripts.console_log(chunked_conn(), "Hi", level: unquote(level))

        assert result.resp_body =~ "console.#{unquote(level)}('Hi')"
      end
    end

    # A mistyped level used to fall through to :log, hiding the typo. Note
    # that :warning — Elixir's own Logger spelling — is one such typo.
    test "raises on an invalid level" do
      for bad <- [:invalid, :warning, "warn", nil] do
        assert_raise ArgumentError, ~r/invalid level/, fn ->
          Scripts.console_log(chunked_conn(), "Message", level: bad)
        end
      end
    end

    test "escapes single quotes in string messages" do
      result = Scripts.console_log(chunked_conn(), "It's a test")

      assert result.resp_body =~ ~S|console.log('It\'s a test')|
    end

    test "escapes backslashes in string messages" do
      result = Scripts.console_log(chunked_conn(), "Path: C:\\Users\\test")

      assert result.resp_body =~ ~S|console.log('Path: C:\\Users\\test')|
    end

    test "escapes newlines in string messages" do
      result = Scripts.console_log(chunked_conn(), "Line 1\nLine 2")

      assert result.resp_body =~ ~S|console.log('Line 1\nLine 2')|
      # The literal newline must not survive into the SSE frame.
      refute result.resp_body =~ "Line 1\nLine 2"
    end

    test "escapes carriage returns in string messages" do
      result = Scripts.console_log(chunked_conn(), "Line 1\r\nLine 2")

      assert result.resp_body =~ ~S|console.log('Line 1\r\nLine 2')|
      refute result.resp_body =~ "Line 1\r\nLine 2"
    end

    test "logs map as JSON object" do
      result = Scripts.console_log(chunked_conn(), %{user: "alice", id: 123})

      assert result.resp_body =~ ~S|console.log({"id":123,"user":"alice"})|
    end

    test "logs list as JSON array" do
      result = Scripts.console_log(chunked_conn(), [1, 2, 3])

      assert result.resp_body =~ "console.log([1,2,3])"
    end

    test "logs nested data structures" do
      result =
        Scripts.console_log(chunked_conn(), %{
          user: %{name: "Bob", tags: ["admin", "user"]},
          count: 42
        })

      assert result.resp_body =~
               ~S|console.log({"count":42,"user":{"name":"Bob","tags":["admin","user"]}})|
    end

    test "passes options through to execute/3" do
      result = Scripts.console_log(chunked_conn(), "Test", level: :warn, event_id: "log-1")

      assert result.resp_body =~ "id: log-1"
      assert result.resp_body =~ "console.warn('Test')"
    end
  end
end
