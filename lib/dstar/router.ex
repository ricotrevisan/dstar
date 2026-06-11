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
  """
  defmacro dstar(path, page) do
    quote bind_quoted: [path: path, page: page] do
      get(path, Dstar.Page.Plug, {:page, page})
      post(path, Dstar.Page.Plug, {:stream, page})
      post(Dstar.Router.__event_path__(path), Dstar.Page.Plug, {:event, page})
    end
  end

  @doc """
  Wires `Dstar.Component` modules (or any `handle_event/3` handler
  modules) onto a single dispatch route under `base`.
  """
  defmacro dstar_components(base, modules) do
    quote bind_quoted: [base: base, modules: modules] do
      post(Dstar.Router.__dispatch_path__(base), Dstar.Plugs.Dispatch, modules: modules)
    end
  end

  @doc false
  def __event_path__(path), do: String.trim_trailing(path, "/") <> "/_event/:event"

  @doc false
  def __dispatch_path__(base), do: String.trim_trailing(base, "/") <> "/:module/:event"
end
