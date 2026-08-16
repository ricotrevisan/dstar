defmodule Dstar.Plugs.Dispatch do
  @moduledoc """
  Dynamic event dispatch plug.

  Routes `POST /ds/:module/:event` requests to handler modules.
  Each handler module implements `handle_event(conn, event, signals)`.

  ## Usage

      # In your Phoenix router:
      post "/ds/:module/:event", Dstar.Plugs.Dispatch, modules: [
        MyAppWeb.CounterHandler,
        MyAppWeb.TodoHandler
      ]

      # Handler module — just a plain module with a function:
      defmodule MyAppWeb.CounterHandler do
        def handle_event(conn, "increment", signals) do
          count = signals["count"] || 0

          conn
          |> Dstar.start()
          |> Dstar.patch_signals(%{count: count + 1})
        end
      end

  ## Options

  - `:modules` — Required. List of allowed handler modules.
  - `:max_signal_bytes` — Maximum raw signal JSON size (default `1_000_000`).
    If `Plug.Parsers` runs first, configure its `:length` and `:read_length`
    to the same or a smaller value.

  Malformed and non-object signal payloads receive 400, and oversized raw
  payloads receive 413. Dispatch returns those responses before calling the
  handler, so an SSE response has not yet started.

  """

  @behaviour Plug

  require Logger
  import Plug.Conn

  alias Dstar.{Actions, Signals}

  @impl Plug
  def init(opts) do
    modules = Keyword.fetch!(opts, :modules)

    # Pre-build lookup map: encoded_name => module
    lookup =
      Map.new(modules, fn mod ->
        {Actions.encode_module(mod), mod}
      end)

    %{
      lookup: lookup,
      max_signal_bytes: Keyword.get(opts, :max_signal_bytes, Dstar.Signals.default_max_bytes())
    }
  end

  @impl Plug
  def call(conn, %{lookup: lookup, max_signal_bytes: max_signal_bytes}) do
    conn = fetch_query_params(conn)

    module_param = conn.path_params["module"] || conn.params["module"]
    event = conn.path_params["event"] || conn.params["event"]

    case Map.fetch(lookup, module_param) do
      {:ok, module} ->
        case Signals.fetch(conn, max_bytes: max_signal_bytes) do
          {:ok, signals, conn} -> dispatch(conn, module, event, signals)
          {:error, reason, conn} -> Signals.send_error(conn, reason)
        end

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
    end
  end

  defp dispatch(conn, module, event, signals) do
    module.handle_event(conn, event, signals)
  rescue
    exception ->
      Logger.error(
        "Dstar.Plugs.Dispatch: #{inspect(module)}.handle_event(#{inspect(event)}) raised:\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      reraise exception, __STACKTRACE__
  end
end
