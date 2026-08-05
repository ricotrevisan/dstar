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
        "@#{verb_str}('/ds/my_app-counter_handler/increment')"

    ## With a dynamic module signal (runtime on client):

        iex> Dstar.Actions.#{verb_str}("increment")
        "@#{verb_str}('/ds/' + $_dstar_module + '/increment')"

    ## With a URL prefix:

        iex> Dstar.Actions.#{verb_str}(MyApp.Handler, "save", prefix: "/ws")
        "@#{verb_str}('/ws/ds/my_app-handler/save')"

    ## Options

    - `:prefix` — URL path prefix (e.g. `"/my-workspace"`). Only for the module form.
    - `:module` — Override the module signal name (default: `$_dstar_module`). Only for the dynamic form.

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
    Generates a `@#{verb_str}(...)` expression with a URL prefix.

    ## Example

        iex> Dstar.Actions.#{verb_str}(MyApp.Handler, "save", prefix: "/my-workspace")
        "@#{verb_str}('/my-workspace/ds/my_app-handler/save')"

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

  # ── Shared expression builder ────────────────────────────────────────

  @doc false
  # Shared by `Dstar.Page.Helpers.event/2` and `Dstar.Component.build_event/3`.
  # Both validate the event name and verb identically and assemble the same
  # `@verb(<url>, <opts>)` shape — they differ only in `url_expression`, the
  # JS that computes the target URL in the browser. Kept here so the verb
  # allowlist has one definition.
  def build_expression(name, url_expression, opts)
      when is_binary(name) and is_binary(url_expression) and is_list(opts) do
    if String.contains?(name, ["'", "/"]) do
      raise ArgumentError,
            "event name must not contain \"'\" or \"/\", got: #{inspect(name)}"
    end

    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    args =
      case Keyword.get(opts, :opts) do
        nil -> url_expression
        extra when is_binary(extra) -> url_expression <> ", " <> extra
      end

    "@#{verb}(#{args})"
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp action(verb, module, event_name, opts) do
    encoded = encode_module(module)
    prefix = Keyword.get(opts, :prefix, "")
    "@#{verb}('#{prefix}/ds/#{encoded}/#{event_name}')"
  end

  defp action_dynamic(verb, event_name, opts) do
    module = Keyword.get(opts, :module, "$_dstar_module")

    path =
      if module == "$_dstar_module" do
        "'/ds/' + $_dstar_module + '/#{event_name}'"
      else
        "'/ds/#{module}/#{event_name}'"
      end

    "@#{verb}(#{path})"
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
