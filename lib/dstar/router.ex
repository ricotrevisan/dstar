defmodule Dstar.Router do
  @moduledoc """
  Router macros for Dstar pages and components.

      # In your Phoenix router:
      import Dstar.Router

      scope "/", MyAppWeb do
        pipe_through :browser

        dstar "/counter", CounterPage
        dstar_components "/ds", [DetailDrawer, DatePicker]
      end

  `dstar/2` expands to plain Phoenix routes — the route is the allowlist:

      GET   /counter                 -> Dstar.Page.Plug page    (mount + render)
      POST  /counter                 -> Dstar.Page.Plug stream  (handle_connect + loop)
      POST  /counter/_event/:event   -> Dstar.Page.Plug event   (handle_event)

  `_event` is a reserved path segment under page paths.

  `dstar_components/2` expands to one POST route on `Dstar.Plugs.Dispatch`
  with the given module allowlist.
  """

  @doc """
  Wires a `Dstar.Page` module: GET render, POST stream, POST events.

  Inside an aliased `scope`, the page module is scope-expanded like a
  controller or live view — `dstar "/counter", CounterPage` inside
  `scope "/", MyAppWeb` resolves to `MyAppWeb.CounterPage`.
  """
  defmacro dstar(path, page) do
    quote bind_quoted: [path: path, page: page] do
      # Scope-expand the page (like `live/4` does for live views), and
      # exempt the dispatcher plug from scope aliasing (alias: false) so
      # routes inside `scope "/", MyAppWeb` don't target MyAppWeb.Dstar.Page.Plug.
      page = Phoenix.Router.scoped_alias(__MODULE__, page)
      get(path, Dstar.Page.Plug, {:page, page}, alias: false)
      post(path, Dstar.Page.Plug, {:stream, page}, alias: false)
      post(Dstar.Router.__event_path__(path), Dstar.Page.Plug, {:event, page}, alias: false)
    end
  end

  @doc """
  Wires `Dstar.Component` modules (or any `handle_event/3` handler
  modules) onto a single dispatch route under `base`.

  Component modules are scope-expanded like controllers.
  """
  defmacro dstar_components(base, modules) do
    quote bind_quoted: [base: base, modules: modules] do
      modules = Enum.map(modules, &Phoenix.Router.scoped_alias(__MODULE__, &1))

      post(Dstar.Router.__dispatch_path__(base), Dstar.Plugs.Dispatch, [modules: modules],
        alias: false
      )
    end
  end

  @doc false
  def __event_path__(path), do: String.trim_trailing(path, "/") <> "/_event/:event"

  @doc false
  def __dispatch_path__(base), do: String.trim_trailing(base, "/") <> "/:module/:event"
end
