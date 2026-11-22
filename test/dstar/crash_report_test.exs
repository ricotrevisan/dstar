defmodule Dstar.CrashReportTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Dstar.CrashReport

  describe "format/2" do
    test "redacts sensitive keys in MatchError terms while keeping non-sensitive keys" do
      signals = %{
        "csrf" => "SECRET-CSRF",
        "password" => "hunter2",
        "api_key" => "sk-live-123",
        "count" => 42
      }

      exception = %MatchError{term: signals}
      formatted = CrashReport.format(exception, [])

      assert formatted =~ "MatchError"
      assert formatted =~ "\"count\" => 42"
      assert formatted =~ "[FILTERED]"

      for secret <- ["SECRET-CSRF", "hunter2", "sk-live-123"] do
        refute formatted =~ secret
      end
    end

    test "redacts Plug.Conn and nested secrets across exception structs" do
      conn =
        conn(:post, "/secret")
        |> Plug.Conn.put_req_header("cookie", "_app_key=SESSION-COOKIE")
        |> Plug.Conn.put_req_header("authorization", "Bearer API-TOKEN")

      exceptions = [
        %MatchError{term: {:ok, conn}},
        %CaseClauseError{term: %{conn: conn, token: "SECRET-TOK"}},
        %KeyError{
          key: :missing,
          term: %{"csrf" => "SECRET-CSRF", "user" => %{"password" => "pw123"}}
        },
        %WithClauseError{term: {:error, conn}},
        %Protocol.UndefinedError{protocol: Enumerable, value: conn}
      ]

      for exception <- exceptions do
        formatted = CrashReport.format(exception, [])

        for secret <- ["SESSION-COOKIE", "API-TOKEN", "SECRET-TOK", "SECRET-CSRF", "pw123"] do
          refute formatted =~ secret
        end
      end
    end

    test "respects Phoenix :filter_parameters config" do
      previous = Application.get_env(:phoenix, :filter_parameters)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:phoenix, :filter_parameters)
        else
          Application.put_env(:phoenix, :filter_parameters, previous)
        end
      end)

      Application.put_env(:phoenix, :filter_parameters, ["ssn"])

      formatted =
        CrashReport.format(%MatchError{term: %{"ssn" => "123-45-6789", "csrf" => "TOK"}}, [])

      refute formatted =~ "123-45-6789"
      refute formatted =~ "TOK"
    end
  end
end
