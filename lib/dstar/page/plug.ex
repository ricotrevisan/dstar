if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Dstar.Page.Plug do
    @moduledoc """
    The plug behind `Dstar.Router.dstar/2`. Drives `Dstar.Page` callbacks:

    - `{:page, Module}` — GET: `mount/2` then `render/1` through Phoenix's
      view pipeline (root layout, flash, `page_title` all apply).
    - `{:event, Module}` — POST `_event/:event`: reads signals, optional
      `authorize/2`, starts SSE, calls `handle_event/3`.
    - `{:stream, Module}` — POST: optional `authorize/2`, starts SSE
      (deduped when `stream_key/1` is defined), calls `handle_connect/2`,
      then owns the receive loop dispatching to `handle_info/2`.

    `authorize/2` is the pre-SSE seam: a halted or already-staged
    response is returned as ordinary HTTP and SSE never starts.
    `mount/2` does not run on event or stream POSTs.

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
      conn = fetch_query_params(conn)

      event =
        conn.path_params["event"] ||
          raise(
            ArgumentError,
            "missing :event path param — route the event POST with an `:event` segment"
          )

      signals = Dstar.Signals.read(conn)
      conn = maybe_authorize(conn, page, {:event, event})

      if response_committed?(conn) do
        conn
      else
        conn = Dstar.SSE.start(conn)
        dispatch_event(conn, page, event, signals)
      end
    end

    defp dispatch_event(conn, page, event, signals) do
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
      if exported?(page, :handle_connect, 2) do
        conn = fetch_query_params(conn)
        conn = maybe_authorize(conn, page, {:stream, conn.params})

        if response_committed?(conn) do
          conn
        else
          open_stream(conn, page)
        end
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
      end
    end

    defp open_stream(conn, page) do
      conn =
        if function_exported?(page, :stream_key, 1) do
          Dstar.start_stream(conn, page.stream_key(conn))
        else
          Dstar.SSE.start(conn)
        end

      drain_stale_replaced()

      conn =
        try do
          page.handle_connect(conn, conn.params)
        rescue
          exception ->
            log_crash(page, :handle_connect, exception, __STACKTRACE__)
            reraise exception, __STACKTRACE__
        end

      loop(conn, page, page.__dstar__(:idle_check))
    end

    defp loop(conn, page, idle_check) do
      receive do
        # Plug adapters notify the conn owner when the response is sent;
        # this is internal plumbing, never a page message.
        {:plug_conn, :sent} ->
          loop(conn, page, idle_check)

        # Bandit's HTTP/2 stream runs in this same process and delivers
        # flow-control messages ({:bandit, {:send_window_update, _}} etc.)
        # to its mailbox, consuming them by selective receive inside its
        # send path. The guard skips them so they stay in the mailbox —
        # consuming them here would break flow control and stall the
        # stream once the send window drains.
        # A newer stream for the same `stream_key/1` is taking over. Bandit
        # connection processes trap exits, so `Dstar.Utility.StreamRegistry`'s
        # `Process.exit(pid, :replaced)` lands here as a message rather than
        # killing us — halting is what makes the takeover take effect. Without
        # this the old stream survives as a zombie holding the registry key,
        # and every page would have to write this clause itself.
        #
        # The page still gets first refusal, because apps wrote this clause
        # before the library handled the signal and their cleanup must keep
        # running. Whatever it returns, the stream then ends: a takeover is
        # not something a page may decline.
        {:EXIT, _pid, :replaced} = msg ->
          conn
          |> offer_replaced(page, msg)
          |> teardown(page)

        msg when not is_tuple(msg) or tuple_size(msg) != 2 or elem(msg, 0) != :bandit ->
          case dispatch_info(page, msg, conn) do
            {:halt, conn} -> teardown(conn, page)
            conn -> loop(conn, page, idle_check)
          end
      after
        idle_check ->
          case Dstar.check_connection(conn) do
            {:ok, conn} -> loop(conn, page, idle_check)
            {:error, conn} -> teardown(conn, page)
          end
      end
    end

    # A keep-alive connection process is reused across requests and keeps its
    # mailbox. A takeover signal that arrived after the previous loop stopped
    # receiving is still parked there, and the loop below cannot tell it from
    # a takeover of *this* stream — it would tear down a fresh stream nobody
    # replaced, silently.
    #
    # Draining here is safe by construction: a `:replaced` meant for this
    # stream can only be sent by a taker that found this process in the
    # registry, which cannot happen before the registration just above. A
    # legitimate signal landing inside the microsecond window between the two
    # is backstopped by the taker's kill escalation.
    defp drain_stale_replaced do
      receive do
        {:EXIT, _pid, :replaced} -> drain_stale_replaced()
      after
        0 -> :ok
      end
    end

    # Streaming pages need handle_connect/2 but not handle_info/2, so this
    # dispatch is speculative on both counts: the callback may not exist, and
    # if it does it may have no clause for this message. Neither is an error.
    defp offer_replaced(conn, page, msg) do
      if exported?(page, :handle_info, 2) do
        case dispatch_info(page, msg, conn, warn_unhandled: false) do
          {:halt, conn} -> conn
          conn -> conn
        end
      else
        conn
      end
    end

    # Registry entries and PubSub subscriptions are released when the owning
    # process dies. Under HTTP/1.1 keep-alive the connection process does NOT
    # die when the stream ends — it is reused for the next request on that
    # socket — so without this everything the stream registered stays
    # registered, owned by a process now serving unrelated traffic.
    defp teardown(conn, page) do
      Dstar.Utility.StreamRegistry.unregister_self()

      if exported?(page, :handle_disconnect, 1) do
        try do
          page.handle_disconnect(conn)
        rescue
          exception -> log_crash(page, :handle_disconnect, exception, __STACKTRACE__)
        end
      end

      conn
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
          log_crash(page, :handle_info, exception, __STACKTRACE__)
          reraise exception, __STACKTRACE__
        end

      exception ->
        log_crash(page, :handle_info, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    end

    defp log_crash(page, callback, exception, stacktrace) do
      Logger.error(
        "Dstar.Page.Plug: #{inspect(page)}.#{callback} raised:\n" <>
          Exception.format(:error, exception, stacktrace)
      )
    end
  end
end
