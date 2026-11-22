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

    test "redacts sensitive keys inside keyword lists and header tuples" do
      headers = [
        {"cookie", "_app_key=SESSION-COOKIE"},
        {"authorization", "Bearer API-TOKEN"},
        {"accept", "text/event-stream"}
      ]

      opts = [password: "hunter2", csrf: "SECRET-CSRF", ok: true]

      formatted = CrashReport.format(%MatchError{term: {headers, opts}}, [])

      assert formatted =~ "text/event-stream"
      assert formatted =~ "ok: true"
      assert formatted =~ "[FILTERED]"

      for secret <- ["SESSION-COOKIE", "API-TOKEN", "hunter2", "SECRET-CSRF"] do
        refute formatted =~ secret
      end
    end

    test "applies Phoenix {:keep, ...} allowlist to keyword and header tuples while preserving {:ok, _} and {:error, _}" do
      previous = Application.get_env(:phoenix, :filter_parameters)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:phoenix, :filter_parameters)
        else
          Application.put_env(:phoenix, :filter_parameters, previous)
        end
      end)

      Application.put_env(:phoenix, :filter_parameters, {:keep, ["id"]})

      ok_formatted =
        CrashReport.format(
          %MatchError{
            term: {:ok, [id: 7, ssn: "123-45-6789", ok: "SECRET-OK", error: "SECRET-ERR"]}
          },
          []
        )

      err_formatted =
        CrashReport.format(
          %MatchError{term: {:error, [{"x-custom", "SECRET-HDR"}, {"id", "7"}]}},
          []
        )

      assert ok_formatted =~
               "{:ok, [id: 7, ssn: \"[FILTERED]\", ok: \"[FILTERED]\", error: \"[FILTERED]\"]}"

      assert err_formatted =~ "{:error, [{\"x-custom\", \"[FILTERED]\"}, {\"id\", \"7\"}]}"

      for secret <- ["123-45-6789", "SECRET-OK", "SECRET-ERR", "SECRET-HDR"] do
        refute ok_formatted =~ secret
        refute err_formatted =~ secret
      end
    end
  end
end
