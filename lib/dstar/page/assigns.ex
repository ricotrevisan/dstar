if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Dstar.Page.Assigns do
    @moduledoc """
    Assign helpers that work in both halves of a Dstar page module.

    `use Dstar.Page` imports these instead of `Phoenix.Component`'s assign
    family, so one set of names works everywhere:

    - On a `%Plug.Conn{}` (in `mount/2`, `handle_event/3`, `handle_connect/2`,
      `handle_info/2`) they behave like `Plug.Conn.assign/3`.
    - On anything else (sockets, assigns maps inside function components)
      they delegate to `Phoenix.Component`.
    """

    @doc """
    Assigns one key/value or many key/values.

        conn |> assign(:count, 1)
        conn |> assign(count: 1, name: "rico")
    """
    def assign(%Plug.Conn{} = conn, key_values) when is_list(key_values) or is_map(key_values) do
      Enum.reduce(key_values, conn, fn {key, value}, acc -> Plug.Conn.assign(acc, key, value) end)
    end

    def assign(socket_or_assigns, key_values) do
      Phoenix.Component.assign(socket_or_assigns, key_values)
    end

    def assign(%Plug.Conn{} = conn, key, value) when is_atom(key) do
      Plug.Conn.assign(conn, key, value)
    end

    def assign(socket_or_assigns, key, value) do
      Phoenix.Component.assign(socket_or_assigns, key, value)
    end

    @doc """
    Assigns a value computed by `fun` only when `key` is absent.
    `fun` may take zero arguments or the current assigns.
    """
    def assign_new(%Plug.Conn{} = conn, key, fun) when is_atom(key) and is_function(fun) do
      if Map.has_key?(conn.assigns, key) do
        conn
      else
        value =
          case fun do
            fun when is_function(fun, 0) -> fun.()
            fun when is_function(fun, 1) -> fun.(conn.assigns)
          end

        Plug.Conn.assign(conn, key, value)
      end
    end

    def assign_new(socket_or_assigns, key, fun) do
      Phoenix.Component.assign_new(socket_or_assigns, key, fun)
    end

    @doc """
    Updates an existing assign with `fun`. Raises `KeyError` if absent.
    """
    def update(%Plug.Conn{} = conn, key, fun) when is_atom(key) and is_function(fun, 1) do
      Plug.Conn.assign(conn, key, fun.(Map.fetch!(conn.assigns, key)))
    end

    def update(socket_or_assigns, key, fun) do
      Phoenix.Component.update(socket_or_assigns, key, fun)
    end
  end
end
