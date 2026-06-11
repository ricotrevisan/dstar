defmodule Dstar.Test do
  @moduledoc """
  Assertions for Dstar SSE responses in `Plug.Test` / `Phoenix.ConnTest`
  tests. Chunked SSE bodies accumulate in `conn.resp_body` on the test
  adapter; these helpers parse them back into events.

      conn = post(conn, "/counter/_event/increment")
      assert_patched_signals(conn, %{count: 1})
      assert_patched_element(conn, "#history")
  """

  import ExUnit.Assertions

  @doc """
  Parses the SSE events from a conn (or raw body string) into a list of
  `%{type: String.t() | nil, data: [String.t()]}`.
  """
  def sse_events(%Plug.Conn{} = conn), do: sse_events(conn.resp_body || "")

  def sse_events(body) when is_binary(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_event/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_event(block) do
    lines = String.split(block, "\n", trim: true)

    type =
      Enum.find_value(lines, fn
        "event: " <> type -> type
        _ -> nil
      end)

    data = for "data: " <> data <- lines, do: data

    if type != nil or data != [], do: %{type: type, data: data}
  end

  @doc """
  Returns the merged map of all signals patched on the conn.
  """
  def patched_signals(conn) do
    conn
    |> sse_events()
    |> Enum.filter(&(&1.type == "datastar-patch-signals"))
    |> Enum.flat_map(& &1.data)
    |> Enum.reduce(%{}, fn
      "signals " <> json, acc -> Map.merge(acc, Jason.decode!(json))
      _line, acc -> acc
    end)
  end

  @doc """
  Asserts the given signals (a subset) were patched. Keys may be atoms
  or strings; values compare against the JSON-decoded patch.
  Returns the conn for piping.
  """
  def assert_patched_signals(conn, expected) when is_map(expected) do
    actual = patched_signals(conn)

    for {key, value} <- expected do
      key = to_string(key)

      assert Map.get(actual, key) == value,
             "expected signal #{inspect(key)} to be patched to #{inspect(value)}, " <>
               "got #{inspect(Map.get(actual, key))}. All patched signals: #{inspect(actual)}"
    end

    conn
  end

  @doc """
  Asserts a `datastar-patch-elements` event targets `target` — either via
  an explicit `selector` line or via an `id` attribute in the patched HTML
  (pass the target as `"#the-id"` in both cases).
  Returns the conn for piping.
  """
  def assert_patched_element(conn, "#" <> _ = target) do
    events =
      conn
      |> sse_events()
      |> Enum.filter(&(&1.type == "datastar-patch-elements"))

    id = String.trim_leading(target, "#")

    found =
      Enum.any?(events, fn %{data: data} ->
        Enum.any?(data, fn
          "selector " <> selector -> selector == target
          "elements " <> html -> String.contains?(html, ~s(id="#{id}"))
          _other -> false
        end)
      end)

    assert found,
           "no datastar-patch-elements event targeting #{inspect(target)}. " <>
             "Element events: #{inspect(events)}"

    conn
  end
end
