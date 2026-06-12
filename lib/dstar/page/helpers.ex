defmodule Dstar.Page.Helpers do
  @moduledoc """
  Template and handler helpers imported by `use Dstar.Page`.

  - `event/1,2` — Datastar action expression targeting the page's own
    `_event` route, resolved client-side via `location.pathname`.
  - `connect/0,1` — Datastar action expression opening the page's SSE stream.
  - `patch/3,4` — render a function component into a `patch_elements` call.
  """

  @verbs ~w(get post put patch delete)a

  @doc """
  Builds a page-local Datastar action expression.

      event("increment")
      #=> "@post(location.pathname.replace(/\\/+$/, '') + '/_event/increment')"

      event("remove", verb: :delete)
      #=> "@delete(location.pathname.replace(/\\/+$/, '') + '/_event/remove')"

  The URL is computed in the browser, so path params (workspace slugs,
  ids) need no server-side threading. Event names become a single URL
  path segment: they must not contain `/` or `'`.

  Trailing slashes in the path are stripped client-side so pages mounted
  at "/" or visited with a trailing slash don't produce protocol-relative
  ("//") or double-slash URLs.

  ## Options

  - `:verb` — `:get | :post | :put | :patch | :delete` (default `:post`)
  - `:opts` — raw JS object string appended as the action's options,
    e.g. `"{retryMaxCount: 5}"`
  """
  def event(name, opts \\ []) when is_binary(name) and is_list(opts) do
    if String.contains?(name, ["'", "/"]) do
      raise ArgumentError,
            "event name must not contain \"'\" or \"/\", got: #{inspect(name)}"
    end

    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    args = "location.pathname.replace(/\\/+$/, '') + '/_event/#{name}'"

    args =
      case Keyword.get(opts, :opts) do
        nil -> args
        extra when is_binary(extra) -> args <> ", " <> extra
      end

    "@#{verb}(#{args})"
  end

  @doc """
  Builds the stream-connect expression for `data-init` /
  `data-on:online__window`.

      connect()
      #=> "@post(location.pathname, {retryMaxCount: Infinity})"

      connect(include_search: true)
      #=> "@post(location.pathname + location.search, {retryMaxCount: Infinity})"

  ## Options

  - `:opts` — override the options object (default `"{retryMaxCount: Infinity}"`)
  - `:include_search` — append `location.search` so query params reach `handle_connect`
    (pages whose render depends on them, e.g. `?step=`).

  Always emits `@post` — Dstar streams connect over POST.
  """
  def connect(opts \\ []) when is_list(opts) do
    extra = Keyword.get(opts, :opts, "{retryMaxCount: Infinity}")

    url =
      if Keyword.get(opts, :include_search, false) do
        "location.pathname + location.search"
      else
        "location.pathname"
      end

    "@post(#{url}, #{extra})"
  end

  @doc """
  Renders a function component and pipes it to `Dstar.Elements.patch/3`.

      conn |> patch(&history/1, value: count)
      conn |> patch(&item_card/1, [item: item], selector: "#row-1", mode: :outer)

  With no `:selector`, Datastar matches elements by their `id` attribute,
  so the component's root element must carry one.
  """
  def patch(conn, component, assigns, opts \\ [])
      when is_function(component, 1) and (is_list(assigns) or is_map(assigns)) do
    # Direct function-component calls bypass the HEEx engine, which is what
    # normally adds :__changed__; without it, any assign/3 inside raises.
    assigns = assigns |> Map.new() |> Map.put_new(:__changed__, nil)
    html = component.(assigns)
    Dstar.Elements.patch(conn, html, opts)
  end
end
