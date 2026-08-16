defmodule Dstar.SignalsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.{Signals, SSE}

  defmodule SequencedAdapter do
    def read_req_body({test_pid, [{tag, chunk} | rest], reads}, opts)
        when tag in [:ok, :more] do
      send(test_pid, {:sequenced_read, reads, opts})
      {tag, chunk, {test_pid, rest, reads + 1}}
    end

    def read_req_body({test_pid, [{:error, reason} | _rest], reads}, opts) do
      send(test_pid, {:sequenced_read, reads, opts})
      {:error, reason}
    end
  end

  # Helper to create a chunked SSE conn
  defp chunked_conn do
    conn(:post, "/test")
    |> SSE.start()
  end

  describe "frame safety (S1)" do
    test "carriage returns in signal values stay JSON-escaped and never reach the wire" do
      frame = Signals.format_patch(%{name: "a\rb\nc"})

      # Jason escapes control chars, so no raw CR/LF can break the SSE frame.
      refute frame =~ "\r"

      blank_before_terminator? =
        frame
        |> String.replace_suffix("\n\n", "")
        |> String.split(["\r\n", "\r", "\n"])
        |> Enum.any?(&(&1 == ""))

      refute blank_before_terminator?
    end
  end

  describe "fetch/2" do
    test "accepts JSON objects from GET and DELETE query params" do
      for method <- [:get, :delete] do
        conn = conn(method, "/?datastar=" <> URI.encode_www_form(~s({"count":42})))

        assert {:ok, %{"count" => 42}, fetched_conn} = Signals.fetch(conn)
        assert is_map(fetched_conn.query_params)
      end
    end

    test "returns an empty map when no signals are present" do
      assert {:ok, %{}, _conn} = Signals.fetch(conn(:get, "/"))
      assert {:ok, %{}, _conn} = Signals.fetch(conn(:post, "/", ""))
    end

    test "accepts already-fetched body param maps without reading the adapter" do
      conn = conn(:post, "/") |> Map.put(:body_params, %{"count" => 10})

      assert {:ok, %{"count" => 10}, ^conn} = Signals.fetch(conn)
      assert Signals.read(conn) == %{"count" => 10}
    end

    test "rejects Plug.Parsers' _json wrapper for a non-object document" do
      for value <- [[], "value", 42, true, nil] do
        conn = conn(:post, "/") |> Map.put(:body_params, %{"_json" => value})
        assert {:error, :not_an_object, ^conn} = Signals.fetch(conn)
      end
    end

    test "accepts an already-fetched object that has _json plus real signal keys" do
      body_params = %{"_json" => "metadata", "count" => 1}
      conn = conn(:post, "/") |> Map.put(:body_params, body_params)

      assert {:ok, ^body_params, ^conn} = Signals.fetch(conn)
      assert Signals.read(conn) == body_params
    end

    test "rejects arrays, scalars, and null from either transport" do
      for json <- ["[]", ~s("value"), "42", "true", "null"] do
        query_conn = conn(:get, "/?datastar=" <> URI.encode_www_form(json))
        body_conn = conn(:post, "/", json)

        assert {:error, :not_an_object, _conn} = Signals.fetch(query_conn)
        assert {:error, :not_an_object, _conn} = Signals.fetch(body_conn)
      end
    end

    test "reports malformed JSON instead of treating it as empty signals" do
      assert {:error, :malformed, _conn} = Signals.fetch(conn(:post, "/", "{"))

      for json <- ["{", ""] do
        query_conn = conn(:delete, "/?datastar=" <> URI.encode_www_form(json))
        assert {:error, :malformed, _conn} = Signals.fetch(query_conn)
      end
    end

    test "accepts a payload exactly at max_bytes on both transports" do
      json = ~s({"a":1})
      assert byte_size(json) == 7

      assert {:ok, %{"a" => 1}, _conn} = Signals.fetch(conn(:post, "/", json), max_bytes: 7)

      query_conn = conn(:get, "/?datastar=" <> URI.encode_www_form(json))
      assert {:ok, %{"a" => 1}, _conn} = Signals.fetch(query_conn, max_bytes: 7)
    end

    test "rejects raw bodies over max_bytes and returns the updated conn" do
      conn = conn(:post, "/", ~s({"value":"too long"}))

      assert {:error, :too_large, updated_conn} = Signals.fetch(conn, max_bytes: 8)
      assert updated_conn != conn
      assert {:ok, _remaining, drained_conn} = Plug.Conn.read_body(updated_conn)
      assert drained_conn != updated_conn
    end

    test "rejects GET/DELETE payloads over the same max_bytes before decoding" do
      json = ~s({"value":"too long"})

      for method <- [:get, :delete] do
        conn = conn(method, "/?datastar=" <> URI.encode_www_form(json))
        assert {:error, :too_large, _conn} = Signals.fetch(conn, max_bytes: 8)
      end
    end

    test "bounds both adapter read options at max_bytes" do
      test_pid = self()

      defmodule OptionsAdapter do
        def read_req_body({test_pid, body}, opts) do
          send(test_pid, {:read_opts, opts})
          {:ok, body, {test_pid, ""}}
        end
      end

      conn = %{conn(:post, "/") | adapter: {OptionsAdapter, {test_pid, ~s({"ok":true})}}}

      assert {:ok, %{"ok" => true}, _conn} = Signals.fetch(conn, max_bytes: 1234)
      assert_receive {:read_opts, opts}
      assert opts[:length] == 1234
      assert opts[:read_length] == 1234
    end

    test "threads the conn through partial reads and accumulates within the limit" do
      state = {self(), [{:more, ~s({"count)}, {:ok, ~s(":1})}], 0}
      conn = %{conn(:post, "/") | adapter: {SequencedAdapter, state}}

      assert {:ok, %{"count" => 1}, fetched_conn} = Signals.fetch(conn, max_bytes: 20)
      assert {SequencedAdapter, {_test_pid, [], 2}} = fetched_conn.adapter
      assert_receive {:sequenced_read, 0, first_opts}
      assert_receive {:sequenced_read, 1, second_opts}
      assert first_opts[:length] == 20
      assert second_opts[:length] == 13
    end

    test "an adapter error after a partial read returns the latest conn" do
      state = {self(), [{:more, "{"}, {:error, :closed}], 0}
      conn = %{conn(:post, "/") | adapter: {SequencedAdapter, state}}

      assert {:error, {:read_body, :closed}, updated_conn} = Signals.fetch(conn, max_bytes: 20)
      assert {SequencedAdapter, {_test_pid, [{:error, :closed}], 1}} = updated_conn.adapter
    end

    test "returns first-call adapter errors with the original conn" do
      defmodule ErrorAdapter do
        def read_req_body(:state, _opts), do: {:error, :closed}
      end

      conn = %{conn(:post, "/") | adapter: {ErrorAdapter, :state}}

      assert {:error, {:read_body, :closed}, ^conn} = Signals.fetch(conn)
    end

    test "read/1 rejects unfetched raw bodies because it cannot return the updated conn" do
      assert_raise ArgumentError, ~r/Signals.fetch\/2/, fn ->
        Signals.read(conn(:post, "/", ~s({"count":1})))
      end
    end
  end

  describe "format_patch/2" do
    test "formats a basic signal patch" do
      result = Signals.format_patch(%{count: 42})

      assert result ==
               "event: datastar-patch-signals\ndata: signals {\"count\":42}\n\n"
    end

    test "formats with only_if_missing" do
      result = Signals.format_patch(%{count: 0}, only_if_missing: true)
      assert result =~ "onlyIfMissing true"
      assert result =~ "signals {\"count\":0}"
    end
  end

  describe "remove_signals/3" do
    test "removes a single top-level signal" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "count")

      assert result.state == :chunked
    end

    test "removes a nested signal with dot notation" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "user.profile.theme")

      assert result.state == :chunked
    end

    test "removes multiple signals with shared prefix" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, ["user.name", "user.email"])

      assert result.state == :chunked
    end

    test "passes through options" do
      conn = chunked_conn()
      result = Signals.remove_signals(conn, "count", event_id: "remove-1")

      assert result.state == :chunked
    end

    test "raises on empty path" do
      conn = chunked_conn()

      assert_raise ArgumentError, "Signal path cannot be empty", fn ->
        Signals.remove_signals(conn, "")
      end
    end

    test "raises on path with leading dot" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot start with a dot/, fn ->
        Signals.remove_signals(conn, ".user")
      end
    end

    test "raises on path with trailing dot" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot end with a dot/, fn ->
        Signals.remove_signals(conn, "user.")
      end
    end

    test "raises on path with consecutive dots" do
      conn = chunked_conn()

      assert_raise ArgumentError, ~r/cannot contain consecutive dots/, fn ->
        Signals.remove_signals(conn, "user..profile")
      end
    end
  end

  describe "format_remove/2" do
    test "formats removal of a single signal" do
      result = Signals.format_remove("count")

      assert result =~ "\"count\":null"
    end

    test "formats removal of nested signal" do
      result = Signals.format_remove("user.profile")

      assert result =~ "\"user\""
      assert result =~ "\"profile\":null"
    end

    test "formats removal of multiple signals with shared prefix" do
      result = Signals.format_remove(["user.name", "user.email"])

      assert result =~ "\"name\":null"
      assert result =~ "\"email\":null"
    end

    test "formats with only_if_missing option" do
      result = Signals.format_remove("count", only_if_missing: true)

      assert result =~ "onlyIfMissing true"
      assert result =~ "\"count\":null"
    end

    test "raises on invalid path" do
      assert_raise ArgumentError, "Signal path cannot be empty", fn ->
        Signals.format_remove("")
      end
    end
  end

  describe "nudge/3" do
    test "patches an integer under nudges.<key>" do
      conn = Signals.nudge(chunked_conn(), "posts")

      assert %{"nudges" => %{"posts" => value}} = Dstar.Test.patched_signals(conn)
      assert is_integer(value)
    end

    test "sends a different value on every call" do
      # The client only fires data-on-signal-patch when a value actually
      # changes, so two nudges patching the same number would be one nudge.
      conn = chunked_conn() |> Signals.nudge("posts") |> Signals.nudge("posts")

      values =
        conn
        |> Dstar.Test.sse_events()
        |> Enum.flat_map(& &1.data)
        |> Enum.map(fn "signals " <> json -> get_in(Jason.decode!(json), ["nudges", "posts"]) end)

      assert [first, second] = values
      assert first != second
    end

    test "accepts an atom key" do
      conn = Signals.nudge(chunked_conn(), :posts)

      assert %{"nudges" => %{"posts" => _}} = Dstar.Test.patched_signals(conn)
    end

    test "passes options through to patch/3" do
      conn = Signals.nudge(chunked_conn(), "posts", event_id: "e1")

      assert conn.resp_body =~ "id: e1\n"
    end

    test "raises when the key is not a bare signal path segment" do
      for bad <- ["", "posts.recent", "posts-recent", "a b", "$posts"] do
        assert_raise ArgumentError, ~r/nudge key/, fn ->
          Signals.nudge(chunked_conn(), bad)
        end
      end
    end
  end
end
