defmodule Dstar.Component do
  @moduledoc """
  Shared UI + its event handlers in one module — for drawers, pickers,
  and other components used across many pages.

      defmodule MyAppWeb.DetailDrawer do
        use Dstar.Component

        def drawer(assigns) do
          ~H\"\"\"
          <div id="detail-drawer">
            <input data-on:change={event("change_title:\#{@item.id}")} />
          </div>
          \"\"\"
        end

        def handle_event(conn, "change_title:" <> id, signals) do
          # ... update, then patch
          conn |> start() |> patch_signals(%{saved: true})
        end
      end

  Pages embed the UI as plain function components and need no
  `handle_event` clauses for it — events route to this module via
  `Dstar.Plugs.Dispatch` (wire it with `Dstar.Router.dstar_components/2`).

  Unlike `Dstar.Page`, `event/2` here targets the component's dispatch
  URL. When your app mounts the dispatch route under a path prefix,
  declare it once in the root layout:

      <body data-ds-prefix={workspace_path(@current_scope.workspace.slug)}>

  Colocation only: no server-side component state, no lifecycle. State
  lives in signals, the DOM, and the database.
  """

  @verbs ~w(get post put patch delete)a

  defmacro __using__(_opts) do
    unless Code.ensure_loaded?(Phoenix.Component) do
      raise ArgumentError, """
      `use Dstar.Component` requires the optional dependencies. Add to your deps:

          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"}
      """
    end

    quote do
      use Phoenix.Component

      import Phoenix.Component,
        except: [assign: 2, assign: 3, assign_new: 3, update: 3]

      import Dstar.Page.Assigns

      import Dstar,
        only: [
          start: 1,
          read_signals: 1,
          patch_signals: 2,
          patch_signals: 3,
          remove_signals: 2,
          remove_signals: 3,
          patch_elements: 3,
          remove_elements: 2,
          remove_elements: 3,
          execute_script: 2,
          execute_script: 3,
          redirect: 2,
          redirect: 3,
          console_log: 2,
          console_log: 3
        ]

      import Dstar.Page.Helpers, only: [patch: 3, patch: 4]

      @doc """
      Builds a Datastar action expression targeting this component's
      dispatch URL, prefixed client-side by `document.body.dataset.dsPrefix`.
      """
      def event(name, opts \\ []) when is_binary(name) and is_list(opts) do
        Dstar.Component.build_event(__MODULE__, name, opts)
      end
    end
  end

  @doc false
  def build_event(module, name, opts)
      when is_atom(module) and is_binary(name) and is_list(opts) do
    if String.contains?(name, ["'", "/"]) do
      raise ArgumentError,
            "event name must not contain \"'\" or \"/\", got: #{inspect(name)}"
    end

    verb = Keyword.get(opts, :verb, :post)

    unless verb in @verbs do
      raise ArgumentError,
            "invalid verb: #{inspect(verb)}. Must be one of #{inspect(@verbs)}"
    end

    encoded = Dstar.Actions.encode_module(module)
    args = "(document.body.dataset.dsPrefix || '') + '/ds/#{encoded}/#{name}'"

    args =
      case Keyword.get(opts, :opts) do
        nil -> args
        extra when is_binary(extra) -> args <> ", " <> extra
      end

    "@#{verb}(#{args})"
  end
end
