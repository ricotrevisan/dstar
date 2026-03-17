defmodule Dstar.SSE do
  @moduledoc """
  Server-Sent Event (SSE) connection helpers.

  Sets up a Plug conn for chunked SSE streaming and provides
  functions to send events over it.

  ## Example

      conn
      |> Dstar.SSE.start()
      |> Dstar.SSE.send_event!("my-event", ["data line 1", "data line 2"])

  """

  @doc """
  Starts an SSE connection from a Plug conn.

  Sets the content type to `text/event-stream`, disables caching,
  and sends a chunked 200 response.

  ## Example

      conn = Dstar.SSE.start(conn)

  """
  @spec start(Plug.Conn.t()) :: Plug.Conn.t()
  def start(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_chunked(200)
  end

  @doc """
  Checks if an SSE connection is still open by sending a comment line.

  SSE comments (lines starting with `:`) are ignored by clients but
  will fail if the connection has been closed. Useful for detecting
  disconnections in streaming loops.

  Returns `{:ok, conn}` if the connection is open, `{:error, conn}` if closed
  or not yet started.

  ## Example

      case Dstar.SSE.check_connection(conn) do
        {:ok, conn} ->
          # Continue streaming
          stream_loop(conn)

        {:error, _conn} ->
          # Connection closed, clean up
          :ok
      end

  """
  @spec check_connection(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def check_connection(conn) do
    try do
      case Plug.Conn.chunk(conn, ": \n\n") do
        {:ok, conn} -> {:ok, conn}
        {:error, _reason} -> {:error, conn}
      end
    rescue
      ArgumentError -> {:error, conn}
    end
  end

  @doc """
  Sends an SSE event to the client.

  Returns `{:ok, conn}` on success, `{:error, reason}` on failure.

  ## Options

  - `:event_id` — Event ID for client tracking
  - `:retry` — Retry duration in milliseconds

  ## Example

      {:ok, conn} = Dstar.SSE.send_event(conn, "my-event", ["line1", "line2"])

  """
  @spec send_event(Plug.Conn.t(), String.t(), list(String.t()) | String.t(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def send_event(conn, event_type, data_lines, opts \\ []) do
    data_lines = if is_binary(data_lines), do: [data_lines], else: data_lines

    event_content =
      []
      |> maybe_add_event(event_type)
      |> maybe_add_id(opts[:event_id])
      |> maybe_add_retry(opts[:retry])
      |> add_data_lines(data_lines)
      |> Enum.join()
      |> Kernel.<>("\n")

    case Plug.Conn.chunk(conn, event_content) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends an SSE event, raising on error. Returns the updated conn.

  Useful for pipelines:

      conn
      |> send_event!("event-a", "data a")
      |> send_event!("event-b", "data b")

  """
  @spec send_event!(Plug.Conn.t(), String.t(), list(String.t()) | String.t(), keyword()) ::
          Plug.Conn.t()
  def send_event!(conn, event_type, data_lines, opts \\ []) do
    case send_event(conn, event_type, data_lines, opts) do
      {:ok, conn} -> conn
      {:error, reason} -> raise "Failed to send SSE event: #{inspect(reason)}"
    end
  end

  @doc """
  Formats a single SSE event as a string (no connection needed).

  Useful for building SSE response bodies without chunked streaming.

  ## Example

      Dstar.SSE.format_event("datastar-patch-signals", ["signals {\\"count\\":42}"])
      # => "event: datastar-patch-signals\\ndata: signals {\\"count\\":42}\\n\\n"

  """
  @spec format_event(String.t(), [String.t()]) :: String.t()
  def format_event(event_type, data_lines) do
    event_line = "event: #{event_type}\n"
    data_content = Enum.map_join(data_lines, "\n", &"data: #{&1}")
    "#{event_line}#{data_content}\n\n"
  end

  # Private helpers

  defp maybe_add_event(lines, nil), do: lines
  defp maybe_add_event(lines, event_type), do: lines ++ ["event: #{event_type}\n"]

  defp maybe_add_id(lines, nil), do: lines
  defp maybe_add_id(lines, id), do: lines ++ ["id: #{id}\n"]

  defp maybe_add_retry(lines, nil), do: lines
  defp maybe_add_retry(lines, retry), do: lines ++ ["retry: #{retry}\n"]

  defp add_data_lines(lines, data_lines) do
    lines ++ Enum.map(data_lines, &"data: #{&1}\n")
  end
end
