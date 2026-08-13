defmodule Dstar.Page.Helpers do
  @moduledoc """
  Template and handler helpers imported by `use Dstar.Page`.

  - `event/1,2` — Datastar action expression targeting the page's own
    `_event` route, resolved client-side via `location.pathname`.
  - `connect/0,1` — Datastar action expression opening the page's SSE stream.
  - `patch/3,4` — render a function component into a `patch_elements` call.
  """

  @doc """
  Builds a page-local Datastar action expression.

      event("increment")
      #=> ~S|@post(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/increment")|

      event("remove", verb: :delete)
      #=> ~S|@delete(location.pathname.replace(/^\/+/, '/').replace(/\/+$/, '') + "/_event/remove")|

  The URL is computed in the browser, so path params (workspace slugs,
  ids) need no server-side threading. Event names are percent-encoded as one
  URL path segment; handlers receive the original decoded value. Empty,
  `"."`, and `".."` names raise `ArgumentError` because browsers normalize
  those segments.

  Leading slashes are collapsed and trailing slashes are stripped client-side,
  so even an unusual pathname cannot become a protocol-relative target.

  ## Options

  - `:verb` — `:get | :post | :put | :patch | :delete` (default `:post`)
  - `:opts` — trusted, developer-authored JavaScript appended as the action's
    options, e.g. `"{indicator: 'saving'}"`. This is a code escape hatch;
    never build it from request, stored, or other untrusted data.
  """
  def event(name, opts \\ []) when is_binary(name) and is_list(opts) do
    Dstar.Actions.build_action(
      :page_path,
      ["_event", name],
      opts
    )
  end

  @doc """
  Builds the stream-connect expression for `data-init` /
  `data-on:online__window`.

      connect()
      #=> ~S|@post(location.pathname.replace(/^\/+/, '/'), {retryMaxCount: Infinity})|

      connect(include_search: true)
      #=> ~S|@post(location.pathname.replace(/^\/+/, '/') + location.search, {retryMaxCount: Infinity})|

  ## Options

  - `:opts` — override the options object (default `"{retryMaxCount: Infinity}"`).
    This is trusted, developer-authored JavaScript; never interpolate data into it.
  - `:include_search` — append `location.search` so query params reach `handle_connect`
    (pages whose render depends on them, e.g. `?step=`).

  Leading slashes in `location.pathname` are collapsed so the emitted request
  cannot become protocol-relative. Always emits `@post` — Dstar streams connect
  over POST.

  > #### retryMaxCount does not bound reconnect cycles {: .warning}
  >
  > It counts *consecutive failures to connect*, and the client resets it —
  > along with the backoff interval — on every 200. So it cannot cap a loop
  > that reconnects successfully each time round: the budget never
  > accumulates, whatever finite value you set. Only `retryMaxCount: 0`
  > stops such a loop.
  >
  > This applies when the stream ends as a **transport error**: an HTTP/2
  > takeover (the stream process is killed outright rather than halting),
  > the registry's kill escalation, or a crash. A stream that ends
  > *cleanly* — the ordinary HTTP/1.1 takeover, where the loop halts and
  > the response is terminated properly — does not reconnect at all under
  > the default `retry: "auto"`; reconnecting after a clean end requires
  > `retry: "always"`.
  >
  > If you combine auto-reconnect with `Dstar.Utility.StreamRegistry` dedup
  > on a stack where takeovers end as errors, cap it:
  >
  >     connect(opts: "{retryMaxCount: 0}")
  """
  def connect(opts \\ []) when is_list(opts) do
    extra = Keyword.get(opts, :opts, "{retryMaxCount: Infinity}")

    base =
      if Keyword.get(opts, :include_search, false) do
        :stream_path_with_search
      else
        :stream_path
      end

    Dstar.Actions.build_action(base, [], verb: :post, opts: extra)
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

  @doc """
  Wires a container to re-run `action` whenever that nudge fires.

      <div id="posts" {on_nudge("posts", event("reload"))}>

  See `Dstar.Actions.on_nudge/2`.
  """
  defdelegate on_nudge(key, action), to: Dstar.Actions
end
