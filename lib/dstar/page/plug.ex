if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Dstar.Page.Plug do
    @moduledoc """
    The plug behind `Dstar.Router.dstar/2`. Drives `Dstar.Page` callbacks:

    - `{:page, Module}` — GET: `mount/2` then `render/1` through Phoenix's
      view pipeline (root layout, flash, `page_title` all apply).
    - `{:event, Module}` — POST `_event/:event`: reads signals, starts SSE,
      calls `handle_event/3`.
    - `{:stream, Module}` — POST: starts SSE (deduped when `stream_key/1`
      is defined), calls `handle_connect/2`, then owns the receive loop
      dispatching to `handle_info/2`.

    All control flow lives here as plain functions — pages contain only
    callbacks.
    """

    @behaviour Plug

    require Logger
    import Plug.Conn

    @impl Plug
    def init({action, page}) when action in [:page, :event, :stream] and is_atom(page) do
      {action, page}
    end

    @impl Plug
    def call(conn, {:page, page}), do: page(conn, page)
    def call(conn, {:event, page}), do: event(conn, page)
    def call(conn, {:stream, page}), do: stream(conn, page)

    # ── GET: mount + render ─────────────────────────────────────────────

    defp page(conn, page) do
      conn = conn |> fetch_query_params() |> ensure_html_format()

      conn =
        if function_exported?(page, :mount, 2) do
          page.mount(conn, conn.params)
        else
          conn
        end

      if conn.halted or conn.state != :unset do
        conn
      else
        conn
        |> Phoenix.Controller.put_view(html: page)
        |> Phoenix.Controller.render(:render)
      end
    end

    defp ensure_html_format(conn) do
      if Phoenix.Controller.get_format(conn) do
        conn
      else
        Phoenix.Controller.put_format(conn, "html")
      end
    end

    # ── POST _event/:event — implemented in Task 7 ──────────────────────
    defp event(conn, _page), do: send_resp(conn, 501, "not implemented")

    # ── POST stream — implemented in Task 8 ─────────────────────────────
    defp stream(conn, _page), do: send_resp(conn, 501, "not implemented")
  end
end
