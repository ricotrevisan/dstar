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

    # ── POST stream: connect, then library-owned receive loop ───────────

    defp stream(conn, page) do
      if function_exported?(page, :handle_connect, 2) do
        conn = fetch_query_params(conn)

        conn =
          if function_exported?(page, :stream_key, 1) do
            Dstar.start_stream(conn, page.stream_key(conn))
          else
            Dstar.SSE.start(conn)
          end

        # TODO: consider a debug_errors relay (like the event action) for
        # handle_connect/handle_info crashes — today a crash means a silent
        # dead stream in the browser.
        conn = page.handle_connect(conn, conn.params)
        loop(conn, page, page.__dstar__(:idle_check))
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
      end
    end

    defp loop(conn, page, idle_check) do
      receive do
        # Plug adapters notify the conn owner when the response is sent;
        # this is internal plumbing, never a page message.
        {:plug_conn, :sent} ->
          loop(conn, page, idle_check)

        msg ->
          case dispatch_info(page, msg, conn) do
            {:halt, conn} -> conn
            conn -> loop(conn, page, idle_check)
          end
      after
        idle_check ->
          case Dstar.check_connection(conn) do
            {:ok, conn} -> loop(conn, page, idle_check)
            {:error, conn} -> conn
          end
      end
    end

    # A message matching no handle_info/2 clause must not kill the stream.
    # Only a FunctionClauseError raised by the head of the page's own
    # handle_info/2 is absorbed; errors inside a matched clause propagate.
    defp dispatch_info(page, msg, conn) do
      page.handle_info(msg, conn)
    rescue
      exception in FunctionClauseError ->
        if exception.module == page and exception.function == :handle_info and
             exception.arity == 2 do
          Logger.warning("#{inspect(page)} received unhandled message: #{inspect(msg)}")

          conn
        else
          reraise exception, __STACKTRACE__
        end
    end
  end
end
