defmodule Dstar.Page.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Dstar.Test

  alias Dstar.Page.Plug, as: PagePlug

  defmodule CounterPage do
    use Dstar.Page

    def mount(conn, params) do
      assign(conn, count: String.to_integer(params["start"] || "0"))
    end

    def render(assigns) do
      ~H"""
      <div data-signals:count={@count}>
        <button data-on:click={event("increment")}>+1</button>
      </div>
      """
    end

    def handle_event(conn, "increment", signals) do
      count = (signals["count"] || 0) + 1

      conn
      |> patch_signals(%{count: count})
      |> patch(&history/1, value: count)
    end

    defp history(assigns) do
      ~H"""
      <span id="history">Last: {@value}</span>
      """
    end
  end

  defmodule RedirectPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> Plug.Conn.put_resp_header("location", "/login")
      |> Plug.Conn.send_resp(302, "")
    end

    def render(assigns), do: ~H'<div id="never">never rendered</div>'
  end

  defmodule BarePage do
    use Dstar.Page

    def render(assigns), do: ~H'<div id="bare">bare</div>'
  end

  defmodule HaltedPage do
    use Dstar.Page

    def mount(conn, _params) do
      conn
      |> Plug.Conn.send_resp(401, "unauthorized")
      |> Plug.Conn.halt()
    end

    def render(assigns), do: ~H'<div id="never-halted">never rendered</div>'
  end

  defmodule StreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="s">stream</div>'

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:connected, self()})
      conn
    end

    def handle_info({:tick, n}, conn), do: patch_signals(conn, %{tick: n})

    def handle_info({:ping, from}, conn) do
      send(from, :pong)
      conn
    end

    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  defmodule KeyedStreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="k">keyed</div>'

    def stream_key(_conn), do: :test_scope

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:keyed_connected, self()})
      conn
    end

    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  defmodule AuthEventPage do
    use Dstar.Page

    def render(assigns), do: ~H'<div id="a">auth event</div>'

    def authorize(conn, {:event, "secret"}) do
      conn
      |> Plug.Conn.send_resp(403, "Forbidden")
      |> Plug.Conn.halt()
    end

    def authorize(conn, {:event, "silent"}) do
      conn
      |> Plug.Conn.put_resp_header("x-denied", "1")
      |> Plug.Conn.send_resp(401, "Unauthorized")
    end

    def authorize(conn, {:event, _event}) do
      assign(conn, :from_authorize, true)
    end

    def handle_event(conn, "secret", _signals) do
      send(:dstar_plug_auth_test, :handle_event_ran)
      patch_signals(conn, %{leaked: true})
    end

    def handle_event(conn, "silent", _signals) do
      send(:dstar_plug_auth_test, :handle_event_ran)
      patch_signals(conn, %{leaked: true})
    end

    def handle_event(conn, "increment", _signals) do
      patch_signals(conn, %{ok: true, from_authorize: conn.assigns.from_authorize})
    end
  end

  defmodule AuthStreamPage do
    use Dstar.Page, idle_check: 50

    def render(assigns), do: ~H'<div id="as">auth stream</div>'

    def authorize(conn, {:stream, _params}) do
      case conn.assigns[:current_user] do
        nil ->
          conn
          |> Plug.Conn.send_resp(401, "Unauthorized")
          |> Plug.Conn.halt()

        user ->
          assign(conn, :scope_user, user)
      end
    end

    def stream_key(conn) do
      send(:dstar_plug_stream_test, {:stream_key, conn.assigns.scope_user})
      {:auth_scope, conn.assigns.scope_user}
    end

    def handle_connect(conn, _params) do
      send(:dstar_plug_stream_test, {:connected, self(), conn.assigns.scope_user})
      conn
    end

    def handle_info(:halt_now, conn), do: {:halt, conn}
  end

  describe "authorize/2 before SSE (#28)" do
    alias Dstar.Utility.StreamRegistry

    test "rejects an event POST with 403 without starting SSE or calling handle_event" do
      Process.register(self(), :dstar_plug_auth_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_auth_test)
        rescue
          _ -> :ok
        end
      end)

      conn = event_conn("secret", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, AuthEventPage}))

      assert conn.status == 403
      assert conn.state == :sent
      assert conn.resp_body == "Forbidden"
      refute_received :handle_event_ran
    end

    test "send_resp without halt still skips SSE" do
      Process.register(self(), :dstar_plug_auth_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_auth_test)
        rescue
          _ -> :ok
        end
      end)

      conn = event_conn("silent", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, AuthEventPage}))

      assert conn.status == 401
      assert conn.state == :sent
      refute_received :handle_event_ran
    end

    test "authorized event POSTs keep authorize/2 assigns and start SSE" do
      # Direct POST — no preceding GET / mount/2.
      conn = event_conn("increment", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, AuthEventPage}))

      assert conn.state == :chunked
      assert conn.status == 200
      assert_patched_signals(conn, %{ok: true, from_authorize: true})
    end

    test "rejects a stream POST with 401 before stream_key, register, or handle_connect" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      conn =
        conn(:post, "/stream")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"tabId" => "tab-denied"})

      conn = PagePlug.call(conn, PagePlug.init({:stream, AuthStreamPage}))

      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body == "Unauthorized"
      refute_received {:stream_key, _}
      refute_received {:connected, _, _}
      assert Registry.lookup(StreamRegistry, {{:auth_scope, :alice}, "tab-denied"}) == []
    end

    test "authorized stream POSTs keep authorize/2 assigns for stream_key and handle_connect" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      # Direct POST — no preceding GET / mount/2.
      conn =
        conn(:post, "/stream")
        |> Plug.Conn.assign(:current_user, :alice)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"tabId" => "tab-ok"})

      task =
        Task.async(fn ->
          PagePlug.call(conn, PagePlug.init({:stream, AuthStreamPage}))
        end)

      assert_receive {:stream_key, :alice}, 1_000
      assert_receive {:connected, stream_pid, :alice}, 1_000

      assert [{^stream_pid, _}] =
               Registry.lookup(StreamRegistry, {{:auth_scope, :alice}, "tab-ok"})

      send(stream_pid, :halt_now)
      conn = Task.await(task, 2_000)
      assert conn.state == :chunked
    end
  end

  describe "event action (POST _event/:event)" do
    defp event_conn(event, signals) do
      conn(:post, "/counter/_event/#{event}")
      |> Map.put(:path_params, %{"event" => event})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:body_params, signals)
    end

    test "starts SSE and dispatches to handle_event with signals" do
      conn = event_conn("increment", %{"count" => 2})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))

      assert conn.state == :chunked
      assert conn.status == 200
      assert_patched_signals(conn, %{count: 3})
      assert_patched_element(conn, "#history")
    end

    test "handlers never call Dstar.start themselves" do
      # CounterPage.handle_event has no Dstar.start — reaching :chunked
      # proves the plug started SSE.
      conn = event_conn("increment", %{})
      conn = PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      assert conn.state == :chunked
    end

    test "with debug_errors, a crash is relayed to the browser console and re-raised" do
      Application.put_env(:dstar, :debug_errors, true)
      on_exit(fn -> Application.delete_env(:dstar, :debug_errors) end)

      conn = event_conn("explode", %{})

      assert_raise FunctionClauseError, fn ->
        PagePlug.call(conn, PagePlug.init({:event, CounterPage}))
      end
    end
  end

  describe "stream action (POST)" do
    test "404s when the page has no handle_connect" do
      conn = PagePlug.call(conn(:post, "/bare"), PagePlug.init({:stream, BarePage}))
      assert conn.status == 404
    end

    test "connects, dispatches handle_info, tolerates strays, halts on demand" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/stream"), PagePlug.init({:stream, StreamPage}))
        end)

      assert_receive {:connected, stream_pid}, 1_000

      send(stream_pid, {:tick, 7})
      send(stream_pid, :unmatched_stray_message)
      send(stream_pid, {:tick, 8})
      send(stream_pid, :halt_now)

      conn = Task.await(task, 2_000)

      assert conn.state == :chunked
      assert_patched_signals(conn, %{tick: 8})
      # The stray message did not kill the loop: tick 8 arrived after it.
    end

    test "leaves Bandit flow-control messages in the mailbox" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/stream"), PagePlug.init({:stream, StreamPage}))
        end)

      assert_receive {:connected, stream_pid}, 1_000

      # Bandit's HTTP/2 stream consumes these by selective receive in its
      # send path; the loop must skip them, not dispatch or drop them.
      send(stream_pid, {:bandit, {:send_window_update, 1234}})
      send(stream_pid, {:ping, self()})

      # The pong proves the loop processed a message queued BEHIND the
      # Bandit message, which therefore was skipped over, not consumed.
      assert_receive :pong, 1_000

      assert {:messages, [{:bandit, {:send_window_update, 1234}}]} =
               Process.info(stream_pid, :messages)

      send(stream_pid, :halt_now)
      conn = Task.await(task, 2_000)
      assert conn.state == :chunked
    end

    test "opens via start_stream when stream_key/1 is defined" do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      task =
        Task.async(fn ->
          PagePlug.call(conn(:post, "/keyed"), PagePlug.init({:stream, KeyedStreamPage}))
        end)

      assert_receive {:keyed_connected, stream_pid}, 1_000
      send(stream_pid, :halt_now)

      conn = Task.await(task, 2_000)
      assert conn.state == :chunked
    end
  end

  describe "stream teardown (#18)" do
    alias Dstar.Utility.StreamRegistry

    defmodule TeardownPage do
      use Dstar.Page, idle_check: 50

      def render(assigns), do: ~H'<div id="t">teardown</div>'

      def stream_key(_conn), do: :teardown_scope

      def handle_connect(conn, _params) do
        send(:dstar_plug_stream_test, {:connected, self()})
        conn
      end

      def handle_info(:halt_now, conn), do: {:halt, conn}
    end

    defmodule DisconnectPage do
      use Dstar.Page, idle_check: 50

      def render(assigns), do: ~H'<div id="d">disconnect</div>'

      def stream_key(_conn), do: :teardown_scope

      def handle_connect(conn, _params) do
        send(:dstar_plug_stream_test, {:connected, self()})
        conn
      end

      def handle_disconnect(conn) do
        send(:dstar_plug_stream_test, {:disconnected, self()})
        conn
      end

      def handle_info(:halt_now, conn), do: {:halt, conn}
    end

    setup do
      Process.register(self(), :dstar_plug_stream_test)

      on_exit(fn ->
        try do
          Process.unregister(:dstar_plug_stream_test)
        rescue
          _ -> :ok
        end
      end)

      :ok
    end

    # The stream must be driven by a process that OUTLIVES the loop, the way
    # a Bandit keep-alive connection process is reused for the next request.
    # Running it in a Task would let the process death clean the Registry up
    # and hide the leak entirely.
    defp run_stream(page, tab_id, opts \\ []) do
      parent = self()
      trap_exits? = Keyword.get(opts, :trap_exits, false)

      conn =
        conn(:post, "/keyed")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"tabId" => tab_id})

      pid =
        spawn(fn ->
          # Bandit connection processes trap exits; that is what turns the
          # registry's :replaced signal into a message instead of a kill.
          if trap_exits?, do: Process.flag(:trap_exit, true)
          returned = PagePlug.call(conn, PagePlug.init({:stream, page}))
          send(parent, {:loop_returned, returned})
          Process.sleep(:infinity)
        end)

      assert_receive {:connected, ^pid}, 1_000
      pid
    end

    test "releases its registry key when the loop halts" do
      pid = run_stream(TeardownPage, "tab-teardown-1")

      assert [{^pid, _}] = Registry.lookup(StreamRegistry, {:teardown_scope, "tab-teardown-1"})

      send(pid, :halt_now)
      assert_receive {:loop_returned, _conn}, 1_000

      # The connection process is still alive — as it would be between
      # keep-alive requests — so nothing but the loop can have released this.
      assert Process.alive?(pid)
      assert Registry.lookup(StreamRegistry, {:teardown_scope, "tab-teardown-1"}) == []

      Process.exit(pid, :kill)
    end

    test "calls handle_disconnect/1 when the loop halts" do
      pid = run_stream(DisconnectPage, "tab-teardown-2")

      send(pid, :halt_now)

      assert_receive {:disconnected, ^pid}, 1_000
      assert_receive {:loop_returned, _conn}, 1_000

      Process.exit(pid, :kill)
    end

    test "a takeover by a newer stream halts and tears down the old one (#17)" do
      # End to end: the old stream traps exits like a real connection
      # process, so the registry's :replaced signal lands as a message.
      # Without the library handling it, this stream would log an unhandled
      # message and keep running as a zombie holding the key.
      pid = run_stream(DisconnectPage, "tab-takeover", trap_exits: true)
      parent = self()

      spawn(fn ->
        StreamRegistry.replace_and_register({:teardown_scope, "tab-takeover"})
        send(parent, {:took_over, self()})
        Process.sleep(:infinity)
      end)

      assert_receive {:disconnected, ^pid}, 2_000
      assert_receive {:loop_returned, _conn}, 1_000
      assert_receive {:took_over, new_pid}, 1_000

      # Graceful: the old process released the key and was left alive,
      # rather than being killed mid-request.
      assert Process.alive?(pid)
      assert [{^new_pid, _}] = Registry.lookup(StreamRegistry, {:teardown_scope, "tab-takeover"})

      Process.exit(pid, :kill)
      Process.exit(new_pid, :kill)
    end

    defmodule StalePage do
      use Dstar.Page, idle_check: 50

      def render(assigns), do: ~H'<div id="st">stale</div>'

      def stream_key(_conn), do: :teardown_scope

      def handle_connect(conn, _params) do
        send(:dstar_plug_stream_test, {:connected, self()})
        conn
      end

      def handle_info({:ping, from}, conn) do
        send(from, :pong)
        conn
      end

      def handle_info(:halt_now, conn), do: {:halt, conn}
    end

    defmodule OwnReplacedClausePage do
      use Dstar.Page, idle_check: 50

      def render(assigns), do: ~H'<div id="o">own clause</div>'

      def stream_key(_conn), do: :teardown_scope

      def handle_connect(conn, _params) do
        send(:dstar_plug_stream_test, {:connected, self()})
        conn
      end

      # Apps wrote this clause before the library handled the signal — it
      # must keep running, or their cleanup silently stops happening.
      def handle_info({:EXIT, _pid, :replaced}, conn) do
        send(:dstar_plug_stream_test, {:own_clause_ran, self()})
        {:halt, conn}
      end

      def handle_info(:halt_now, conn), do: {:halt, conn}
    end

    test "a page's own {:EXIT, _, :replaced} clause still runs on takeover" do
      pid = run_stream(OwnReplacedClausePage, "tab-own-clause", trap_exits: true)

      send(pid, {:EXIT, self(), :replaced})

      assert_receive {:own_clause_ran, ^pid}, 1_000
      assert_receive {:loop_returned, _conn}, 1_000

      Process.exit(pid, :kill)
    end

    test "a takeover on a page with no such clause logs no unhandled-message warning" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          pid = run_stream(DisconnectPage, "tab-quiet", trap_exits: true)
          send(pid, {:EXIT, self(), :replaced})
          assert_receive {:disconnected, ^pid}, 1_000
          assert_receive {:loop_returned, _conn}, 1_000
          Process.exit(pid, :kill)
        end)

      refute log =~ "unhandled message"
    end

    test "a stale :replaced left in the mailbox does not kill the next stream" do
      # Keep-alive connection processes are reused across requests, and their
      # mailbox survives with them. A takeover signal that arrived after the
      # previous loop stopped receiving is still sitting there — it must not
      # be mistaken for a takeover of the stream that comes next.
      parent = self()

      conn =
        conn(:post, "/keyed")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"tabId" => "tab-stale"})

      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          # Left over from the previous request on this socket.
          send(self(), {:EXIT, parent, :replaced})

          returned = PagePlug.call(conn, PagePlug.init({:stream, StalePage}))
          send(parent, {:loop_returned, returned})
          Process.sleep(:infinity)
        end)

      assert_receive {:connected, ^pid}, 1_000

      # A live stream answers; a poisoned one has already torn down.
      send(pid, {:ping, self()})
      assert_receive :pong, 1_000
      refute_received {:loop_returned, _}

      send(pid, :halt_now)
      assert_receive {:loop_returned, _conn}, 1_000
      Process.exit(pid, :kill)
    end

    test "a page without handle_disconnect/1 still tears down" do
      assert Code.ensure_loaded?(TeardownPage)
      refute function_exported?(TeardownPage, :handle_disconnect, 1)

      pid = run_stream(TeardownPage, "tab-teardown-3")
      send(pid, :halt_now)

      assert_receive {:loop_returned, conn}, 1_000
      assert conn.state == :chunked

      Process.exit(pid, :kill)
    end
  end

  describe "page action (GET)" do
    test "mounts and renders HTML 200" do
      conn = conn(:get, "/counter?start=5")
      conn = PagePlug.call(conn, PagePlug.init({:page, CounterPage}))

      assert conn.status == 200
      assert conn.state == :sent

      assert {"content-type", "text/html" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert conn.resp_body =~ "data-signals:count=\"5\""
    end

    test "works without a mount callback" do
      conn = PagePlug.call(conn(:get, "/bare"), PagePlug.init({:page, BarePage}))
      assert conn.status == 200
      assert conn.resp_body =~ "bare"
    end

    test "skips render when mount already sent a response" do
      conn = PagePlug.call(conn(:get, "/r"), PagePlug.init({:page, RedirectPage}))
      assert conn.status == 302
      refute conn.resp_body =~ "never rendered"
    end

    test "skips render when mount halts after sending (auth pattern)" do
      conn = PagePlug.call(conn(:get, "/h"), PagePlug.init({:page, HaltedPage}))
      assert conn.status == 401
      assert conn.halted
      refute conn.resp_body =~ "never rendered"
    end

    test "mounts pages the code server has not loaded yet" do
      # On a fresh VM (lazy code loading) the page beam sits on disk unloaded.
      # function_exported?/3 alone would report no mount/2 and skip it.
      [{mod, beam}] =
        Code.compile_string("""
        defmodule Dstar.Page.PlugTest.LazyPage do
          use Dstar.Page

          def mount(conn, _params), do: assign(conn, marker: "lazy-mounted")

          def render(assigns), do: ~H"<div id='lazy'>{@marker}</div>"
        end
        """)

      dir = Path.join(System.tmp_dir!(), "dstar_lazy_page_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{mod}.beam"), beam)
      true = Code.append_path(dir)

      on_exit(fn ->
        Code.delete_path(dir)
        :code.purge(mod)
        :code.delete(mod)
        File.rm_rf!(dir)
      end)

      # Unload the freshly created module so only the on-disk beam remains.
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
      refute :erlang.module_loaded(mod)

      conn = PagePlug.call(conn(:get, "/lazy"), PagePlug.init({:page, mod}))

      assert conn.status == 200
      assert conn.resp_body =~ "lazy-mounted"
    end
  end
end
