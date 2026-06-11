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

      # Skip render if mount halted OR staged/sent any response. A :set conn
      # (resp/3 without send_resp) must be honored, not overwritten: Plug
      # adapters auto-send staged responses (see Plug.Cowboy.Handler.maybe_send/2).
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

    # ── POST _event/:event: read signals, start SSE, handle_event ───────

    defp event(conn, page) do
      conn = fetch_query_params(conn)

      event =
        conn.path_params["event"] ||
          raise(
            ArgumentError,
            "missing :event path param — route the event POST with an `:event` segment"
          )

      signals = Dstar.Signals.read(conn)
      conn = Dstar.SSE.start(conn)

      if Application.get_env(:dstar, :debug_errors, false) do
        try do
          page.handle_event(conn, event, signals)
        rescue
          exception ->
            stacktrace = __STACKTRACE__

            # Best-effort: if the conn died mid-stream, console_log raising
            # here would shadow the original exception.
            try do
              Dstar.console_log(
                conn,
                Exception.format(:error, exception, stacktrace),
                level: :error
              )
            rescue
              _ -> :ok
            end

            reraise exception, stacktrace
        end
      else
        page.handle_event(conn, event, signals)
      end
    end

    # ── POST stream — implemented in Task 8 ─────────────────────────────
    defp stream(conn, _page), do: send_resp(conn, 501, "not implemented")
  end
end
