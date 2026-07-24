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
        assert result == "@#{unquote(verb_str)}('/ds/#{encoded}/increment')"
      end
    end

    describe "#{verb}/3 with prefix" do
      test "generates a #{verb_str} action with prefix" do
        result = apply(Actions, unquote(verb), [MyApp.CounterView, "increment", [prefix: "/ws"]])
        encoded = Actions.encode_module(MyApp.CounterView)
        assert result == "@#{unquote(verb_str)}('/ws/ds/#{encoded}/increment')"
      end
    end

    describe "#{verb}/1 dynamic" do
      test "generates a #{verb_str} action with dynamic module signal" do
        result = apply(Actions, unquote(verb), ["increment"])

        assert result ==
                 "@#{unquote(verb_str)}('/ds/' + $_dstar_module + '/increment')"
      end

      test "generates #{verb_str} with custom module signal" do
        result = apply(Actions, unquote(verb), ["save", [module: "my_module"]])
        assert result == "@#{unquote(verb_str)}('/ds/my_module/save')"
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
