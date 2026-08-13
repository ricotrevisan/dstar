defmodule Dstar.ActionsTest do
  use ExUnit.Case, async: true

  alias Dstar.Actions

  # Define test modules so String.to_existing_atom works in decode_module
  defmodule MyApp.CounterView do
  end

  defmodule MyApp.Web.ChatView do
  end

  describe "encode_module/1" do
    test "encodes a simple module" do
      assert Actions.encode_module(MyApp.CounterView) ==
               "dstar-actions_test-my_app-counter_view"
    end
  end

  describe "decode_module/1" do
    test "decodes an encoded module" do
      encoded = Actions.encode_module(MyApp.CounterView)
      assert Actions.decode_module(encoded) == {:ok, MyApp.CounterView}
    end

    test "roundtrips nested modules" do
      encoded = Actions.encode_module(MyApp.Web.ChatView)
      assert Actions.decode_module(encoded) == {:ok, MyApp.Web.ChatView}
    end

    test "returns error for nonexistent module" do
      assert Actions.decode_module("does_not-exist") == :error
    end
  end

  # ── Verb helpers ──────────────────────────────────────────────────────

  for verb <- ~w(post get put patch delete)a do
    verb_str = Atom.to_string(verb)

    describe "#{verb}/2 with module" do
      test "generates a #{verb_str} action with encoded module" do
        result = apply(Actions, unquote(verb), [MyApp.CounterView, "increment"])
        encoded = Actions.encode_module(MyApp.CounterView)
        assert result == ~s|@#{unquote(verb_str)}("/ds/#{encoded}/increment")|
      end
    end

    describe "#{verb}/3 with prefix" do
      test "generates a #{verb_str} action with prefix" do
        result = apply(Actions, unquote(verb), [MyApp.CounterView, "increment", [prefix: "/ws"]])
        encoded = Actions.encode_module(MyApp.CounterView)
        assert result == ~s|@#{unquote(verb_str)}("/ws/ds/#{encoded}/increment")|
      end
    end

    describe "#{verb}/1 dynamic" do
      test "generates a #{verb_str} action with dynamic module signal" do
        result = apply(Actions, unquote(verb), ["increment"])

        assert String.starts_with?(
                 result,
                 ~s|@#{unquote(verb_str)}("/ds" + "/" + ((segment) =>|
               )

        assert result =~ "invalid Dstar module segment"
        assert result =~ "encodeURIComponent(segment)"
        assert String.ends_with?(result, ~S|($_dstar_module) + "/increment")|)
      end

      test "generates #{verb_str} with a literal custom module" do
        result = apply(Actions, unquote(verb), ["save", [module: "my_module"]])
        assert result == ~s|@#{unquote(verb_str)}("/ds/my_module/save")|
      end

      test "preserves the explicit default dynamic module expression" do
        assert apply(Actions, unquote(verb), ["save", [module: "$_dstar_module"]]) ==
                 apply(Actions, unquote(verb), ["save"])
      end
    end
  end

  describe "action URL safety" do
    test "serializes caller-provided text instead of interpolating it into the expression" do
      payload = "x');alert(document.domain);//"
      prefix = "');alert(1);//"
      module = "x');alert(1);//"

      assert Actions.post(String, payload) ==
               ~S|@post("/ds/string/x%27%29%3Balert%28document%2Edomain%29%3B%2F%2F")|

      assert_raise ArgumentError, ~r/prefix/, fn ->
        Actions.post(String, "save", prefix: prefix)
      end

      assert Actions.post("save", module: module) ==
               ~S|@post("/ds/x%27%29%3Balert%281%29%3B%2F%2F/save")|
    end

    test "encodes every event and literal module value as one route segment" do
      values = [
        {"/", "%2F"},
        {"\\", "%5C"},
        {"a..b", "a%2E%2Eb"},
        {"?", "%3F"},
        {"#", "%23"},
        {"%2f", "%252f"},
        {"\r\n", "%0D%0A"},
        {"'\"", "%27%22"},
        {"café/東京", "caf%C3%A9%2F%E6%9D%B1%E4%BA%AC"}
      ]

      for {value, encoded} <- values do
        assert Actions.post(String, value) == ~s|@post("/ds/string/#{encoded}")|
        assert Actions.post("save", module: value) == ~s|@post("/ds/#{encoded}/save")|
      end
    end

    test "accepts only local absolute path prefixes" do
      for prefix <- [
            "//evil.test",
            "https://evil.test",
            "relative",
            "",
            "/x?y",
            "/x#y",
            "/\\evil",
            "/x\ny",
            "/%2F%2Fevil.test",
            "/x%3Fy",
            "/x%23y",
            "/x%0Ay",
            "/%5Cevil.test",
            "/bad%",
            "/%ZZ",
            "/%FF",
            "/a/../admin",
            "/a/%2E%2E/admin",
            "/./admin"
          ] do
        assert_raise ArgumentError, ~r/:prefix must be a local absolute path/, fn ->
          Actions.post(String, "save", prefix: prefix)
        end
      end

      assert Actions.post(String, "save", prefix: "/workspace/") ==
               ~S|@post("/workspace/ds/string/save")|

      assert Actions.post(String, "save", prefix: "/") == Actions.post(String, "save")

      assert Actions.post(String, "save", prefix: "/caf%C3%A9") ==
               ~S|@post("/caf%C3%A9/ds/string/save")|
    end

    test "encodes unusual module atoms through the same segment rules" do
      assert Actions.post(:"Elixir.X/Y", "go") == ~S|@post("/ds/x%2F_y/go")|
    end

    test "rejects values that browser URL parsing would treat as missing or dot segments" do
      for value <- ["", ".", ".."] do
        assert_raise ArgumentError, ~r/path segment/, fn -> Actions.post(String, value) end

        assert_raise ArgumentError, ~r/path segment/, fn ->
          Actions.post("save", module: value)
        end
      end
    end
  end

  # ── Deprecated event/2,3 still works ─────────────────────────────────

  describe "event/2 (deprecated)" do
    test "delegates to post/2" do
      assert Actions.event(MyApp.CounterView, "increment") ==
               Actions.post(MyApp.CounterView, "increment")
    end

    test "dynamic delegates to post/1" do
      assert Actions.event("increment") == Actions.post("increment")
    end
  end

  describe "event/3 (deprecated)" do
    test "delegates to post/3" do
      assert Actions.event(MyApp.CounterView, "save", prefix: "/ws") ==
               Actions.post(MyApp.CounterView, "save", prefix: "/ws")
    end
  end

  describe "on_nudge/2" do
    test "returns the Datastar attribute pair for a filtered signal-patch listener" do
      # Attribute names verified against the Datastar v1 bundle: the plugin is
      # registered as "on-signal-patch" and the filter is a sibling attribute.
      assert Actions.on_nudge("posts", "@post('/reload')") == %{
               "data-on-signal-patch" => "@post('/reload')",
               "data-on-signal-patch-filter" => ~S({"include":"^nudges\\.posts$"})
             }
    end

    test "emits a JSON filter so it needs no eval under a strict CSP" do
      %{"data-on-signal-patch-filter" => filter} = Actions.on_nudge("posts", "@post('/x')")

      assert Jason.decode!(filter) == %{"include" => "^nudges\\.posts$"}
    end

    test "accepts an atom key" do
      assert Actions.on_nudge(:posts, "@post('/x')") == Actions.on_nudge("posts", "@post('/x')")
    end

    test "raises when the key is not a bare signal path segment" do
      for bad <- ["", "posts.recent", "posts-recent", "a b", "$posts"] do
        assert_raise ArgumentError, ~r/nudge key/, fn ->
          Actions.on_nudge(bad, "@post('/x')")
        end
      end
    end
  end
end
