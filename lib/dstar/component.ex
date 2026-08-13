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
  URL: `<base>/<encoded-module>/<event>`. The base defaults to `/ds` and
  is read client-side from `<body data-ds-base="...">`, so it must match
  the base you give `dstar_components/2`. The value must be a trusted local
  absolute application path beginning with one `/`; protocol-relative values,
  dot segments, backslashes, queries, fragments, and controls are rejected in
  the browser; percent escapes must decode successfully.
  Two common setups:

      # Router: dstar_components "/ds", [...]   (the default — no layout
      # attribute needed)

      # Custom base and/or app path prefix — declare it once in the root
      # layout, including the dispatch segment:
      #   Router: scope "/:workspace_slug" do dstar_components "/ds", [...] end
      <body data-ds-base={workspace_path(@current_scope.workspace.slug) <> "/ds"}>

  Colocation only: no server-side component state, no lifecycle. State
  lives in signals, the DOM, and the database.
  """

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
      Builds a Datastar action expression targeting this component's dispatch URL.

      Event and module values are percent-encoded as one route segment. The
      optional `:opts` value is raw, trusted JavaScript for developer-authored
      action options; never interpolate request or stored data into it.
      """
      def event(name, opts \\ []) when is_binary(name) and is_list(opts) do
        Dstar.Component.build_event(__MODULE__, name, opts)
      end
    end
  end

  @doc false
  def build_event(module, name, opts)
      when is_atom(module) and is_binary(name) and is_list(opts) do
    encoded = Dstar.Actions.encode_module(module)

    # The dispatch base comes from <body data-ds-base="...">, defaulting to
    # "/ds". It must match the base given to `dstar_components/2` — keeping
    # it client-side means one layout attribute covers app path prefixes too.
    Dstar.Actions.build_action(
      :component_base,
      [encoded, name],
      opts
    )
  end
end
