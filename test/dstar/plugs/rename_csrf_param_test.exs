defmodule Dstar.Plugs.RenameCsrfParamTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Dstar.Plugs.RenameCsrfParam

  describe "init/1" do
    test "defaults to 'csrf' as source param" do
      opts = RenameCsrfParam.init([])
      assert opts == %{from: "csrf"}
    end

    test "accepts custom :from option" do
      opts = RenameCsrfParam.init(from: "my_token")
      assert opts == %{from: "my_token"}
    end

    test "accepts custom :from option as string" do
      opts = RenameCsrfParam.init(from: "custom_csrf")
      assert opts == %{from: "custom_csrf"}
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

    test "handles nil source param value", %{opts: opts} do
      conn =
        conn(:post, "/test")
        |> Map.put(:params, %{"csrf" => nil})
        |> Map.put(:body_params, %{"csrf" => nil})

      result = RenameCsrfParam.call(conn, opts)

      # Should copy nil value
      assert result.body_params["_csrf_token"] == nil
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
end
