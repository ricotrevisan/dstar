defmodule Dstar.Scripts do
  @moduledoc """
  Executes JavaScript on the client via SSE.

  Appends a `<script>` tag to the body using `datastar-patch-elements`.

      conn |> execute("alert('Hello!')")
      conn |> execute("console.log('debug')", auto_remove: false)
  """

  alias Dstar.Elements

  @doc """
  Executes JavaScript on the client by appending a script tag to the body.

  ## Options

  - `:auto_remove` - Remove script tag after execution (default: true)
  - `:attributes` - Map of additional script tag attributes
  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  ## Examples

      # Simple script execution
      conn |> execute("alert('Hello!')")

      # Keep script in DOM
      conn |> execute("window.myVar = 42", auto_remove: false)

      # ES module script
      conn |> execute("import {...} from 'module'", attributes: %{type: "module"})

  """
  @spec execute(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def execute(conn, script, opts \\ []) when is_binary(script) do
    auto_remove = Keyword.get(opts, :auto_remove, true)
    attributes = Keyword.get(opts, :attributes, %{})

    all_attributes =
      if auto_remove do
        Map.put_new(attributes, "data-effect", "el.remove()")
      else
        attributes
      end

    attr_list =
      all_attributes
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> ~s(#{k}="#{escape_html_attr(v)}") end)

    attrs_str = if attr_list == [], do: "", else: " " <> Enum.join(attr_list, " ")

    script_html = "<script#{attrs_str}>#{escape_script_content(script)}</script>"

    element_opts =
      [
        selector: "body",
        mode: :append,
        event_id: opts[:event_id],
        retry: opts[:retry]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Elements.patch(conn, script_html, element_opts)
  end

  @doc """
  Redirects the client to the given URL via JavaScript.

  Uses `Jason.encode!/1` to safely encode the URL, preventing injection
  attacks. Uses `setTimeout` for proper browser history handling.

  ## Examples

      conn |> redirect("/workspaces")
      conn |> redirect("https://example.com")

  """
  @spec redirect(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def redirect(conn, url, opts \\ []) when is_binary(url) do
    execute(
      conn,
      "setTimeout(function(){window.location.href=#{Jason.encode!(url)}},0)",
      opts
    )
  end

  @doc """
  Logs a message to the browser console via SSE.

  ## Options

  - `:level` - Console method: `:log`, `:warn`, `:error`, `:info`, `:debug` (default: :log)
  - Plus all options from `execute/3`

  ## Examples

      conn |> console_log("Debug message")
      conn |> console_log("Warning!", level: :warn)
      conn |> console_log(%{user: "alice"}, level: :info)

  """
  @spec console_log(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def console_log(conn, message, opts \\ []) do
    {level, opts} = Keyword.pop(opts, :level, :log)

    level_str =
      case level do
        :log -> "log"
        :warn -> "warn"
        :error -> "error"
        :info -> "info"
        :debug -> "debug"
        _ -> "log"
      end

    js_message =
      case message do
        msg when is_binary(msg) -> "'#{escape_js_string(msg)}'"
        msg -> Jason.encode!(msg)
      end

    execute(conn, "console.#{level_str}(#{js_message})", opts)
  end

  # Private helpers

  defp escape_html_attr(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_html_attr(other), do: to_string(other)

  # A `<script>` element ends only at `</script` (case-insensitive, followed
  # by `>`, whitespace, or `/`). Neutralize it by inserting a backslash right
  # after the `<`, so the HTML parser sees `<\/script` — not a closing tag —
  # while the value stays intact in every JS context:
  #
  #   * in a string/template literal, `<\/script` === `</script`;
  #   * a regex literal can never contain an unescaped `</script` (the `/`
  #     would terminate the regex), so it is never matched/altered.
  #
  # We deliberately do NOT touch `<script` or `<!--`: backslashing those
  # (`<\script`, `<\!--`) silently corrupts developer regex literals (`\s`
  # becomes a whitespace class, `\!` is an invalid unicode-mode escape), and
  # they cannot break out on their own — ending the element still requires a
  # `</script`, which this neutralizes. (A `<!--<script>` chain only makes the
  # wrapper's own `</script>` fail to close, turning the injected text into an
  # inert syntax error with nothing after it to capture.)
  @script_close ~r{</script}i

  defp escape_script_content(script) do
    Regex.replace(@script_close, script, fn match ->
      "<\\" <> String.slice(match, 1..-1//1)
    end)
  end

  defp escape_js_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end
end
