defmodule Dstar.Plugs.RenameCsrfParamTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.Plugs.RenameCsrfParam

  describe "init/1" do
    test "defaults to 'csrf' as source param" do
      opts = RenameCsrfParam.init([])
      assert opts.from == "csrf"
      assert opts.datastar_param == "datastar"
    end

    test "accepts custom :from option" do
      opts = RenameCsrfParam.init(from: "my_token")
      assert opts.from == "my_token"
    end

    test "accepts custom :from option as string" do
      opts = RenameCsrfParam.init(from: "custom_csrf")
      assert %{from: "custom_csrf", datastar_param: "datastar"} = opts
    end

    test "accepts custom :datastar_param option" do
      opts = RenameCsrfParam.init(datastar_param: "ds")
      assert %{from: "csrf", datastar_param: "ds"} = opts
    end

    test "defaults include the standard datastar param name" do
      opts = RenameCsrfParam.init([])

      assert opts == %{
               from: "csrf",
               datastar_param: "datastar",
               max_bytes: Dstar.Signals.default_max_bytes()
             }
    end
  end

  describe "call/2" do
    setup do
      opts = RenameCsrfParam.init([])
      %{opts: opts}
    end

    test "copies csrf param to _csrf_token in body_params", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => "token-123", "other" => "value"})
        |> Map.put(:body_params, %{"csrf" => "token-123", "other" => "value"})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "token-123"
      assert result.body_params["csrf"] == "token-123"
      assert result.body_params["other"] == "value"
    end

    test "is a no-op when _csrf_token already exists", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"_csrf_token" => "existing", "csrf" => "new"})
        |> Map.put(:body_params, %{"_csrf_token" => "existing", "csrf" => "new"})

      result = RenameCsrfParam.call(conn, opts)

      # Should not overwrite existing _csrf_token
      assert result.body_params["_csrf_token"] == "existing"
      # Original conn should be returned unchanged
      assert result == conn
    end

    test "is a no-op when source param is missing", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"other" => "value"})
        |> Map.put(:body_params, %{"other" => "value"})

      result = RenameCsrfParam.call(conn, opts)

      # Should not add _csrf_token
      refute Map.has_key?(result.body_params, "_csrf_token")
      # Original conn should be returned unchanged
      assert result == conn
    end

    test "works with custom source param name" do
      opts = RenameCsrfParam.init(from: "my_token")

      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"my_token" => "custom-123"})
        |> Map.put(:body_params, %{"my_token" => "custom-123"})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "custom-123"
      assert result.body_params["my_token"] == "custom-123"
    end

    test "handles empty params", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "only modifies body_params, not params", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => "token-456"})
        |> Map.put(:body_params, %{"csrf" => "token-456"})

      result = RenameCsrfParam.call(conn, opts)

      # _csrf_token should only appear in body_params
      assert result.body_params["_csrf_token"] == "token-456"
      refute Map.has_key?(result.params, "_csrf_token")
    end

    test "preserves other body_params", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{
          "csrf" => "token-789",
          "username" => "alice",
          "password" => "secret"
        })
        |> Map.put(:body_params, %{
          "csrf" => "token-789",
          "username" => "alice",
          "password" => "secret"
        })

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "token-789"
      assert result.body_params["csrf"] == "token-789"
      assert result.body_params["username"] == "alice"
      assert result.body_params["password"] == "secret"
    end

    test "ignores a nil source param value", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => nil})
        |> Map.put(:body_params, %{"csrf" => nil})

      result = RenameCsrfParam.call(conn, opts)

      # Non-binary tokens are ignored (CVE-2026-105963 hardening): the
      # request fails CSRF validation like a missing token instead of
      # `Plug.Crypto` receiving a wrong-typed argument.
      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "ignores a list source param value (`csrf[]=x`)", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => ["x"]})
        |> Map.put(:body_params, %{"csrf" => ["x"]})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "ignores non-binary source tokens from a JSON body (number, map)", %{opts: opts} do
      for token <- [123, %{"evil" => true}] do
        conn =
          conn(:post, "/test")
          |> Map.put(:params, %{"csrf" => token})
          |> Map.put(:body_params, %{"csrf" => token})

        result = RenameCsrfParam.call(conn, opts)

        refute Map.has_key?(result.body_params, "_csrf_token")
        assert result == conn
      end
    end

    test "ignores an empty binary source param value", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => ""})
        |> Map.put(:body_params, %{"csrf" => ""})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "ignores a non-binary token inside the datastar param", %{opts: opts} do
      conn =
        conn(:delete, "/test?datastar=%7B%22csrf%22%3A%5B%22x%22%5D%7D")
        |> Map.put(:query_params, %{"datastar" => ~s({"csrf":["x"]})})
        |> Map.put(:params, %{"datastar" => ~s({"csrf":["x"]})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "non-binary body token does not suppress a datastar token", %{opts: opts} do
      # A body `csrf` of the wrong type must behave like a missing token:
      # precedence continues with the next documented source.
      conn =
        split_conn(
          :post,
          "/test",
          %{"datastar" => ~s({"csrf":"ds-token"})},
          %{"csrf" => ["x"]}
        )

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "ds-token"
    end

    test "handles token with special characters", %{opts: opts} do
      token = "abc123-XYZ_789+/="

      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => token})
        |> Map.put(:body_params, %{"csrf" => token})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == token
    end

    test "works when csrf is the only param", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => "only-token"})
        |> Map.put(:body_params, %{"csrf" => "only-token"})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "only-token"
      assert result.body_params["csrf"] == "only-token"
      assert map_size(result.body_params) == 2
    end
  end

  describe "datastar query param (GET/DELETE)" do
    setup do
      opts = RenameCsrfParam.init([])
      %{opts: opts}
    end

    test "leaves GET, HEAD and OPTIONS untouched (Plug.CSRFProtection skips them)", %{
      opts: opts
    } do
      for method <- [:get, :head, :options] do
        conn =
          conn(method, "/test")
          |> Map.put(:query_params, %{"datastar" => ~s({"csrf":"token-123"})})
          |> Map.put(:params, %{"datastar" => ~s({"csrf":"token-123"}), "csrf" => "t"})
          |> Map.put(:body_params, %{})

        assert RenameCsrfParam.call(conn, opts) == conn
      end
    end

    test "extracts csrf from the datastar query param on PATCH", %{opts: opts} do
      conn =
        conn(:patch, "/test")
        |> Map.put(:query_params, %{"datastar" => ~s({"csrf":"token-123","count":5})})
        |> Map.put(:params, %{"datastar" => ~s({"csrf":"token-123","count":5})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "token-123"
      assert result.body_params["csrf"] == nil
    end

    test "extracts csrf from the datastar query param on DELETE", %{opts: opts} do
      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"datastar" => ~s({"csrf":"token-456"})})
        |> Map.put(:params, %{"datastar" => ~s({"csrf":"token-456"})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "token-456"
    end

    test "works with custom :from via the datastar param", %{} do
      opts = RenameCsrfParam.init(from: "my_token")

      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"datastar" => ~s({"my_token":"custom-123"})})
        |> Map.put(:params, %{"datastar" => ~s({"my_token":"custom-123"})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "custom-123"
    end

    test "works with custom :datastar_param", %{} do
      opts = RenameCsrfParam.init(datastar_param: "ds")

      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"ds" => ~s({"csrf":"ds-token"})})
        |> Map.put(:params, %{"ds" => ~s({"csrf":"ds-token"})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "ds-token"
    end

    test "handles already-decoded datastar map", %{opts: opts} do
      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"datastar" => %{"csrf" => "map-token"}})
        |> Map.put(:params, %{"datastar" => %{"csrf" => "map-token"}})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "map-token"
    end

    test "is a no-op when datastar param has no csrf key", %{opts: opts} do
      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"datastar" => ~s({"count":5})})
        |> Map.put(:params, %{"datastar" => ~s({"count":5})})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "is a no-op when datastar param is malformed JSON", %{opts: opts} do
      conn =
        conn(:delete, "/test")
        |> Map.put(:query_params, %{"datastar" => "not-json{{"})
        |> Map.put(:params, %{"datastar" => "not-json{{"})
        |> Map.put(:body_params, %{})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert result == conn
    end

    test "prefers top-level csrf param over the datastar param", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => "top-level", "datastar" => ~s({"csrf":"nested"})})
        |> Map.put(:body_params, %{"csrf" => "top-level"})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "top-level"
    end

    test "existing _csrf_token wins over the datastar param", %{opts: opts} do
      conn =
        conn(:delete, "/test")
        |> Map.put(:params, %{"_csrf_token" => "existing", "datastar" => ~s({"csrf":"nested"})})
        |> Map.put(:body_params, %{"_csrf_token" => "existing"})

      result = RenameCsrfParam.call(conn, opts)

      assert result == conn
      assert result.body_params["_csrf_token"] == "existing"
    end
  end

  describe "token source precedence with split query/body maps" do
    setup do
      opts = RenameCsrfParam.init([])
      %{opts: opts}
    end

    test "a query _csrf_token does not suppress a body source token", %{opts: opts} do
      conn =
        split_conn(:post, "/test", %{"_csrf_token" => "query-junk"}, %{"csrf" => "body-token"})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "body-token"
    end

    test "a query _csrf_token does not suppress a datastar source token", %{opts: opts} do
      conn =
        split_conn(
          :delete,
          "/test",
          %{"_csrf_token" => "query-junk", "datastar" => ~s({"csrf":"ds-token"})},
          %{}
        )

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "ds-token"
    end

    test "a query _csrf_token is not copied into body_params", %{opts: opts} do
      conn = split_conn(:post, "/test", %{"_csrf_token" => "query-only"}, %{"other" => "value"})

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
    end

    test "existing body _csrf_token is not overwritten by a body source token", %{opts: opts} do
      conn =
        split_conn(:post, "/test", %{}, %{
          "_csrf_token" => "form-token",
          "csrf" => "signal-token"
        })

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "form-token"
    end

    test "existing body _csrf_token is not overwritten by a datastar token", %{opts: opts} do
      conn =
        split_conn(
          :post,
          "/test",
          %{"datastar" => ~s({"csrf":"ds-token"})},
          %{"_csrf_token" => "form-token"}
        )

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "form-token"
    end

    test "body source token wins over a conflicting datastar token", %{opts: opts} do
      conn =
        split_conn(
          :post,
          "/test",
          %{"datastar" => ~s({"csrf":"ds-token"})},
          %{"csrf" => "body-token"}
        )

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "body-token"
    end

    test "datastar token wins over a query-only source param", %{opts: opts} do
      conn =
        split_conn(
          :delete,
          "/test",
          %{"csrf" => "query-csrf", "datastar" => ~s({"csrf":"ds-token"})},
          %{}
        )

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "ds-token"
    end

    test "copies a query-only source param when no body or datastar token is present", %{
      opts: opts
    } do
      conn = split_conn(:delete, "/test", %{"csrf" => "query-csrf"}, %{})

      result = RenameCsrfParam.call(conn, opts)

      assert result.body_params["_csrf_token"] == "query-csrf"
    end

    test "does not copy x-csrf-token into body_params", %{opts: opts} do
      conn =
        split_conn(:post, "/test", %{}, %{"other" => "value"})
        |> Plug.Conn.put_req_header("x-csrf-token", "header-token")

      result = RenameCsrfParam.call(conn, opts)

      refute Map.has_key?(result.body_params, "_csrf_token")
      assert Plug.Conn.get_req_header(result, "x-csrf-token") == ["header-token"]
    end

    test "still copies a body source token when an x-csrf-token header is also present", %{
      opts: opts
    } do
      conn =
        split_conn(:post, "/test", %{}, %{"csrf" => "body-token"})
        |> Plug.Conn.put_req_header("x-csrf-token", "header-token")

      result = RenameCsrfParam.call(conn, opts)

      # Plug.CSRFProtection checks body_params["_csrf_token"] before the header.
      assert result.body_params["_csrf_token"] == "body-token"
      assert Plug.Conn.get_req_header(result, "x-csrf-token") == ["header-token"]
    end
  end

  describe "integration scenarios" do
    test "typical Phoenix form submission flow" do
      # Init plug with default settings
      opts = RenameCsrfParam.init([])

      # Simulate a form POST with csrf as non-prefixed signal
      conn =
        conn(:post, "/session")
        |> Map.put(:params, %{
          "csrf" => "generated-token-abc",
          "user" => %{"email" => "user@example.com", "password" => "pass"}
        })
        |> Map.put(:body_params, %{
          "csrf" => "generated-token-abc",
          "user" => %{"email" => "user@example.com", "password" => "pass"}
        })

      result = RenameCsrfParam.call(conn, opts)

      # Verify _csrf_token is now available for Plug.CSRFProtection
      assert result.body_params["_csrf_token"] == "generated-token-abc"
      # Original csrf param should still exist
      assert result.body_params["csrf"] == "generated-token-abc"
      # Other params should be preserved
      assert result.body_params["user"]["email"] == "user@example.com"
    end

    test "already protected route (token exists)" do
      opts = RenameCsrfParam.init([])

      # Simulate a request that already has _csrf_token (e.g., traditional form)
      conn =
        conn(:post, "/settings")
        |> Map.put(:params, %{
          "_csrf_token" => "existing-token",
          "setting" => "value"
        })
        |> Map.put(:body_params, %{
          "_csrf_token" => "existing-token",
          "setting" => "value"
        })

      result = RenameCsrfParam.call(conn, opts)

      # Should not modify anything
      assert result == conn
      assert result.body_params["_csrf_token"] == "existing-token"
    end
  end

  describe "bounded decoding (audit A2)" do
    setup do
      %{opts: RenameCsrfParam.init([])}
    end

    test "a `datastar` key in a POST body is not a token source", %{opts: opts} do
      conn = split_conn(:post, "/test", %{}, %{"datastar" => ~s({"csrf":"body-ds"})})

      refute Map.has_key?(RenameCsrfParam.call(conn, opts).body_params, "_csrf_token")
    end

    test "a valid body token stops before the datastar query is decoded", %{opts: opts} do
      # Malformed JSON would be skipped either way; a huge nested value
      # proves the decode never runs by keeping this fast.
      nested = String.duplicate("[", 200_000) <> String.duplicate("]", 200_000)

      conn =
        split_conn(:post, "/test", %{"datastar" => nested}, %{"csrf" => "body-token"})

      {micros, result} = :timer.tc(fn -> RenameCsrfParam.call(conn, opts) end)

      assert result.body_params["_csrf_token"] == "body-token"
      assert micros < 20_000
    end

    test "skips a datastar query value over :max_bytes" do
      opts = RenameCsrfParam.init(max_bytes: 32)
      big = ~s({"csrf":"ds-token","pad":") <> String.duplicate("x", 64) <> ~s("})

      conn = split_conn(:delete, "/test", %{"datastar" => big}, %{})
      refute Map.has_key?(RenameCsrfParam.call(conn, opts).body_params, "_csrf_token")

      small = split_conn(:delete, "/test", %{"datastar" => ~s({"csrf":"ds"})}, %{})
      assert RenameCsrfParam.call(small, opts).body_params["_csrf_token"] == "ds"
    end

    test "passes through when no parser fetched the body (text/plain POST)", %{opts: opts} do
      parsers =
        Plug.Parsers.init(parsers: [:urlencoded, {:json, json_decoder: Jason}], pass: ["*/*"])

      conn =
        conn(:post, "/test", "hello=world")
        |> Plug.Conn.put_req_header("content-type", "text/plain")
        |> Plug.Parsers.call(parsers)

      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert RenameCsrfParam.call(conn, opts) == conn
    end
  end

  # Plug merges query then body (body wins on key conflict). Tests that
  # reproduce the query-vs-body suppression bug must keep the maps split.
  defp split_conn(method, path, query_params, body_params) do
    conn(method, path)
    |> Map.put(:query_params, query_params)
    |> Map.put(:body_params, body_params)
    |> Map.put(:params, Map.merge(query_params, body_params))
  end
end
