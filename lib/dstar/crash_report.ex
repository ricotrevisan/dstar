defmodule Dstar.CrashReport do
  @moduledoc false

  # Crash reporting shared by `Dstar.Plugs.Dispatch` and `Dstar.Page.Plug`.
  #
  # A stack frame can carry the call's arguments instead of its arity (the
  # top frame of a `FunctionClauseError` always does). For a handler those
  # arguments are the conn and the signals, so formatting or re-raising the
  # raw stacktrace would copy cookies, the authorization header, the CSRF
  # token and every signal (passwords included) into logs, error trackers
  # and the browser console. Phoenix strips them for controller actions the
  # same way.

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
    Exception.format(:error, exception, scrub(stacktrace))
  end
end
