defmodule Dstar.Plugs.RenameCsrfParam do
  @moduledoc """
  Renames a CSRF body param to `_csrf_token` so that `Plug.CSRFProtection`
  can find it.

  ## Why this exists

  Phoenix expects the CSRF token in `conn.body_params["_csrf_token"]` (or
  the `x-csrf-token` header). Datastar sends its signals with every
  request, but `_`-prefixed signal keys are front-end-only — never sent to
  the backend — so a token named `_csrf_token` would never arrive.

  The shim: expose the token as a **non-prefixed** signal (default `csrf`).
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

  Only **binary** values count as tokens. If a source carries any other
  type (`nil`, a list from `csrf[]=x`, a number or object from a JSON
  body), that source is skipped and the next one is considered — so a
  malformed signal behaves like a missing token and `Plug.CSRFProtection`
  rejects the request with its ordinary invalid-token error. This keeps
  request-controlled arguments of the wrong type out of the crypto code
  paths (see CVE-2026-105963's guidance on typed arguments to `Plug.Crypto`).

  ## Token source precedence

  This plug only writes `body_params["_csrf_token"]` when that key is
  absent. Sources are considered in this order:

  1. Existing `body_params["_csrf_token"]` — left untouched (Phoenix forms).
  2. The source signal in `body_params` (default `csrf`) — POST/PUT/PATCH.
  3. The same key inside the `datastar` query parameter — GET/DELETE.
  4. A last-resort top-level `params` source key (not query `_csrf_token`).

  A query-string `_csrf_token` is **not** a source and does **not** suppress
  (2)–(4). `Plug.CSRFProtection` looks at `body_params`, not merged
  `params`.

  The `x-csrf-token` header is not read or written here.
  `Plug.CSRFProtection` then validates `body_params["_csrf_token"]` first,
  then the header. Prefer the header when you want the token out of URLs.

  ## Security note

  Because the token is a non-prefixed signal, it rides along on **every**
  request — and on GET/DELETE that means the **URL query string**, not the
  body. The token is still validated cryptographically against the
  session-derived value by `Plug.CSRFProtection`, so this does not weaken
  forgery protection. But a per-session credential sitting in URLs ends up
  in access/proxy logs and same-origin `Referer` headers. If that matters
  for your threat model, see the README's CSRF section for hardening
  options (redact the entire `datastar` query value from logs/APM, set
  `Referrer-Policy` to `no-referrer` or `origin`, or send `x-csrf-token`).

  Session and cookie authentication identify the user; they do not prove
  who initiated the request. Cookie-authenticated state-changing routes
  still need `Plug.CSRFProtection` (or a comparably strong Origin /
  Fetch-Metadata policy).

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
    # Plug.CSRFProtection reads body_params, not merged params. A query
    # `_csrf_token` must not suppress a body or datastar source.
    case conn.body_params do
      %{"_csrf_token" => _} ->
        conn

      _ ->
        datastar_value =
          case datastar_token(conn.params, datastar_param, from) do
            {:ok, token} ->
              token

            :error ->
              :missing
          end

        [conn.body_params[from], datastar_value, conn.params[from]]
        |> Enum.find(:missing, &is_token/1)
        |> case do
          token when is_binary(token) -> put_csrf_token(conn, token)
          :missing -> conn
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

  # Only a nonempty binary is a plausible CSRF token. Anything else (nil,
  # list, number, map) is request-controlled garbage — e.g. `csrf[]=x`
  # yields a list and a JSON body `{"csrf": null}` yields nil — and the
  # source is skipped, leaving the next one to be considered, so a
  # wrong-typed argument never reaches `Plug.CSRFProtection` (and,
  # underneath it, `Plug.Crypto`). (CVE-2026-105963 hardening.)
  defp is_token(token) when is_binary(token) and token != "", do: true
  defp is_token(_token), do: false

  defp put_csrf_token(conn, token) do
    %{conn | body_params: Map.put(conn.body_params, "_csrf_token", token)}
  end
end
