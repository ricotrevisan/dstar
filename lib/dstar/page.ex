defmodule Dstar.Page do
  @moduledoc """
  One module per page: render, event handlers, stream callbacks, and
  colocated function components.

      defmodule MyAppWeb.CounterPage do
        use Dstar.Page

        def mount(conn, _params), do: assign(conn, count: 0)

        def render(assigns) do
          ~H\"\"\"
          <div data-signals:count={@count}>
            <button data-on:click={event("increment")}>+1</button>
          </div>
          \"\"\"
        end

        def handle_event(conn, "increment", signals) do
          patch_signals(conn, %{count: (signals["count"] || 0) + 1})
        end
      end

  Route it with `Dstar.Router.dstar/2`:

      import Dstar.Router
      dstar "/counter", MyAppWeb.CounterPage

  All requests are driven by `Dstar.Page.Plug` — pages contain no
  control flow, only callbacks. Conn in, conn out.

  ## Options

  - `:idle_check` — ms between connection liveness checks in the stream
    loop (default `30_000`).
  """

  @doc "GET: load data and assign what `render/1` needs. Optional."
  @callback mount(Plug.Conn.t(), params :: map()) :: Plug.Conn.t()

  @doc "The full-page HEEx template. Required."
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc "Handles a Datastar event POST. SSE is already started. Optional."
  @callback handle_event(Plug.Conn.t(), event :: String.t(), signals :: map()) :: Plug.Conn.t()

  @doc """
  Stream open: subscribe to topics, assign loop state. Optional —
  defining it enables `POST /path` streaming.
  """
  @callback handle_connect(Plug.Conn.t(), params :: map()) :: Plug.Conn.t()

  @doc "Handles one message from the library-owned receive loop. Optional."
  @callback handle_info(msg :: term(), Plug.Conn.t()) :: Plug.Conn.t() | {:halt, Plug.Conn.t()}

  @doc "If defined, the stream opens via `Dstar.start_stream/2` keyed on the result. Optional."
  @callback stream_key(Plug.Conn.t()) :: term()

  @doc """
  Stream close: release what `handle_connect/2` acquired — unsubscribe,
  untrack presence, drop caches. Optional.

  Runs on every exit from the receive loop: a `{:halt, conn}` from
  `handle_info/2`, a dead client, or a takeover by a newer stream for the
  same `stream_key/1`. The library already unregisters the stream from
  `Dstar.Utility.StreamRegistry` for you; this is for app-owned state.

  The client is usually gone by this point, so treat the conn as
  write-only-on-a-best-effort basis. A crash here is logged and swallowed —
  teardown continues either way. The return value is ignored.

  > #### Best-effort, not guaranteed {: .warning}
  >
  > This runs when the *loop* ends, which requires the process to survive
  > long enough to notice. A takeover that kills the process outright skips
  > it: only Thousand Island (so Bandit HTTP/1.1) connection processes trap
  > exits, whereas Bandit's HTTP/2 stream processes and Cowboy request
  > processes do not, and the registry's escalation kill is untrappable by
  > design.
  >
  > Anything cleaned up by process monitors — `Phoenix.PubSub`
  > subscriptions, `Phoenix.Presence`, the registry entry itself — is
  > released regardless. Reserve this callback for state that is *not*
  > monitor-backed (external caches, rows in another system), and make it
  > idempotent: on a takeover it can interleave with, or run after, the
  > replacing stream's `handle_connect/2`, so cleanup keyed on the tab
  > rather than on this stream can otherwise clobber what the new stream
  > just wrote.
  """
  @callback handle_disconnect(Plug.Conn.t()) :: any()

  @optional_callbacks mount: 2,
                      handle_event: 3,
                      handle_connect: 2,
                      handle_info: 2,
                      stream_key: 1,
                      handle_disconnect: 1

  @default_idle_check 30_000

  defmacro __using__(opts) do
    unless Code.ensure_loaded?(Phoenix.Component) do
      raise ArgumentError, """
      `use Dstar.Page` requires the optional dependencies. Add to your deps:

          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"}
      """
    end

    idle_check = Keyword.get(opts, :idle_check, @default_idle_check)

    quote do
      @behaviour Dstar.Page

      use Phoenix.Component

      # Re-importing overrides the import set from `use Phoenix.Component`,
      # freeing the assign family for the conn/component shim below.
      import Phoenix.Component,
        except: [assign: 2, assign: 3, assign_new: 3, update: 3]

      import Dstar.Page.Assigns

      # Explicit list: `Dstar` also exports URL builders (post/2,3,
      # patch/1,2,3, event/2,3) that collide with the page helpers.
      import Dstar,
        only: [
          start: 1,
          start_stream: 2,
          check_connection: 1,
          read_signals: 1,
          patch_signals: 2,
          patch_signals: 3,
          remove_signals: 2,
          remove_signals: 3,
          patch_elements: 3,
          remove_elements: 2,
          remove_elements: 3,
          append_elements: 3,
          append_elements: 4,
          upsert_elements: 2,
          upsert_elements: 3,
          nudge: 2,
          nudge: 3,
          execute_script: 2,
          execute_script: 3,
          redirect: 2,
          redirect: 3,
          console_log: 2,
          console_log: 3
        ]

      import Dstar.Page.Helpers

      @doc false
      def __dstar__(:idle_check), do: unquote(idle_check)
    end
  end
end
