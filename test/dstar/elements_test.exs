defmodule Dstar.ElementsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.{Elements, SSE}

  # Helper to create a chunked SSE conn
  defp chunked_conn do
    conn(:post, "/test")
    |> SSE.start()
  end

  # An SSE frame ends with exactly one blank line (the "\n\n" terminator).
  # A blank line anywhere *before* that boundary would dispatch a forged
  # event, so its presence means a value broke out of its `data:` field.
  # The browser's EventSource splits on CR, LF, or CRLF (WHATWG spec), so
  # we split the same way.
  defp internal_blank_line?(frame) do
    frame
    |> String.replace_suffix("\n\n", "")
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.any?(&(&1 == ""))
  end

  describe "format_patch/2" do
    test "formats a basic element patch with selector" do
      result = Elements.format_patch("<span>42</span>", selector: "#count")

      assert result ==
               "event: datastar-patch-elements\n" <>
                 "data: selector #count\n" <>
                 "data: elements <span>42</span>\n\n"
    end

    test "formats element patch without selector (ID-based targeting)" do
      result = Elements.format_patch("<div id=\"feed\">New content</div>")

      assert result ==
               "event: datastar-patch-elements\n" <>
                 "data: elements <div id=\"feed\">New content</div>\n\n"

      refute result =~ "selector"
    end

    test "omits mode when default outer" do
      result = Elements.format_patch("<div>test</div>", selector: "#x")
      refute result =~ "mode"
    end

    test "formats with inner mode" do
      result = Elements.format_patch("<p>hello</p>", selector: ".box", mode: :inner)
      assert result =~ "mode inner"
      assert result =~ "selector .box"
    end

    test "formats with append mode" do
      result = Elements.format_patch("<li>item</li>", selector: "ul", mode: :append)
      assert result =~ "mode append"
    end

    test "formats with view transitions" do
      result =
        Elements.format_patch("<div>smooth</div>",
          selector: "#box",
          use_view_transitions: true
        )

      assert result =~ "useViewTransition true"
    end

    test "formats multiline HTML" do
      html = "<div>\n  <span>hello</span>\n</div>"
      result = Elements.format_patch(html, selector: "#target")
      assert result =~ "elements <div>"
      assert result =~ "elements   <span>hello</span>"
      assert result =~ "elements </div>"
    end

    test "does not raise when selector is omitted" do
      result = Elements.format_patch("<div id=\"x\">test</div>", [])
      assert result =~ "elements <div"
      refute result =~ "selector"
    end

    test "formats with svg namespace" do
      result =
        Elements.format_patch("<circle cx='50' cy='50' r='40'/>",
          selector: "#svg",
          namespace: :svg
        )

      assert result =~ "namespace svg"
    end

    test "formats with mathml namespace" do
      result =
        Elements.format_patch("<math><mi>x</mi></math>",
          selector: "#math",
          namespace: :mathml
        )

      assert result =~ "namespace mathml"
    end

    test "does not emit namespace line for default html namespace" do
      result =
        Elements.format_patch("<div>test</div>",
          selector: "#x",
          namespace: :html
        )

      refute result =~ "namespace"
    end

    test "does not emit namespace line when namespace not specified" do
      result = Elements.format_patch("<div>test</div>", selector: "#x")

      refute result =~ "namespace"
    end

    test "raises on invalid namespace" do
      assert_raise ArgumentError, ~r/Invalid namespace/, fn ->
        Elements.format_patch("<element/>", selector: "#x", namespace: :xml)
      end
    end

    test "raises when html is nil and mode is not :remove" do
      assert_raise ArgumentError, ~r/elements content is required/, fn ->
        Elements.format_patch(nil, selector: "#x", mode: :inner)
      end
    end

    test "allows nil html when mode is :remove" do
      result = Elements.format_patch(nil, selector: "#old", mode: :remove)
      assert result =~ "mode remove"
      assert result =~ "selector #old"
      refute result =~ "data: elements"
    end
  end

  describe "SSE frame injection via carriage returns (S1)" do
    test "a lone CR in element HTML cannot forge a second SSE event" do
      # Attacker-controlled content (e.g. a display name) carrying CRs that,
      # if passed through verbatim, would dispatch a forged patch-signals
      # event setting isAdmin=true on every viewer's client.
      name = "Bob\r\revent: datastar-patch-signals\rdata: signals {\"isAdmin\":true}\r\r"
      html = "<div id=\"card\">#{name}</div>"

      frame = Elements.format_patch(html, selector: "#card")

      # No raw CR may survive into the wire frame — it is a line terminator.
      refute frame =~ "\r"
      # No premature blank line, so the stream dispatches exactly one event.
      refute internal_blank_line?(frame)
      # The injected "event:" text must be neutralized into a data payload,
      # never a standalone SSE field.
      refute frame =~ "\ndata: signals {\"isAdmin\":true}"
    end

    test "a CR in the selector cannot forge a second SSE event" do
      frame =
        Elements.format_patch("<div>x</div>", selector: "#a\r\revent: datastar-patch-signals")

      refute frame =~ "\r"
      refute internal_blank_line?(frame)
    end

    test "CRLF multiline HTML renders one clean elements line per physical line" do
      html = "<div>\r\n  <span>hi</span>\r\n</div>"

      frame = Elements.format_patch(html, selector: "#t")

      refute frame =~ "\r"
      assert frame =~ "data: elements <div>\n"
      assert frame =~ "data: elements   <span>hi</span>\n"
      assert frame =~ "data: elements </div>\n"
    end

    test "lone-CR multiline HTML splits into separate elements lines" do
      html = "<p>one</p>\r<p>two</p>"

      frame = Elements.format_patch(html, selector: "#t")

      refute frame =~ "\r"
      assert frame =~ "data: elements <p>one</p>\n"
      assert frame =~ "data: elements <p>two</p>\n"
    end

    test "literal backslash-r text is not treated as a line break" do
      # The two characters "\\" and "r" (not a CR byte) must stay on one line.
      frame = Elements.format_patch("<p>a\\rb</p>", selector: "#t")

      assert frame =~ "data: elements <p>a\\rb</p>\n"
    end
  end

  describe "format_remove/2" do
    test "formats a basic element removal" do
      result = Elements.format_remove("#target")

      assert result ==
               "event: datastar-patch-elements\n" <>
                 "data: selector #target\n" <>
                 "data: mode remove\n\n"
    end

    test "formats removal with multiple selectors" do
      result = Elements.format_remove("#feed, #other")
      assert result =~ "mode remove"
      assert result =~ "selector #feed, #other"
      refute result =~ "data: elements"
    end
  end

  describe "remove/3" do
    test "sends mode remove and selector" do
      conn = chunked_conn()
      result = Elements.remove(conn, ".temporary")

      assert %Plug.Conn{state: :chunked} = result
    end

    test "passes through event_id and retry options" do
      conn = chunked_conn()
      result = Elements.remove(conn, "#old", event_id: "rm-1", retry: 2000)

      assert %Plug.Conn{state: :chunked} = result
    end
  end

  describe "patch/3" do
    test "patches without selector (ID-based)" do
      conn = chunked_conn()
      result = Elements.patch(conn, "<div id=\"feed\">content</div>")

      assert %Plug.Conn{state: :chunked} = result
    end

    test "patches with nil html and mode :remove" do
      conn = chunked_conn()
      result = Elements.patch(conn, nil, selector: "#old", mode: :remove)

      assert %Plug.Conn{state: :chunked} = result
    end

    test "raises with nil html and non-remove mode" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/elements content is required/, fn ->
        Elements.patch(conn, nil, selector: "#x", mode: :outer)
      end
    end
  end
end
