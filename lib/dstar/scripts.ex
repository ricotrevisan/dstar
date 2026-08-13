defmodule Dstar.Scripts do
  @moduledoc """
  Executes JavaScript on the client via SSE.

  Appends a `<script>` tag to the body using `datastar-patch-elements`.

      conn |> execute("alert('Hello!')")
      conn |> execute("console.log('debug')", auto_remove: false)
  """

  alias Dstar.Elements

  @levels ~w(log warn error info debug)a

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
      |> Enum.map(fn {k, v} -> ~s(#{validate_attr_name!(k)}="#{escape_html_attr(v)}") end)

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

  Uses `setTimeout` so the browser records a history entry.

  ## Destination policy

  Default: same-origin, path-absolute destinations only. Query-only and
  fragment-only references (`?x=1`, `#frag`) are also allowed — they stay
  on the current path. Validation uses parsed URL *components* (via `URI`),
  not a case-sensitive prefix check, and raises `ArgumentError` **before**
  any SSE patch is emitted.

  Allowed without opt-in:

      conn |> redirect("/workspaces")
      conn |> redirect("/search?q=1#results")
      conn |> redirect("?next=1")
      conn |> redirect("#section")
      # same-origin absolute URL (scheme/host/port match the request)
      conn |> redirect("http://www.example.com/path")

  Rejected:

    * `javascript:`, `data:`, `vbscript:` (any case)
    * those schemes hidden behind leading, control, or Unicode whitespace
      (`"  DATA:…"`, `"JavaScript:…"`, `"java\\tscript:…"`)
    * protocol-relative URLs (`//evil.example`, including tab/LF/CR
      smuggled into a path so browsers parse `/\n/evil` as `//evil`)
    * URLs with userinfo (`https://trusted.example@evil.example/`)
    * off-origin `http`/`https` (including `https://example.com`)

  Off-origin `http`/`https` needs an explicit opt-in — either
  `external: true` or a host allowlist. Hosts are matched exactly
  (case-insensitive) against the *parsed* host. Dangerous schemes,
  protocol-relative URLs, and userinfo are still rejected.

      conn |> redirect("https://ok.example/docs", external: true)
      conn |> redirect("https://ok.example/docs", allow: ["ok.example"])

  `Jason.encode!/1` (plus the `</script` neutralizer in `execute/3`)
  prevents the URL from breaking out of the generated JavaScript string.
  It does **not** make the destination itself safe — do not pass an
  untrusted `return_to` (or similar) without deciding the policy. For
  raw JavaScript, use `execute/3`; that remains a trusted-code API.

  ## Options

    * `:external` - when `true`, allow any `http`/`https` URL
    * `:allow` - list of host strings permitted for `http`/`https`
    * plus all options from `execute/3`

  """
  @spec redirect(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def redirect(conn, url, opts \\ []) when is_binary(url) do
    {policy_opts, exec_opts} = Keyword.split(opts, [:external, :allow])
    validate_destination!(conn, url, policy_opts)

    execute(
      conn,
      "setTimeout(function(){window.location.href=#{encode_redirect_url(url)}},0)",
      exec_opts
    )
  end

  @doc """
  Logs a message to the browser console via SSE.

  ## Options

  - `:level` - Console method: `:log`, `:warn`, `:error`, `:info`, `:debug`
    (default: `:log`). Anything else raises — a mistyped level used to fall
    back to `:log` silently, which hid the typo rather than the message.
  - Plus all options from `execute/3`

  ## Examples

      conn |> console_log("Debug message")
      conn |> console_log("Warning!", level: :warn)
      conn |> console_log(%{user: "alice"}, level: :info)

  """
  @spec console_log(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def console_log(conn, message, opts \\ []) do
    {level, opts} = Keyword.pop(opts, :level, :log)

    unless level in @levels do
      raise ArgumentError,
            "invalid level: #{inspect(level)}. Must be one of #{inspect(@levels)}"
    end

    js_message =
      case message do
        msg when is_binary(msg) -> "'#{escape_js_string(msg)}'"
        msg -> Jason.encode!(msg)
      end

    execute(conn, "console.#{level}(#{js_message})", opts)
  end

  # Private helpers

  # Attribute *values* are escaped, but the name is written verbatim into the
  # opening tag, so a name carrying `>`/`"`/space/etc. would break out of the
  # `<script …>` tag and inject live markup. Restrict names to a conservative
  # allowlist that still covers ordinary and Datastar attributes
  # (`type`, `nonce`, `data-effect`, `data-on:click`, …) and reject anything
  # else rather than silently mangle it.
  @attr_name ~r/\A[A-Za-z0-9_:.-]+\z/

  defp validate_attr_name!(name) do
    str = to_string(name)

    if Regex.match?(@attr_name, str) do
      str
    else
      raise ArgumentError,
            "invalid script attribute name #{inspect(name)} — names may contain only " <>
              "letters, digits, and the characters - _ : ."
    end
  end

  defp escape_html_attr(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Non-binary values (charlists, atoms, …) must be stringified AND escaped —
  # emitting them raw lets a value close the quote and break out of the tag.
  defp escape_html_attr(other), do: escape_html_attr(to_string(other))

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

  # Destination policy for redirect/3.
  #
  # Jason.encode!/1 quotes the URL as JS data (no string breakout) but does
  # not make the destination safe: `javascript:` assigned to
  # `window.location.href` is DOM XSS, and an off-origin URL is an open
  # redirect. We classify parsed URI components — never a prefix check —
  # and raise before execute/3 runs so a rejected URL emits no SSE patch.
  @dangerous_schemes ~w(javascript data vbscript)
  @http_schemes ~w(http https)

  # Unicode space / format characters that URI.parse leaves in the path
  # (so `"\\u00A0javascript:alert(1)"` looks schemeless) but browsers may
  # ignore, revealing a dangerous scheme. ASCII C0 + space are handled
  # by the `c <= 0x20` guard.
  @unicode_ignorables [
    0x00A0,
    0x00AD,
    0x1680,
    0x180E,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x200B,
    0x200C,
    0x200D,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x2060,
    0x3000,
    0xFEFF
  ]

  defp validate_destination!(conn, url, opts) do
    allow = fetch_allow!(opts)
    external? = Keyword.get(opts, :external, false) == true
    codepoints = utf8_codepoints!(url)

    # Browsers strip tab/LF/CR anywhere before parsing, so "/\n/evil.example"
    # becomes "//evil.example". Classify both the raw string and the
    # ignorable-stripped form; emit the original only if both are allowed.
    stripped = codepoints |> Enum.reject(&ignorable_char?/1) |> List.to_string()

    Enum.each(Enum.uniq([url, stripped]), fn candidate ->
      uri = URI.parse(candidate)
      reject_if_bad_scheme!(uri, url)

      unless destination_allowed?(conn, uri, external?, allow) do
        raise_unsafe_redirect(url)
      end
    end)
  end

  defp destination_allowed?(conn, uri, external?, allow) do
    cond do
      not is_nil(uri.userinfo) ->
        false

      protocol_relative?(uri) ->
        false

      local_destination?(conn, uri) ->
        true

      http_destination?(uri) and (external? or host_allowed?(uri, allow)) ->
        true

      true ->
        false
    end
  end

  defp reject_if_bad_scheme!(%URI{} = uri, url) do
    scheme = normalized_scheme(uri)

    cond do
      scheme in @dangerous_schemes ->
        raise_unsafe_redirect(url)

      scheme not in [nil | @http_schemes] ->
        raise_unsafe_redirect(url)

      true ->
        :ok
    end
  end

  defp normalized_scheme(%URI{scheme: nil}), do: nil
  defp normalized_scheme(%URI{scheme: scheme}), do: String.downcase(scheme)

  defp protocol_relative?(%URI{scheme: scheme, host: host}) do
    is_nil(scheme) and not is_nil(host)
  end

  defp http_destination?(%URI{} = uri) do
    normalized_scheme(uri) in @http_schemes and is_binary(uri.host) and uri.host != ""
  end

  defp local_destination?(conn, uri) do
    cond do
      http_destination?(uri) ->
        same_origin?(conn, uri)

      not is_nil(uri.scheme) or not is_nil(uri.host) ->
        false

      path_absolute_local?(uri.path) ->
        true

      query_or_fragment_only?(uri) ->
        true

      true ->
        false
    end
  end

  # Path-absolute and not protocol-relative. `/\evil` is rejected because
  # some browsers treat `\` as `/`, turning it into `//evil`.
  defp path_absolute_local?(<<"//", _::binary>>), do: false
  defp path_absolute_local?(<<"/\\", _::binary>>), do: false
  defp path_absolute_local?(<<"/", _::binary>>), do: true
  defp path_absolute_local?(_), do: false

  defp query_or_fragment_only?(%URI{path: path, query: query, fragment: fragment}) do
    (is_nil(path) or path == "") and (not is_nil(query) or not is_nil(fragment))
  end

  defp same_origin?(conn, uri) do
    req_scheme = conn.scheme |> to_string() |> String.downcase()
    req_host = conn.host |> to_string() |> String.downcase()
    req_port = effective_port(req_scheme, conn.port)

    dest_scheme = normalized_scheme(uri)
    dest_host = uri.host |> to_string() |> String.downcase()
    dest_port = effective_port(dest_scheme, uri.port)

    dest_scheme == req_scheme and dest_host == req_host and dest_port == req_port
  end

  defp effective_port("http", port) when port in [nil, 80], do: 80
  defp effective_port("https", port) when port in [nil, 443], do: 443
  defp effective_port(_scheme, port), do: port

  defp host_allowed?(%URI{host: host}, allow) when is_binary(host) and host != "" do
    dest = String.downcase(host)
    Enum.any?(allow, fn allowed -> String.downcase(allowed) == dest end)
  end

  defp host_allowed?(_, _), do: false

  defp fetch_allow!(opts) do
    case Keyword.get(opts, :allow, []) do
      list when is_list(list) ->
        Enum.each(list, fn
          host when is_binary(host) and host != "" ->
            :ok

          other ->
            raise ArgumentError,
                  "redirect/3 :allow must be a list of host strings, got: #{inspect(other)}"
        end)

        list

      other ->
        raise ArgumentError,
              "redirect/3 :allow must be a list of host strings, got: #{inspect(other)}"
    end
  end

  defp utf8_codepoints!(url) do
    case :unicode.characters_to_list(url) do
      list when is_list(list) -> list
      _ -> raise_unsafe_redirect(url)
    end
  end

  defp ignorable_char?(c) when is_integer(c) and c <= 0x20, do: true
  defp ignorable_char?(0x7F), do: true
  defp ignorable_char?(c) when c in @unicode_ignorables, do: true
  defp ignorable_char?(_), do: false

  # Jason.encode!/1 is valid JSON but leaves U+2028/U+2029 unescaped.
  # Older JS string grammars treat those as line terminators, so a URL
  # carrying them would break out of `window.location.href="…"`.
  defp encode_redirect_url(url) do
    url
    |> Jason.encode!()
    |> String.replace(<<0x2028::utf8>>, "\\u2028")
    |> String.replace(<<0x2029::utf8>>, "\\u2029")
  end

  defp raise_unsafe_redirect(url) do
    raise ArgumentError,
          "unsafe redirect destination: #{inspect(url)}. " <>
            "Default policy allows same-origin path-absolute URLs " <>
            "(and query/fragment on the current path). " <>
            "Use external: true or allow: [\"host\"] for http(s) URLs."
  end
end
