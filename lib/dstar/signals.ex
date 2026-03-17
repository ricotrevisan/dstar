defmodule Dstar.Signals do
  @moduledoc """
  Functions for reading and patching Datastar signals via SSE.

      signals = Dstar.Signals.read(conn)
      conn |> patch(%{count: 42, message: "Hello"})
      conn |> patch(%{count: 42}, only_if_missing: true)
  """

  alias Dstar.SSE

  @datastar_key "datastar"
  @event_type "datastar-patch-signals"
  @default_only_if_missing false

  @doc """
  Reads signals from a Plug connection.

  For GET requests, reads from query parameters under the "datastar" key.
  For other methods, reads from the JSON request body.

  Returns a map of signals or an empty map if no signals are present.

  ## Example

      signals = Dstar.Signals.read(conn)
      # => %{"count" => 10, "message" => "Hello"}

  """
  @spec read(Plug.Conn.t()) :: map()
  def read(%Plug.Conn{method: "GET", query_params: params}) do
    case Map.get(params, @datastar_key) do
      nil -> %{}
      json_string -> decode_signals(json_string)
    end
  end

  def read(%Plug.Conn{} = conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decode_signals(body)

      body_params when is_map(body_params) ->
        body_params

      _ ->
        %{}
    end
  end

  @doc """
  Patches signals on the client by sending an SSE event.

  ## Options

  - `:only_if_missing` - Only patch signals that don't exist on the client (default: false)
  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  ## Example

      conn
      |> Dstar.Signals.patch(%{count: 42})
      |> Dstar.Signals.patch(%{message: "Hello"}, only_if_missing: true)

  """
  @spec patch(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def patch(conn, signals, opts \\ []) when is_map(signals) do
    json = Jason.encode!(signals)
    patch_raw(conn, json, opts)
  end

  @doc """
  Patches signals using a raw JSON string.

  ## Example

      conn
      |> Dstar.Signals.patch_raw(~s({"count": 42}))

  """
  @spec patch_raw(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def patch_raw(conn, json, opts \\ []) when is_binary(json) do
    only_if_missing = Keyword.get(opts, :only_if_missing, @default_only_if_missing)

    data_lines =
      []
      |> maybe_add_only_if_missing(only_if_missing)
      |> add_signals_data(json)

    event_opts =
      [
        event_id: opts[:event_id],
        retry: opts[:retry]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    SSE.send_event!(conn, @event_type, data_lines, event_opts)
  end

  @doc """
  Formats a signals patch as an SSE event string (for stateless responses).

  ## Example

      format_patch(%{count: 42})
      # => "event: datastar-patch-signals\\ndata: signals {\\"count\\":42}\\n\\n"

  """
  @spec format_patch(map(), keyword()) :: String.t()
  def format_patch(signals, opts \\ []) when is_map(signals) do
    only_if_missing = Keyword.get(opts, :only_if_missing, @default_only_if_missing)
    json = Jason.encode!(signals)

    data_lines =
      []
      |> maybe_add_only_if_missing(only_if_missing)
      |> add_signals_data(json)

    SSE.format_event(@event_type, data_lines)
  end

  @doc """
  Removes signals from the client by setting them to `nil`.

  Accepts a single dot-notated path string or a list of paths.
  Paths are converted to a nested map with `nil` values,
  then passed to `patch/3`.

  ## Examples

      # Remove a single signal
      conn |> remove_signals("user.profile.theme")

      # Remove multiple signals with shared prefix
      conn |> remove_signals(["user.name", "user.email"])

      # Remove top-level signal
      conn |> remove_signals("count")

  ## Options

  - `:only_if_missing` - Only remove if signal doesn't exist (default: false)
  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  """
  @spec remove_signals(Plug.Conn.t(), String.t() | [String.t()], keyword()) :: Plug.Conn.t()
  def remove_signals(conn, paths, opts \\ [])

  def remove_signals(conn, path, opts) when is_binary(path) do
    remove_signals(conn, [path], opts)
  end

  def remove_signals(conn, paths, opts) when is_list(paths) do
    nil_map = paths_to_nil_map(paths)
    patch(conn, nil_map, opts)
  end

  @doc """
  Formats a signal removal as an SSE event string (for stateless responses).

  ## Example

      format_remove("user.profile")
      # => "event: datastar-patch-signals\\ndata: signals {\\"user\\":{\\"profile\\":null}}\\n\\n"

      format_remove(["user.a", "user.b"])

  """
  @spec format_remove(String.t() | [String.t()], keyword()) :: String.t()
  def format_remove(paths, opts \\ [])

  def format_remove(path, opts) when is_binary(path) do
    format_remove([path], opts)
  end

  def format_remove(paths, opts) when is_list(paths) do
    nil_map = paths_to_nil_map(paths)
    format_patch(nil_map, opts)
  end

  # Private helpers

  defp decode_signals(""), do: %{}
  defp decode_signals(nil), do: %{}

  defp decode_signals(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  defp maybe_add_only_if_missing(lines, false), do: lines

  defp maybe_add_only_if_missing(lines, true) do
    lines ++ ["onlyIfMissing true"]
  end

  defp add_signals_data(lines, json) do
    lines ++ ["signals " <> json]
  end

  defp paths_to_nil_map(paths) do
    Enum.reduce(paths, %{}, fn path, acc ->
      validate_path!(path)
      deep_merge_nil(acc, path_to_nested_nil(path))
    end)
  end

  defp path_to_nested_nil(path) do
    path
    |> String.split(".")
    |> Enum.reverse()
    |> Enum.reduce(nil, fn segment, acc ->
      %{segment => acc}
    end)
  end

  defp deep_merge_nil(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge_nil(v1, v2)
      else
        v2
      end
    end)
  end

  defp deep_merge_nil(_map1, map2), do: map2

  defp validate_path!(path) when is_binary(path) do
    cond do
      path == "" ->
        raise ArgumentError, "Signal path cannot be empty"

      String.starts_with?(path, ".") ->
        raise ArgumentError, "Signal path cannot start with a dot: #{inspect(path)}"

      String.ends_with?(path, ".") ->
        raise ArgumentError, "Signal path cannot end with a dot: #{inspect(path)}"

      String.contains?(path, "..") ->
        raise ArgumentError, "Signal path cannot contain consecutive dots: #{inspect(path)}"

      true ->
        :ok
    end
  end
end
