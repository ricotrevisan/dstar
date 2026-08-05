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
  Because it is not `_`-prefixed, Datastar includes it in every request.
  This plug then copies that value into `_csrf_token` in `body_params`
  before `Plug.CSRFProtection` runs.

  ## How the token travels (Datastar v1.0)

  Datastar transports signals differently depending on the HTTP method:

  - **POST / PUT / PATCH** — signals are sent as the JSON request body, so
    the token arrives as a top-level body param (e.g. `body_params["csrf"]`).
  - **GET / DELETE** — signals are serialized into the `datastar` URL query
    parameter as a JSON object (e.g. `?datastar={"csrf":"..."}`), because
    these methods carry no body. This plug decodes that parameter and
    extracts the token from it, so DELETE requests — which
    `Plug.CSRFProtection` *does* check — pass validation too.

  The plug checks both channels, so one setup covers page `event()` POSTs,
  stream `connect()` POSTs, component events, and all verb helpers.

  ## Security note

  Because the token is a non-prefixed signal, it rides along on **every**
  request — and on GET/DELETE that means the **URL query string**, not the
  body. The token is still validated cryptographically against the
  session-derived value by `Plug.CSRFProtection`, so this does not weaken
  forgery protection. But a per-session credential sitting in URLs ends up
  in access/proxy logs and same-origin `Referer` headers. If that matters
  for your threat model, see the README's CSRF section for hardening
  options (log scrubbing, `Referrer-Policy`, header-based transport).

  ## Usage

      # In your Phoenix router (before :protect_from_forgery):
      plug Dstar.Plugs.RenameCsrfParam

      # With a custom source param name:
      plug Dstar.Plugs.RenameCsrfParam, from: "my_token"

      # With a custom Datastar query param name (default "datastar"):
      plug Dstar.Plugs.RenameCsrfParam, datastar_param: "ds"

  ## Options

  - `:from` — Source param name to copy from. Default: `"csrf"`.
  - `:datastar_param` — Name of the Datastar query parameter that carries
    the signals JSON on GET/DELETE requests. Default: `"datastar"`.
  """

  @behaviour Plug

  @default_datastar_param "datastar"

  @impl Plug
  def init(opts) do
    %{
      from: Keyword.get(opts, :from, "csrf"),
      datastar_param: Keyword.get(opts, :datastar_param, @default_datastar_param)
    }
  end

  @impl Plug
  def call(conn, %{from: from, datastar_param: datastar_param}) do
    case conn.params do
      %{"_csrf_token" => _} ->
        conn

      %{^from => token} ->
        put_csrf_token(conn, token)

      params ->
        case datastar_token(params, datastar_param, from) do
          {:ok, token} -> put_csrf_token(conn, token)
          :error -> conn
        end
    end
  end

  # The `datastar` query parameter carries the signals JSON on GET/DELETE
  # requests (Datastar v1.0 sends no body for those methods). Mirrors how
  # `Dstar.Signals.read/1` decodes it.
  defp datastar_token(params, datastar_param, from) do
    case Map.get(params, datastar_param) do
      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, %{^from => token}} -> {:ok, token}
          _ -> :error
        end

      %{^from => token} ->
        {:ok, token}

      _ ->
        :error
    end
  end

  defp put_csrf_token(conn, token) do
    %{conn | body_params: Map.put(conn.body_params, "_csrf_token", token)}
  end
end
