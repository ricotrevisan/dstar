defmodule Dstar.Plugs.RenameCsrfParam do
  @moduledoc """
  Renames a CSRF body param to `_csrf_token` so that `Plug.CSRFProtection`
  can find it.

  ## Why this exists

  Datastar treats signals whose names start with `_` as **client-only** —
  they are never sent to the server in the request body. The conventional
  CSRF signal (`_csrf-token` / `$_csrfToken`) is therefore delivered as an
  `x-csrf-token` **header**, which works for Dstar SSE routes that bypass
  `Plug.CSRFProtection`.

  However, regular Phoenix form POSTs (e.g. sign-in, settings) still go
  through `Plug.CSRFProtection`, which looks for the token in
  `conn.body_params["_csrf_token"]`. Because the `_`-prefixed signal is
  never included in the body, those requests would fail with a 403.

  The workaround is to send the token as a **non-prefixed** signal (default
  `csrf`) so it *is* included in the request body. This plug then copies
  that param into `_csrf_token` in `body_params` before
  `Plug.CSRFProtection` runs.

  ## Usage

      # In your Phoenix router (before :protect_from_forgery):
      plug Dstar.Plugs.RenameCsrfParam

      # With a custom source param name:
      plug Dstar.Plugs.RenameCsrfParam, from: "my_token"

  ## Options

  - `:from` — Source param name to copy from. Default: `"csrf"`.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    %{from: Keyword.get(opts, :from, "csrf")}
  end

  @impl Plug
  def call(conn, %{from: from}) do
    case conn.params do
      %{"_csrf_token" => _} ->
        conn

      %{^from => token} ->
        %{conn | body_params: Map.put(conn.body_params, "_csrf_token", token)}

      _ ->
        conn
    end
  end
end
