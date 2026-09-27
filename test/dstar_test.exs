defmodule DstarTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Dstar.Test

  # Nested so the atom exists for decode_module and the encoded segment is
  # deterministic: DstarTest.MyApp.CounterView -> "dstar_test-my_app-counter_view"
  defmodule MyApp.CounterView do
  end

  # ── Connection lifecycle ─────────────────────────────────────────────

  describe "start/1" do
    test "opens a chunked SSE response with SSE headers" do
      conn = Dstar.start(conn(:get, "/ds"))

      assert conn.status == 200
      assert conn.state == :chunked

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "text/event-stream; charset=utf-8"
             ]

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  describe "check_connection/1" do
    test "reports an open chunked stream" do
      conn = Dstar.start(conn(:get, "/ds"))

      assert {:ok, _conn} = Dstar.check_connection(conn)
    end

    test "reports a closed stream when the adapter refuses the chunk" do
      assert {:error, _conn} = Dstar.check_connection(conn(:get, "/ds"))
    end
  end

  # ── Signals ──────────────────────────────────────────────────────────

  describe "fetch_signals/2" do
    test "parses a JSON object body and returns the updated conn" do
      conn =
        conn(:post, "/ds", ~s({"count": 1}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      assert {:ok, %{"count" => 1}, fetched} = Dstar.fetch_signals(conn)
      assert Dstar.read_signals(fetched) == %{"count" => 1}
    end

    test "reads GET signals from the datastar query parameter" do
      conn = conn(:get, "/ds?datastar=" <> URI.encode_www_form(~s({"q":"x"})))

      assert {:ok, %{"q" => "x"}, _conn} = Dstar.fetch_signals(conn)
    end

    test "reports malformed JSON instead of treating it as empty signals" do
      assert {:error, :malformed, _conn} = Dstar.fetch_signals(conn(:post, "/ds", "{"))
    end

    test "reports oversized payloads" do
      json = ~s({"a":1})

      assert {:error, :too_large, _conn} =
               Dstar.fetch_signals(conn(:post, "/ds", json), max_bytes: byte_size(json) - 1)
    end
  end

  describe "read_signals/1" do
    test "reads already-fetched body params" do
      conn = conn(:post, "/ds") |> Map.put(:body_params, %{"count" => 10})

      assert Dstar.read_signals(conn) == %{"count" => 10}
    end

    test "raises on unfetched GET query params" do
      assert_raise ArgumentError, fn -> Dstar.read_signals(conn(:get, "/ds")) end
    end
  end

  describe "patch_signals/2,3" do
    test "patches signals over SSE" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.patch_signals(%{count: 42})

      assert_patched_signals(conn, %{count: 42})
    end
  end

  describe "remove_signals/2,3" do
    test "removes a single path and a list of paths" do
      conn =
        conn(:get, "/ds")
        |> Dstar.start()
        |> Dstar.remove_signals("user.profile.theme")
        |> Dstar.remove_signals(["user.name", "user.email"])

      patched = patched_signals(conn)
      assert get_in(patched, ~w(user profile theme)) == nil
      assert get_in(patched, ~w(user name)) == nil
      assert get_in(patched, ~w(user email)) == nil
    end
  end

  describe "nudge/2,3" do
    test "bumps a monotonic nudge value for the key" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.nudge("posts")

      assert is_integer(get_in(patched_signals(conn), ~w(nudges posts)))
    end
  end

  # ── Elements ─────────────────────────────────────────────────────────

  describe "patch_elements/3" do
    test "targets the given selector" do
      conn =
        conn(:get, "/ds")
        |> Dstar.start()
        |> Dstar.patch_elements(~s(<span id="count">42</span>), selector: "#count")

      assert_patched_element(conn, "#count")
    end

    test "with no selector targets the element's id" do
      conn =
        conn(:get, "/ds")
        |> Dstar.start()
        |> Dstar.patch_elements(~s(<span id="count">42</span>), [])

      assert_patched_element(conn, "#count")
    end
  end

  describe "remove_elements/2,3" do
    test "removes by selector" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.remove_elements("#old-item")

      assert_patched_element(conn, "#old-item")
    end
  end

  describe "append_elements/3,4" do
    test "appends into the container" do
      conn =
        conn(:get, "/ds")
        |> Dstar.start()
        |> Dstar.append_elements(~s(<li id="post-1">post</li>), "#posts")

      assert_patched_element(conn, "#posts")
      assert conn.resp_body =~ ~s(<li id="post-1">post</li>)
    end
  end

  describe "upsert_elements/2,3" do
    test "morphs the element matching the html id" do
      conn =
        conn(:get, "/ds")
        |> Dstar.start()
        |> Dstar.upsert_elements(~s(<li id="post-2">edited</li>))

      assert_patched_element(conn, "#post-2")
    end
  end

  # ── Scripts ──────────────────────────────────────────────────────────

  describe "execute_script/2,3" do
    test "appends the script to the client" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.execute_script("alert('Hello!')")

      assert conn.resp_body =~ "alert('Hello!')"
    end
  end

  describe "redirect/2,3" do
    test "follows the same-origin default policy" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.redirect("/workspaces")

      assert conn.resp_body =~ "location.href"
      assert conn.resp_body =~ "/workspaces"
    end

    test "rejects off-origin destinations unless external: true" do
      started = Dstar.start(conn(:get, "/ds"))

      assert_raise ArgumentError, fn -> Dstar.redirect(started, "https://evil.example/x") end

      allowed = Dstar.redirect(started, "https://ok.example/docs", external: true)
      assert allowed.resp_body =~ "https://ok.example/docs"
    end
  end

  describe "console_log/2,3" do
    test "logs to the browser console" do
      conn = conn(:get, "/ds") |> Dstar.start() |> Dstar.console_log("Debug info")

      assert conn.resp_body =~ "console.log"
      assert conn.resp_body =~ "Debug info"
    end
  end

  # ── Actions ──────────────────────────────────────────────────────────

  describe "action verb helpers" do
    for verb <- [:post, :get, :put, :patch, :delete] do
      test "#{verb}/2,3 delegates to Dstar.Actions" do
        verb = unquote(verb)

        assert apply(Dstar, verb, [MyApp.CounterView, "increment"]) ==
                 apply(Dstar.Actions, verb, [MyApp.CounterView, "increment"])

        assert apply(Dstar, verb, ["increment"]) ==
                 apply(Dstar.Actions, verb, ["increment"])

        assert apply(Dstar, verb, [MyApp.CounterView, "increment", [prefix: "/app"]]) ==
                 apply(Dstar.Actions, verb, [MyApp.CounterView, "increment", [prefix: "/app"]])
      end
    end

    test "post/2 builds the documented route segment" do
      assert Dstar.post(MyApp.CounterView, "increment") ==
               ~s|@post("/ds/dstar_test-my_app-counter_view/increment")|
    end

    test "dynamic event form percent-encodes the module signal in the browser" do
      assert Dstar.post("save") =~ "encodeURIComponent"
    end

    test "deprecated event/2 matches post/2" do
      assert Dstar.event(MyApp.CounterView, "increment") ==
               Dstar.post(MyApp.CounterView, "increment")
    end
  end

  # ── Streams ──────────────────────────────────────────────────────────

  describe "start_stream/2,3" do
    test "falls back to an ordinary SSE stream when no tabId is present" do
      conn = Dstar.start_stream(conn(:get, "/stream"), make_ref())

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.private[:dstar_stream_claim] == nil
    end

    test "responds 413 when signals exceed max_bytes" do
      conn = Dstar.start_stream(conn(:post, "/stream", ~s({"a":1})), :scope, max_bytes: 3)

      assert conn.status == 413
      assert conn.halted
    end
  end
end
