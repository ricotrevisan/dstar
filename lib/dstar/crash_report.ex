defmodule Dstar.CrashReport do
  @moduledoc false

  # Crash reporting shared by `Dstar.Plugs.Dispatch` and `Dstar.Page.Plug`.
  #
  # A stack frame can carry the call's arguments instead of its arity (the
  # top frame of a `FunctionClauseError` always does), and built-in exceptions
  # like `MatchError`, `KeyError`, and `CaseClauseError` embed the failing
  # term directly in their struct. For a handler those values are often the
  # conn or signals, so formatting the raw exception or stacktrace would copy
  # cookies, authorization headers, the CSRF token, and form fields (passwords
  # included) into logs, error trackers, and the `debug_errors` console relay.

  @default_filtered_keys [
    "password",
    "secret",
    "token",
    "csrf",
    "authorization",
    "cookie",
    "api_key",
    "apikey",
    "credential"
  ]

  @max_scrub_depth 12

  @doc false
  @spec scrub(Exception.stacktrace()) :: Exception.stacktrace()
  def scrub(stacktrace) when is_list(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
  end

  @doc false
  @spec format(Exception.t(), Exception.stacktrace()) :: String.t()
  def format(exception, stacktrace) do
    Exception.format(:error, scrub_exception(exception), scrub(stacktrace))
  end

  @doc false
  @spec scrub_exception(Exception.t()) :: Exception.t()
  def scrub_exception(exception) do
    filters = filter_spec()

    case exception do
      %MatchError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %CaseClauseError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %WithClauseError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %KeyError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %BadMapError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %BadStructError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %BadBooleanError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %TryClauseError{term: term} ->
        %{exception | term: scrub_term(term, filters, 0)}

      %Protocol.UndefinedError{value: value} ->
        %{exception | value: scrub_term(value, filters, 0)}

      %FunctionClauseError{args: args} when is_list(args) ->
        %{exception | args: nil}

      other ->
        other
    end
  end

  defp filter_spec do
    case Application.get_env(:phoenix, :filter_parameters, []) do
      {:keep, keep} when is_list(keep) ->
        {:keep, Enum.map(keep, &normalize_filter/1)}

      {:discard, discard} when is_list(discard) ->
        {:discard, Enum.uniq(@default_filtered_keys ++ Enum.map(discard, &normalize_filter/1))}

      discard when is_list(discard) ->
        {:discard, Enum.uniq(@default_filtered_keys ++ Enum.map(discard, &normalize_filter/1))}

      _ ->
        {:discard, @default_filtered_keys}
    end
  end

  defp normalize_filter(key), do: key |> to_string() |> String.downcase()

  defp scrub_term(_term, _filters, depth) when depth >= @max_scrub_depth, do: "[REDACTED]"

  defp scrub_term(%Plug.Conn{}, _filters, _depth), do: "[REDACTED Plug.Conn]"

  defp scrub_term(term, filters, depth) when is_struct(term) do
    Map.new(term, fn
      {:__struct__, mod} ->
        {:__struct__, mod}

      {key, value} ->
        if sensitive_key?(key, filters) do
          {key, "[FILTERED]"}
        else
          {key, scrub_term(value, filters, depth + 1)}
        end
    end)
  end

  defp scrub_term(term, filters, depth) when is_map(term) do
    Map.new(term, fn {key, value} ->
      if sensitive_key?(key, filters) do
        {key, "[FILTERED]"}
      else
        {key, scrub_term(value, filters, depth + 1)}
      end
    end)
  end

  defp scrub_term(term, filters, depth) when is_list(term) do
    if key_value_list?(term) do
      Enum.map(term, fn {key, value} ->
        if sensitive_key?(key, filters) do
          {key, "[FILTERED]"}
        else
          {key, scrub_term(value, filters, depth + 1)}
        end
      end)
    else
      scrub_list(term, filters, depth + 1)
    end
  end

  # Preserve standalone result tuples under `{:keep, ...}` while still
  # scrubbing their payload; keyword entries are handled in `key_value_list?/1`.
  defp scrub_term({tag, value}, filters, depth) when tag in [:ok, :error] do
    {tag, scrub_term(value, filters, depth + 1)}
  end

  defp scrub_term({key, value}, filters, depth) when is_binary(key) or is_atom(key) do
    if sensitive_key?(key, filters) do
      {key, "[FILTERED]"}
    else
      {key, scrub_term(value, filters, depth + 1)}
    end
  end

  defp scrub_term(term, filters, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&scrub_term(&1, filters, depth + 1))
    |> List.to_tuple()
  end

  defp scrub_term(term, _filters, _depth), do: term

  defp key_value_list?([]), do: false
  defp key_value_list?(list), do: proper_kv_list?(list)

  defp proper_kv_list?([{key, _value} | rest]) when is_binary(key) or is_atom(key),
    do: proper_kv_list?(rest)

  defp proper_kv_list?([]), do: true
  defp proper_kv_list?(_), do: false

  defp scrub_list([], _filters, _depth), do: []

  defp scrub_list([head | tail], filters, depth) when is_list(tail) do
    [scrub_term(head, filters, depth) | scrub_list(tail, filters, depth)]
  end

  defp scrub_list([head | tail], filters, depth) do
    [scrub_term(head, filters, depth) | scrub_term(tail, filters, depth)]
  end

  defp sensitive_key?(key, {:discard, patterns}) when is_binary(key) or is_atom(key) do
    key_str = key |> to_string() |> String.downcase()
    Enum.any?(patterns, &String.contains?(key_str, &1))
  end

  defp sensitive_key?(key, {:keep, allowed}) when is_binary(key) or is_atom(key) do
    key_str = key |> to_string() |> String.downcase()

    Enum.any?(@default_filtered_keys, &String.contains?(key_str, &1)) or
      key_str not in allowed
  end

  defp sensitive_key?(_key, _filters), do: false
end
