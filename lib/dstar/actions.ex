defmodule Dstar.Actions do
  @moduledoc """
  Helpers for generating Datastar action expressions and encoding module names.

  ## Examples

      # In a Phoenix template:
      <button data-on:click={Dstar.post(MyApp.CounterHandler, "increment")}>+</button>

      # Other HTTP verbs:
      <button data-on:click={Dstar.delete(MyApp.ItemHandler, "remove")}>×</button>

      # Dynamic module (reads from signal):
      <button data-on:click={Dstar.post("increment")}>+</button>

  Literal event and module values are percent-encoded as one URL path
  segment. Dynamic module signals are encoded in the browser. Exact empty and
  dot segments are rejected because browser URL parsing would remove or
  normalize them.

  A `:prefix`, when supplied to a module form, must be a local absolute
  application path: it starts with one `/` and contains no dot segment,
  backslash, query, fragment, or control character.

  """

  # No explicit CSRF header needed — Datastar sends all signals (including
  # `csrf`) as body params on POST/PUT/PATCH and in the `datastar` query
  # parameter on GET/DELETE. The `RenameCsrfParam` plug copies the token
  # into `_csrf_token` for `Plug.CSRFProtection` from either channel.
  #
  # To set up the token, add this signal to your root layout:
  #
  #     <body data-signals:csrf={"'#{get_csrf_token()}'"}>
  #

  @verbs ~w(get post put patch delete)a

  # ── Verb helpers ──────────────────────────────────────────────────────

  for verb <- @verbs do
    verb_str = Atom.to_string(verb)

    @doc """
    Generates a `@#{verb_str}(...)` action expression for Datastar attributes.

    CSRF is handled automatically — Datastar sends all signals (including
    `csrf`) as body params on POST/PUT/PATCH and in the `datastar` query
    parameter on GET/DELETE; `RenameCsrfParam` maps it to `_csrf_token`.

    ## With a known module (compile-time):

        iex> Dstar.Actions.#{verb_str}(MyApp.CounterHandler, "increment")
        ~s|@#{verb_str}("/ds/my_app-counter_handler/increment")|

    ## With a dynamic module signal (runtime on client):

        iex> expression = Dstar.Actions.#{verb_str}("increment")
        iex> String.contains?(expression, "encodeURIComponent")
        true

    ## With a URL prefix:

        iex> Dstar.Actions.#{verb_str}(MyApp.Handler, "save", prefix: "/ws")
        ~s|@#{verb_str}("/ws/ds/my_app-handler/save")|

    ## Options

    - `:prefix` — local absolute application path (for example,
      `"/my-workspace"`). Only for the module form; relative, protocol-relative,
      cross-origin, dot-segment, query, fragment, backslash, and
      control-containing values are rejected; percent escapes must decode as
      valid UTF-8.
    - `:module` — literal module override. Only for the dynamic form. Without
      it, the `$_dstar_module` signal is read and encoded at runtime.

    Event and module values are encoded as one literal route segment. Empty,
    `"."`, and `".."` values raise `ArgumentError` because browsers normalize
    those segments.

    """
    def unquote(verb)(module_or_name, name_or_opts \\ [])

    @spec unquote(verb)(module(), String.t()) :: String.t()
    def unquote(verb)(module, event_name)
        when is_atom(module) and is_binary(event_name) do
      action(unquote(verb_str), module, event_name, [])
    end

    @spec unquote(verb)(String.t(), keyword()) :: String.t()
    def unquote(verb)(event_name, opts)
        when is_binary(event_name) and is_list(opts) do
      action_dynamic(unquote(verb_str), event_name, opts)
    end

    @doc """
    Generates a `@#{verb_str}(...)` expression with a local absolute URL prefix.

    The prefix must start with one `/` and cannot contain a dot segment,
    backslash, query, fragment, or control character. Percent escapes must be
    valid UTF-8.

    ## Example

        iex> Dstar.Actions.#{verb_str}(MyApp.Handler, "save", prefix: "/my-workspace")
        ~s|@#{verb_str}("/my-workspace/ds/my_app-handler/save")|

    """
    @spec unquote(verb)(module(), String.t(), keyword()) :: String.t()
    def unquote(verb)(module, event_name, opts)
        when is_atom(module) and is_binary(event_name) and is_list(opts) do
      action(unquote(verb_str), module, event_name, opts)
    end
  end

  # ── Deprecated event/1,2,3 ───────────────────────────────────────────

  @doc deprecated: "Use Dstar.Actions.post/2 (or get/put/patch/delete) instead"
  def event(module_or_name, name_or_opts \\ [])

  def event(module, event_name) when is_atom(module) and is_binary(event_name) do
    post(module, event_name)
  end

  def event(event_name, opts) when is_binary(event_name) and is_list(opts) do
    post(event_name, opts)
  end

  @doc deprecated: "Use Dstar.Actions.post/3 (or get/put/patch/delete) instead"
  def event(module, event_name, opts)
      when is_atom(module) and is_binary(event_name) and is_list(opts) do
    post(module, event_name, opts)
  end

  # ── Nudges ───────────────────────────────────────────────────────────

  @nudge_attr "data-on-signal-patch"
  @nudge_filter_attr "data-on-signal-patch-filter"

  @doc """
  Runs `action` whenever `Dstar.Signals.nudge/3` bumps `key`.

  Returns an attribute map for HEEx spread:

      <div id="posts" {on_nudge("posts", event("reload"))}>

  Unlike `data-effect`, this does not fire on page init — only when that
  one nudge changes. See the [Live collections](live-collections.html) guide.

  ## Examples

      iex> Dstar.Actions.on_nudge("posts", "@post('/reload')")
      %{
        "data-on-signal-patch" => "@post('/reload')",
        "data-on-signal-patch-filter" => ~S({"include":"^nudges\\\\.posts$"})
      }

  """
  @spec on_nudge(String.t() | atom(), String.t()) :: %{String.t() => String.t()}
  def on_nudge(key, action) when is_binary(action) do
    key = Dstar.Signals.nudge_key!(key)

    %{
      @nudge_attr => action,
      @nudge_filter_attr => Jason.encode!(%{include: "^nudges\\.#{key}$"})
    }
  end

  # ── Shared action builder ────────────────────────────────────────────

  @doc false
  # The single URL-construction seam used by core Actions, Page, and
  # Component. Literal segments are percent-encoded on the server; dynamic
  # segments are encoded in the browser before they are joined to the path.
  # The base and dynamic segment atoms are reserved for library-authored
  # browser expressions.
  def build_action(base, segments, opts)
      when is_list(segments) and is_list(opts) do
    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    url_expression =
      [base | Enum.map(segments, &segment_part/1)]
      |> collapse_literals()
      |> Enum.map_join(" + ", &render_url_part/1)

    args =
      case Keyword.get(opts, :opts) do
        nil ->
          url_expression

        extra when is_binary(extra) ->
          url_expression <> ", " <> extra

        extra ->
          raise ArgumentError, ":opts must be a trusted JavaScript string, got: #{inspect(extra)}"
      end

    "@#{verb}(#{args})"
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp action(verb, module, event_name, opts) do
    prefix =
      if Keyword.has_key?(opts, :prefix) do
        opts |> Keyword.fetch!(:prefix) |> validate_prefix!()
      else
        ""
      end

    build_action(
      {:literal, prefix <> "/ds"},
      [encode_module(module), event_name],
      verb: String.to_existing_atom(verb)
    )
  end

  defp action_dynamic(verb, event_name, opts) do
    segments =
      case Keyword.get(opts, :module, :dynamic) do
        module when module in [:dynamic, "$_dstar_module"] ->
          [:dynamic_module, event_name]

        module when is_binary(module) ->
          [module, event_name]

        module ->
          raise ArgumentError, ":module must be a literal module string, got: #{inspect(module)}"
      end

    build_action(
      {:literal, "/ds"},
      segments,
      verb: String.to_existing_atom(verb)
    )
  end

  defp validate_prefix!(prefix) when is_binary(prefix) do
    decoded = URI.decode(prefix)

    invalid? =
      not String.valid?(prefix) or not valid_percent_encoding?(prefix) or
        not String.valid?(decoded) or unsafe_prefix?(prefix) or unsafe_prefix?(decoded)

    if invalid? do
      raise ArgumentError,
            ":prefix must be a local absolute path starting with one /, use valid percent encoding, and contain no dot segment, backslash, query, fragment, or control characters, got: #{inspect(prefix)}"
    end

    String.trim_trailing(prefix, "/")
  end

  defp validate_prefix!(prefix) do
    raise ArgumentError, ":prefix must be a local absolute path, got: #{inspect(prefix)}"
  end

  defp valid_percent_encoding?(prefix) do
    remaining = String.replace(prefix, ~r/%[0-9A-Fa-f]{2}/, "")
    not String.contains?(remaining, "%")
  end

  defp unsafe_prefix?(prefix) do
    not String.starts_with?(prefix, "/") or
      String.starts_with?(prefix, "//") or
      String.contains?(prefix, ["\\", "?", "#"]) or
      String.match?(prefix, ~r/[\x00-\x1F\x7F]/u) or
      Enum.any?(String.split(prefix, "/"), &(&1 in [".", ".."]))
  end

  defp segment_part(segment) when is_binary(segment) do
    {:literal, "/" <> encode_segment!(segment)}
  end

  defp segment_part(:dynamic_module), do: :dynamic_module

  defp segment_part(segment) do
    raise ArgumentError, "path segment must be a string, got: #{inspect(segment)}"
  end

  defp collapse_literals(parts) do
    Enum.reduce(parts, [], fn
      {:literal, value}, [{:literal, previous} | rest] ->
        [{:literal, previous <> value} | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
  end

  defp render_url_part({:literal, value}), do: Jason.encode!(value, escape: :javascript_safe)

  defp render_url_part(:page_path) do
    "location.pathname.replace(/^\\/+/, '/').replace(/\\/+$/, '')"
  end

  defp render_url_part(:component_base) do
    "(() => { const base = document.body.dataset.dsBase || '/ds'; " <>
      "let decodedBase; try { decodedBase = decodeURIComponent(base) } catch (_) { throw new TypeError('invalid Dstar component base') } " <>
      "const unsafeBase = value => typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || " <>
      "/[\\\\?#\\x00-\\x1F\\x7F]/.test(value) || value.split('/').some(segment => segment === '.' || segment === '..'); " <>
      "if (unsafeBase(base) || unsafeBase(decodedBase)) throw new TypeError('invalid Dstar component base'); " <>
      "return base.replace(/\\/+$/, '') })()"
  end

  defp render_url_part(:stream_path), do: "location.pathname.replace(/^\\/+/, '/')"

  defp render_url_part(:stream_path_with_search) do
    "location.pathname.replace(/^\\/+/, '/') + location.search"
  end

  defp render_url_part(:dynamic_module) do
    Jason.encode!("/", escape: :javascript_safe) <>
      " + ((segment) => { if (typeof segment !== 'string' || segment === '' || segment === '.' || segment === '..') throw new TypeError('invalid Dstar module segment'); return encodeURIComponent(segment).replace(/[!'()*\\.]/g, char => '%' + char.charCodeAt(0).toString(16).toUpperCase()) })($_dstar_module)"
  end

  defp encode_segment!(segment) do
    if segment in ["", ".", ".."] or not String.valid?(segment) do
      raise ArgumentError,
            ~s|path segment must be valid UTF-8 and must not be empty, ".", or "..", got: #{inspect(segment)}|
    end

    URI.encode(segment, fn char ->
      (char >= ?a and char <= ?z) or
        (char >= ?A and char <= ?Z) or
        (char >= ?0 and char <= ?9) or char in [?-, ?_, ?~]
    end)
  end

  # ── Module encoding ─────────────────────────────────────────────────

  @doc """
  Encodes a module name for URL use.

  ## Examples

      iex> Dstar.Actions.encode_module(MyApp.CounterView)
      "my_app-counter_view"

      iex> Dstar.Actions.encode_module(MyApp.Web.ChatView)
      "my_app-web-chat_view"

  """
  @spec encode_module(module()) :: String.t()
  def encode_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join("-")
  end

  @doc """
  Decodes a URL-safe module name back to an Elixir module.

  Returns `{:ok, module}` if the module exists, `:error` otherwise.

  ## Examples

      iex> Dstar.Actions.decode_module("my_app-counter_view")
      {:ok, MyApp.CounterView}

  """
  @spec decode_module(String.t()) :: {:ok, module()} | :error
  def decode_module(encoded) when is_binary(encoded) do
    try do
      module_string =
        encoded
        |> String.split("-")
        |> Enum.map(&Macro.camelize/1)
        |> Enum.join(".")

      module = String.to_existing_atom("Elixir." <> module_string)
      {:ok, module}
    rescue
      ArgumentError -> :error
    end
  end
end
