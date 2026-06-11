defmodule Dstar.Plugs.RenameCsrfParam do
  @moduledoc """
  Renames a CSRF body param to `_csrf_token` so that `Plug.CSRFProtection`
  can find it.

  ## Why this exists

  Datastar has no built-in CSRF support — it does not read Phoenix's
  `<meta name="csrf-token">` tag and never sets an `x-csrf-token` header.
  `Plug.CSRFProtection` looks for the token in
  `conn.body_params["_csrf_token"]` or the `x-csrf-token` header, so plain
  Datastar requests fail CSRF protection out of the box.

  The fix: expose the token as a **non-prefixed** signal (default `csrf`).
  Because it is not `_`-prefixed, Datastar includes it in every request
  body — page events, stream connects, component events, and helper routes
  alike. This plug then copies that param into `_csrf_token` in
  `body_params` before `Plug.CSRFProtection` runs.

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
