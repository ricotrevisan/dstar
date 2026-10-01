if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Dstar.Page.Plug do
    @moduledoc """
    The plug behind `Dstar.Router.dstar/2`. Drives `Dstar.Page` callbacks:

    - `{:page, Module}` — GET: `mount/2` then `render/1` through Phoenix's
      view pipeline (root layout, flash, `page_title` all apply).
    - `{:event, Module}` — POST `_event/:event`: reads signals, optional
      `authorize/2`, starts SSE, calls `handle_event/3`.
    - `{:stream, Module}` — POST: optional `authorize/2`, atomically claims
      dedup ownership when `stream_key/1` is defined, starts SSE, calls
      `handle_connect/2`, then runs the receive loop on `Dstar.Stream`,
      dispatching to `handle_info/2`. A keyed claim failure returns 503
      before the callback.

    `authorize/2` is the pre-SSE seam: a halted or already-staged
    response is returned as ordinary HTTP and SSE never starts.
    Before authorization, signals are fetched with the page's
    `:max_signal_bytes` limit; malformed/non-object payloads return 400 and
    oversized payloads return 413. `mount/2` does not run on event or stream
    POSTs.

    A raise in `handle_event/3`, `handle_connect/2` or `handle_info/2` is
    logged and re-raised. With `config :dstar, debug_errors: true` (dev only)
    it is also relayed to the browser console over the open stream.

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
        if exported?(page, :mount, 2) do
          page.mount(conn, conn.params)
        else
          conn
        end

      # Skip render if mount halted OR staged/sent any response. A :set conn
      # (resp/3 without send_resp) must be honored, not overwritten: Plug
      # adapters auto-send staged responses (see Plug.Cowboy.Handler.maybe_send/2).
      if response_committed?(conn) do
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

    # ── POST _event/:event: read signals, authorize, start SSE, handle_event

    defp event(conn, page) do
      event =
        conn.path_params["event"] ||
          raise(
            ArgumentError,
            "missing :event path param — route the event POST with an `:event` segment"
          )

      before_sse(conn, page, fn _conn -> {:event, event} end, fn conn, signals ->
        conn = Dstar.SSE.start(conn)
        guard(page, :handle_event, conn, fn -> page.handle_event(conn, event, signals) end)
      end)
    end

    # ── POST stream: connect, then library-owned receive loop ───────────

    defp stream(conn, page) do
      if exported?(page, :handle_connect, 2) do
        before_sse(conn, page, &{:stream, &1.params}, fn conn, _signals ->
          open_stream(conn, page)
        end)
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
      end
    end

    # ── Shared pre-SSE pipeline for event and stream POSTs ──────────────

    # Reads signals within the page's limit, answering malformed (400) or
    # oversized (413) payloads as plain HTTP. Then runs authorize/2 with the
    # action `authorize_as` builds from the signal-bearing conn. `start` runs
    # only if no response was committed, so a rejected request never sees SSE.
    defp before_sse(conn, page, authorize_as, start) do
      conn = fetch_query_params(conn)

      case Dstar.Signals.fetch(conn, max_bytes: page.__dstar__(:max_signal_bytes)) do
        {:ok, signals, conn} ->
          conn = maybe_authorize(conn, page, authorize_as.(conn))

          if response_committed?(conn) do
            conn
          else
            start.(conn, signals)
          end

        {:error, reason, conn} ->
          Dstar.Signals.send_error(conn, reason)
      end
    end

    defp open_stream(conn, page) do
      opts = [max_bytes: page.__dstar__(:max_signal_bytes)]

      opts =
        if function_exported?(page, :stream_key, 1),
          do: [key: page.stream_key(conn)] ++ opts,
          else: opts

      # A refused claim or unreadable signals is an ordinary halted HTTP
      # response. It must not reach application connect callbacks or the loop.
      case Dstar.Stream.open(conn, opts) do
        {:ok, conn} ->
          Dstar.Stream.run(conn,
            connect: &connect(&1, page),
            info: &dispatch_info(page, &1, &2),
            replaced: &offer_replaced(&2, &1, page),
            disconnect: &disconnect(&1, page),
            idle_check: page.__dstar__(:idle_check)
          )

        {:error, conn} ->
          conn
      end
    end

    defp connect(conn, page) do
      guard(page, :handle_connect, conn, fn -> page.handle_connect(conn, conn.params) end)
    end

    # Streaming pages need handle_connect/2 but not handle_info/2, so this
    # dispatch is speculative on both counts: the callback may not exist, and
    # if it does it may have no clause for this message. Neither is an error.
    defp offer_replaced(conn, msg, page) do
      if exported?(page, :handle_info, 2) do
        dispatch_info(page, msg, conn, warn_unhandled: false)
      else
        conn
      end
    end

    defp disconnect(conn, page) do
      if exported?(page, :handle_disconnect, 1) do
        try do
          page.handle_disconnect(conn)
        rescue
          exception -> log_crash(page, :handle_disconnect, exception, __STACKTRACE__)
        end
      end
    end

    defp maybe_authorize(conn, page, action) do
      if exported?(page, :authorize, 2) do
        page.authorize(conn, action)
      else
        conn
      end
    end

    # mount/2 and authorize/2 share this skip rule: a halted or already
    # staged/sent response must not be overwritten by render or SSE.
    defp response_committed?(%Plug.Conn{halted: true}), do: true
    defp response_committed?(%Plug.Conn{state: state}), do: state != :unset

    # function_exported?/3 alone returns false for modules the code server
    # has not loaded yet, so under lazy loading (dev/test, fresh VM) the
    # first request would silently skip mount/2 or 404 the stream.
    defp exported?(module, fun, arity) do
      Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
    end

    # A message matching no handle_info/2 clause must not kill the stream.
    # Only a FunctionClauseError raised by the head of the page's own
    # handle_info/2 is absorbed; errors inside a matched clause propagate.
    defp dispatch_info(page, msg, conn, opts \\ []) do
      page.handle_info(msg, conn)
    rescue
      exception in FunctionClauseError ->
        if exception.module == page and exception.function == :handle_info and
             exception.arity == 2 do
          # Library-handled messages are dispatched speculatively, so "the
          # page has no clause for this" is the expected case, not a warning.
          if Keyword.get(opts, :warn_unhandled, true) do
            Logger.warning("#{inspect(page)} received unhandled message: #{inspect(msg)}")
          end

          conn
        else
          crash(page, :handle_info, conn, exception, __STACKTRACE__)
        end

      exception ->
        crash(page, :handle_info, conn, exception, __STACKTRACE__)
    end

    # One crash policy for every callback that runs on an open SSE stream:
    # log it, relay it to the browser console when `debug_errors` is set,
    # then re-raise so the adapter ends the request.
    defp guard(page, callback, conn, fun) do
      fun.()
    rescue
      exception -> crash(page, callback, conn, exception, __STACKTRACE__)
    end

    defp crash(page, callback, conn, exception, stacktrace) do
      log_crash(page, callback, exception, stacktrace)

      if Application.get_env(:dstar, :debug_errors, false) do
        # Best-effort: if the conn died mid-stream, console_log raising
        # here would shadow the original exception.
        try do
          Dstar.console_log(conn, Exception.format(:error, exception, stacktrace), level: :error)
        rescue
          _ -> :ok
        end
      end

      reraise exception, stacktrace
    end

    defp log_crash(page, callback, exception, stacktrace) do
      Logger.error(
        "Dstar.Page.Plug: #{inspect(page)}.#{callback} raised:\n" <>
          Exception.format(:error, exception, stacktrace)
      )
    end
  end
end
