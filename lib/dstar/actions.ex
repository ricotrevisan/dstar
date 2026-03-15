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

  # Datastar options that attach the CSRF token from the `_csrfToken` signal
  # as an `x-csrf-token` request header. The signal uses a `_` prefix so
  # Datastar excludes it from the JSON body (it only needs to be a header).
  #
  # To set up the signal, add this to your root layout:
  #
  #     <body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>
  #
  @csrf_opts "{headers: {'x-csrf-token': $_csrfToken}}"

  @verbs ~w(get post put patch delete)a

  # ── Verb helpers ──────────────────────────────────────────────────────

  for verb <- @verbs do
    verb_str = Atom.to_string(verb)
    @doc """
    Generates a `@#{verb_str}(...)` action expression for Datastar attributes.

    Includes an `x-csrf-token` header that reads from the `$_csrfToken`
    Datastar signal.

    ## With a known module (compile-time):

        iex> Dstar.Actions.#{verb_str}(MyApp.CounterHandler, "increment")
        "@#{verb_str}('/ds/my_app-counter_handler/increment', #{@csrf_opts})"

    ## With a dynamic module signal (runtime on client):

        iex> Dstar.Actions.#{verb_str}("increment")
        "@#{verb_str}('/ds/' + $_dstar_module + '/increment', #{@csrf_opts})"

    ## With a URL prefix:

        iex> Dstar.Actions.#{verb_str}(MyApp.Handler, "save", prefix: "/ws")
        "@#{verb_str}('/ws/ds/my_app-handler/save', #{@csrf_opts})"

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
        "@#{verb_str}('/my-workspace/ds/my_app-handler/save', #{@csrf_opts})"

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

  # ── Private ──────────────────────────────────────────────────────────

  defp action(verb, module, event_name, opts) do
    encoded = encode_module(module)
    prefix = Keyword.get(opts, :prefix, "")
    "@#{verb}('#{prefix}/ds/#{encoded}/#{event_name}', #{@csrf_opts})"
  end

  defp action_dynamic(verb, event_name, opts) do
    module = Keyword.get(opts, :module, "$_dstar_module")

    path =
      if module == "$_dstar_module" do
        "'/ds/' + $_dstar_module + '/#{event_name}'"
      else
        "'/ds/#{module}/#{event_name}'"
      end

    "@#{verb}(#{path}, #{@csrf_opts})"
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
