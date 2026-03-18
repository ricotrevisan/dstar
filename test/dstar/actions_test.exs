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

  @csrf_opts "{headers: {'x-csrf-token': $_csrfToken}}"

  # ── Verb helpers ──────────────────────────────────────────────────────

  for verb <- ~w(post get put patch delete)a do
    verb_str = Atom.to_string(verb)

    describe "#{verb}/2 with module" do
      test "generates a #{verb_str} action with encoded module and CSRF header" do
        result = apply(Actions, unquote(verb), [MyApp.CounterView, "increment"])
        encoded = Actions.encode_module(MyApp.CounterView)
        assert result == "@#{unquote(verb_str)}('/ds/#{encoded}/increment', #{@csrf_opts})"
      end
    end

    describe "#{verb}/3 with prefix" do
      test "generates a #{verb_str} action with prefix and CSRF header" do
        result = apply(Actions, unquote(verb), [MyApp.CounterView, "increment", [prefix: "/ws"]])
        encoded = Actions.encode_module(MyApp.CounterView)
        assert result == "@#{unquote(verb_str)}('/ws/ds/#{encoded}/increment', #{@csrf_opts})"
      end
    end

    describe "#{verb}/1 dynamic" do
      test "generates a #{verb_str} action with dynamic module signal and CSRF header" do
        result = apply(Actions, unquote(verb), ["increment"])

        assert result ==
                 "@#{unquote(verb_str)}('/ds/' + $_dstar_module + '/increment', #{@csrf_opts})"
      end

      test "generates #{verb_str} with custom module signal and CSRF header" do
        result = apply(Actions, unquote(verb), ["save", [module: "my_module"]])
        assert result == "@#{unquote(verb_str)}('/ds/my_module/save', #{@csrf_opts})"
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
end
