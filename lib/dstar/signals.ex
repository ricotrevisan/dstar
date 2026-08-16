defmodule Dstar.Signals do
  @moduledoc """
  Functions for reading and patching Datastar signals via SSE.

      {:ok, signals, conn} = Dstar.Signals.fetch(conn)
      conn |> patch(%{count: 42, message: "Hello"})
      conn |> patch(%{count: 42}, only_if_missing: true)
      conn |> remove_signals("user.session")
  """

  alias Dstar.SSE

  @datastar_key "datastar"
  @event_type "datastar-patch-signals"
  @default_max_bytes 1_000_000
  @default_only_if_missing false
  @nudge_key_format ~r/^[a-zA-Z0-9_]+$/

  @typedoc "Why a signal payload could not be fetched"
  @type fetch_error :: :malformed | :not_an_object | :too_large | {:read_body, term()}

  @doc false
  def default_max_bytes, do: @default_max_bytes

  @doc """
  Safely fetches signals and returns the connection that owns the body state.

  Only JSON objects are accepted. GET and DELETE read the `datastar` query
  parameter; other methods use already-fetched body params or read the raw
  JSON body. Missing signals or an empty raw body produce an empty object;
  an explicitly empty `datastar=` query value is malformed.

  Raw reads bound both `Plug.Conn.read_body/2`'s `:length` and
  `:read_length`. The default maximum is #{@default_max_bytes} bytes and can
  be changed per call with `:max_bytes`. When a parser already populated
  `body_params`, that parser owns raw-body limits; configure it to the same
  or a smaller limit.

  The returned conn must be threaded forward:

      case Dstar.Signals.fetch(conn, max_bytes: 64_000) do
        {:ok, signals, conn} -> handle(conn, signals)
        {:error, reason, conn} -> Dstar.Signals.send_error(conn, reason)
      end

  ## Options

  - `:max_bytes` — maximum raw JSON payload size (default #{@default_max_bytes})
  """
  @spec fetch(Plug.Conn.t(), keyword()) ::
          {:ok, map(), Plug.Conn.t()} | {:error, fetch_error(), Plug.Conn.t()}
  def fetch(conn, opts \\ []) do
    max_bytes = max_bytes!(opts)

    case conn do
      %Plug.Conn{method: method} when method in ["GET", "DELETE"] ->
        fetch_query_signals(conn, max_bytes)

      %Plug.Conn{body_params: %Plug.Conn.Unfetched{}} ->
        fetch_raw_body(conn, max_bytes)

      %Plug.Conn{body_params: %{"_json" => _value} = body_params}
      when map_size(body_params) == 1 ->
        # Plug.Parsers wraps a non-object JSON document under this reserved
        # key so it can merge params. Datastar never sends underscore-prefixed
        # signals, so this exact shape cannot be a legitimate signal object.
        {:error, :not_an_object, conn}

      %Plug.Conn{body_params: body_params} when is_map(body_params) ->
        {:ok, body_params, conn}

      %Plug.Conn{} ->
        {:error, :not_an_object, conn}
    end
  end

  @doc """
  Reads signals only when the relevant params have already been fetched.

  This convenience API cannot safely own a raw request body because it cannot
  return Plug's updated conn. Use `fetch/2` when `body_params` (or GET/DELETE
  `query_params`) are unfetched. Invalid JSON and non-object JSON raise; code
  that needs a controlled 400/413 response should use `fetch/2`.
  """
  @spec read(Plug.Conn.t()) :: map()
  def read(%Plug.Conn{method: method, query_params: %Plug.Conn.Unfetched{}})
      when method in ["GET", "DELETE"] do
    raise ArgumentError,
          "query params are unfetched; use Dstar.Signals.fetch/2 and thread its returned conn"
  end

  def read(%Plug.Conn{method: method, query_params: params} = conn)
      when method in ["GET", "DELETE"] do
    case decode_query_signals(params, @default_max_bytes) do
      {:ok, signals} -> signals
      {:error, reason} -> raise ArgumentError, invalid_message(reason, conn)
    end
  end

  def read(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}) do
    raise ArgumentError,
          "body params are unfetched; use Dstar.Signals.fetch/2 and thread its returned conn"
  end

  def read(%Plug.Conn{body_params: %{"_json" => _value} = body_params} = conn)
      when map_size(body_params) == 1 do
    raise ArgumentError, invalid_message(:not_an_object, conn)
  end

  def read(%Plug.Conn{body_params: body_params}) when is_map(body_params), do: body_params

  def read(%Plug.Conn{} = conn) do
    raise ArgumentError, invalid_message(:not_an_object, conn)
  end

  @doc """
  Sends a controlled plain-text response for a `fetch/2` error.

  Oversized payloads receive 413; every other input failure receives 400.
  This is safe to call before starting SSE.
  """
  @spec send_error(Plug.Conn.t(), fetch_error()) :: Plug.Conn.t()
  def send_error(conn, :too_large), do: send_input_error(conn, 413, "Signal payload too large")
  def send_error(conn, _reason), do: send_input_error(conn, 400, "Invalid signal payload")

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

  The JSON must be a single line. Embedded line breaks are split across
  multiple SSE `data:` lines for wire safety, which the client will not
  reassemble into one `signals` payload — pass compact JSON (as
  `Jason.encode!/1` produces) or use `patch/3`.

  ## Example

      conn
      |> Dstar.Signals.patch_raw(~s({"count": 42}))

  """
  @spec patch_raw(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def patch_raw(conn, json, opts \\ []) when is_binary(json) do
    SSE.send_event!(conn, @event_type, data_lines(json, opts), event_opts(opts))
  end

  @doc """
  Formats a signals patch as an SSE event string (for stateless responses).

  ## Example

      format_patch(%{count: 42})
      # => "event: datastar-patch-signals\\ndata: signals {\\"count\\":42}\\n\\n"

  """
  @spec format_patch(map(), keyword()) :: String.t()
  def format_patch(signals, opts \\ []) when is_map(signals) do
    SSE.format_event(@event_type, data_lines(Jason.encode!(signals), opts))
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

  ## Path validation

  Raises `ArgumentError` on a path that is empty, starts or ends with a dot,
  or contains consecutive dots — each would otherwise produce a signal name
  with an empty segment.

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
  Signals that a collection changed, without saying how.

  Patches `nudges.<key>` with a fresh integer. Tabs watching that signal
  (see `Dstar.Actions.on_nudge/2`) re-run their own load action, which
  carries *their* current filter/sort/page signals — so every tab gets a
  view correct for that tab. This is the default for any list that is
  filtered, sorted or paginated; the stream is one-way and cannot learn a
  tab's view state after connect. See the
  [Live collections](live-collections.html) guide.

  The value is `System.unique_integer([:positive, :monotonic])`. The client
  only fires its handler when a signal's value actually *changes*, so
  re-sending a constant would be a silent no-op.

  `key` is a single signal path segment: `~r/^[a-zA-Z0-9_]+$/`.

  ## Example

      def handle_info({:posts_changed, _}, conn), do: nudge(conn, "posts")

  """
  @spec nudge(Plug.Conn.t(), String.t() | atom(), keyword()) :: Plug.Conn.t()
  def nudge(conn, key, opts \\ []) do
    key = nudge_key!(key)
    patch(conn, %{nudges: %{key => System.unique_integer([:positive, :monotonic])}}, opts)
  end

  @doc false
  # Shared by Dstar.Actions.on_nudge/2 so both halves reject the same keys.
  def nudge_key!(key) when is_atom(key), do: nudge_key!(Atom.to_string(key))

  def nudge_key!(key) when is_binary(key) do
    unless Regex.match?(@nudge_key_format, key) do
      raise ArgumentError,
            "nudge key must be a single signal path segment matching " <>
              "#{inspect(@nudge_key_format)}, got: #{inspect(key)}"
    end

    key
  end

  @doc """
  Formats a signal removal as an SSE event string (for stateless responses).

  ## Examples

      format_remove("user.profile")
      # => "event: datastar-patch-signals\\ndata: signals {\\"user\\":{\\"profile\\":null}}\\n\\n"

      format_remove(["user.a", "user.b"])
      # => "event: datastar-patch-signals\\ndata: signals {\\"user\\":{\\"a\\":null,\\"b\\":null}}\\n\\n"

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

  # The `data:` payload, shared by patch_raw/3 and format_patch/2 — the two
  # differ only in how the event gets framed (chunked onto a conn vs.
  # returned as a string), never in what it contains.
  defp data_lines(json, opts) do
    []
    |> maybe_add_only_if_missing(Keyword.get(opts, :only_if_missing, @default_only_if_missing))
    |> add_signals_data(json)
  end

  defp event_opts(opts) do
    [event_id: opts[:event_id], retry: opts[:retry]]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp send_input_error(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp fetch_query_signals(conn, max_bytes) do
    conn = Plug.Conn.fetch_query_params(conn)

    case decode_query_signals(conn.query_params, max_bytes) do
      {:ok, signals} -> {:ok, signals, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp decode_query_signals(params, max_bytes) do
    case Map.fetch(params, @datastar_key) do
      :error -> {:ok, %{}}
      {:ok, ""} -> {:error, :malformed}
      {:ok, json} -> decode_payload(json, max_bytes)
    end
  end

  defp fetch_raw_body(conn, max_bytes) do
    read_raw_body(conn, max_bytes, max_bytes, [])
  end

  defp read_raw_body(conn, max_bytes, remaining, chunks) do
    read_opts = [length: remaining, read_length: remaining]

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, chunk, conn} ->
        if byte_size(chunk) > remaining do
          {:error, :too_large, conn}
        else
          decode_raw_body([chunks, chunk], conn, max_bytes)
        end

      {:more, "", conn} ->
        {:error, {:read_body, :no_progress}, conn}

      {:more, chunk, conn} ->
        chunk_size = byte_size(chunk)

        if chunk_size >= remaining do
          {:error, :too_large, conn}
        else
          read_raw_body(conn, max_bytes, remaining - chunk_size, [chunks, chunk])
        end

      {:error, reason} ->
        {:error, {:read_body, reason}, conn}
    end
  end

  defp decode_raw_body(chunks, conn, max_bytes) do
    result =
      case IO.iodata_to_binary(chunks) do
        "" -> {:ok, %{}}
        body -> decode_payload(body, max_bytes)
      end

    case result do
      {:ok, signals} -> {:ok, signals, %{conn | body_params: signals}}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp decode_payload(nil, _max_bytes), do: {:error, :not_an_object}
  defp decode_payload("", _max_bytes), do: {:error, :malformed}

  defp decode_payload(json, max_bytes) when is_binary(json) do
    if byte_size(json) > max_bytes do
      {:error, :too_large}
    else
      case Jason.decode(json) do
        {:ok, signals} when is_map(signals) -> {:ok, signals}
        {:ok, _json} -> {:error, :not_an_object}
        {:error, _reason} -> {:error, :malformed}
      end
    end
  end

  defp decode_payload(_payload, _max_bytes), do: {:error, :not_an_object}

  defp max_bytes!(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        max_bytes

      value ->
        raise ArgumentError, ":max_bytes must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp invalid_message(reason, conn) do
    "invalid signal payload (#{inspect(reason)}) for #{conn.method}; " <>
      "use Dstar.Signals.fetch/2 for a controlled error response"
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
