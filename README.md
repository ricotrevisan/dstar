# Dstar

[![Hex.pm](https://img.shields.io/hexpm/v/dstar)](https://hex.pm/packages/dstar)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/dstar)

**The batteries-included Datastar toolkit for Elixir.** SSE helpers, event dispatch, CSRF handling, stream deduplication — everything you need to ship Datastar apps, not just the wire protocol.

> Successor to [PhoenixDatastar](https://hex.pm/packages/phoenix_datastar).

## Why Dstar?

Other libraries give you SSE primitives and leave the rest to you. Dstar gives you the primitives **and** the utilities you'd end up building yourself:

- **Pages** — `use Dstar.Page` puts render, event handlers, streaming callbacks, and components in one module. One router line wires it.
- **Event dispatch** — One route, unlimited handlers. `Dstar.Plugs.Dispatch` routes events to handler modules by convention, so you never hand-wire a route per action.
- **Safe URL generation** — `Dstar.post/2`, `Dstar.get/2`, and the page/component helpers encode caller values as literal path segments and serialize JavaScript strings. No hand-written URLs or caller text in executable syntax.
- **CSRF handling** — Phoenix wants `_csrf_token`, but Datastar keeps
  `_`-prefixed signals client-side. So the token travels as a non-prefixed
  signal, and `Dstar.Plugs.RenameCsrfParam` maps it back — one plug, one
  `<body>` attribute, and forgery protection just works.
- **Stream deduplication** — `Dstar.Utility.StreamRegistry` gives each user+tab one linearizable active owner and tears replaced SSE streams down with a bounded, generation-safe handover.
- **Console logging** — `Dstar.console_log/2` sends log/warn/error messages straight to the browser DevTools. Debug from the server, read in the browser.
- **Phoenix.HTML support** — `patch_elements` accepts both raw strings and `Phoenix.HTML.safe()` tuples, so HEEx template output works without conversion.

The functional core is still a small bag of functions with no processes. The page layer on top is one behaviour, one plug, and two router macros — all opt-in, all readable. The one optional process — `StreamRegistry` — is opt-in only if you need stream deduplication.

Drop it into any Plug-based app: Phoenix controllers, plain Plug, Bandit. If you have a `%Plug.Conn{}`, you can use Dstar.

## Installation

Add `dstar` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:dstar, "~> 0.2.0"}
  ]
end
```

Pages need `{:phoenix, "~> 1.7"}` and `{:phoenix_live_view, "~> 1.0"}` in your app (any Phoenix app already has them). The functional core needs neither.

Then add the Datastar client script to your root layout's `<head>`:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0/bundles/datastar.js"></script>
```

That's it. No generators, no config, no application callback.

## Quick Start

A page is **one module and one router line**.

```elixir
# router.ex
import Dstar.Router
dstar "/counter", MyAppWeb.CounterPage
```

```elixir
defmodule MyAppWeb.CounterPage do
  use Dstar.Page

  # GET — load data, assign, render
  def mount(conn, _params) do
    assign(conn, count: 0, page_title: "Counter")
  end

  def render(assigns) do
    ~H"""
    <div data-signals:count={@count}>
      <h1 data-text="$count"></h1>
      <span id="history">—</span>
      <button data-on:click={event("increment")}>+1</button>
      <button data-on:click={event("reset")}>Reset</button>
    </div>
    """
  end

  # POST /counter/_event/<name> — SSE already started for you
  def handle_event(conn, "increment", signals) do
    count = (signals["count"] || 0) + 1

    conn
    |> patch_signals(%{count: count})
    |> patch(&history/1, last: "+1 → #{count}")
  end

  def handle_event(conn, "reset", _signals) do
    conn
    |> patch_signals(%{count: 0})
    |> patch(&history/1, last: "Reset")
    |> console_log("Counter reset")
  end

  # Colocated components — used by render/1 and by patches alike
  defp history(assigns) do
    ~H"""
    <span id="history">Last: {@last}</span>
    """
  end
end
```

That's the whole page. Notice what's *absent*:

- No separate controller, HTML, or components module — one file.
- No `handler={...}` / `prefix={...}` threading: `event("increment")`
  resolves its URL in the browser (`location.pathname + '/_event/...'`),
  so path params like `/:workspace_slug` need no server-side plumbing.
- No `Dstar.start()` — event POSTs are SSE by definition, so the
  library starts the stream before calling `handle_event/3`.
- No allowlist registration — the `dstar` route *is* the code
  allowlist, not an authorization check.

> **Routing through `:protect_from_forgery`?** Event POSTs need the CSRF
> token as a signal — one plug plus one `<body>` attribute. See
> [CSRF Protection Setup](#csrf-protection-setup).

### Streaming

Declare how to subscribe; the library owns the receive loop:

```elixir
  # In the same page module:
  def handle_connect(conn, _params) do
    MyAppWeb.Endpoint.subscribe("ticker")
    conn
  end

  def handle_info(%Phoenix.Socket.Broadcast{payload: p}, conn) do
    patch_signals(conn, %{tick: p.count})
  end
```

```heex
<div data-init={connect()} data-on:online__window={connect()}>
  <span data-text="$tick"></span>
</div>
```

The loop checks connection liveness every 30s (tune with
`use Dstar.Page, idle_check: 10_000`) and survives stray messages. Add a
`stream_key/1` callback to enable per-tab stream deduplication via
`Dstar.Utility.StreamRegistry`. If a valid keyed stream cannot claim the
coordinator, Page returns a normal halted 503 before `handle_connect/2` or the
receive loop.

When the loop ends — a `{:halt, conn}`, a dead client, or a takeover by a
newer stream for the same key — the library synchronously releases that exact
claim generation before `handle_disconnect/1`. A stale takeover message cannot
stop a newer stream reusing the same keep-alive process, and an escalation
cannot kill the process after release returns. App-owned state (PubSub
subscriptions, presence, caches) is yours to release in the optional callback:

```elixir
def handle_disconnect(conn) do
  Phoenix.PubSub.unsubscribe(MyApp.PubSub, "room:#{conn.assigns.room_id}")
end
```

This matters on HTTP/1.1 keep-alive, where the connection process outlives
the stream and goes on to serve unrelated requests.

### Authorization

`dstar/2` exposes three independent routes. Put session-wide
authentication on the surrounding pipeline so it covers GET, event POST,
stream POST, and `dstar_components/2`:

```elixir
scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  dstar "/settings", SettingsPage
  dstar_components "/ds", [DetailDrawer]
end
```

`mount/2` runs only on the GET. A tenant or ownership check there does
**not** protect a direct `POST /path/_event/:event` or `POST /path` —
those skip `mount/2` and start SSE before `handle_event/3` /
`handle_connect/2` can return a normal 401/403.

Use optional `authorize/2` for page-local checks. It runs after signals
are read and before SSE starts. Halt or send a response to reject;
return the conn (with any assigns you need) to continue:

```elixir
def authorize(conn, {:event, "export"}) do
  if admin?(conn) do
    conn
  else
    conn
    |> Plug.Conn.send_resp(403, "Forbidden")
    |> Plug.Conn.halt()
  end
end

def authorize(conn, {:event, _event}), do: conn

def authorize(conn, {:stream, _params}) do
  if conn.assigns[:current_user] do
    conn
  else
    conn
    |> Plug.Conn.send_resp(401, "Unauthorized")
    |> Plug.Conn.halt()
  end
end
```

The route is a *code* allowlist. Interpolating a record id into the
event name is fine; `authorize/2` (or the component handler, before
`start/1`) must still prove the current user may touch that id.

### Shared components

UI used across many pages — with its event handlers in the same module:

```elixir
defmodule MyAppWeb.DetailDrawer do
  use Dstar.Component

  def drawer(assigns) do
    ~H"""
    <div id="detail-drawer">
      <input data-on:change={event("change_title:#{@item.id}")} value={@item.title} />
    </div>
    """
  end

  def handle_event(conn, "change_title:" <> id, signals) do
    # The module allowlist only selects this handler. Authorize the
    # record *before* start/1 — after that the response is already 200 SSE.
    case Items.fetch_for_user(conn.assigns.current_user, id) do
      {:ok, item} ->
        {:ok, _} = Items.update_title(item, signals["title"])
        conn |> start() |> patch_signals(%{saved: true})

      :error ->
        conn
        |> Plug.Conn.send_resp(403, "Forbidden")
        |> Plug.Conn.halt()
    end
  end
end
```

```elixir
# router.ex — one line for ALL components:
dstar_components "/ds", [MyAppWeb.DetailDrawer]
```

Pages embed `<MyAppWeb.DetailDrawer.drawer item={@item} />` and need zero
`handle_event` clauses for it. If your app mounts routes under a prefix,
declare the dispatch base once in the root layout: `<body data-ds-base={...}>`
(defaults to `/ds`; it must match the base given to `dstar_components/2`,
including any app path prefix). `data-ds-base` is trusted configuration and
must be a local absolute application path beginning with one `/`; the helper
rejects protocol-relative values, dot segments, backslashes, queries, fragments, and controls.

Unlike page handlers, component handlers call `start()` themselves — the dispatch plug doesn't start the SSE response for them.

## The functional core

*Everything above is built from these functions. Use them directly in plain controllers, custom plugs, or anywhere you have a `%Plug.Conn{}` — pages are optional sugar, the core is the contract.*

Everything goes through the `Dstar` convenience module, which delegates to the lower-level modules listed below. Full signatures, options and examples live in the [API docs](https://hexdocs.pm/dstar/Dstar.html) — this table is a map, not a reference.

| Function | Does |
|----------|------|
| `start/1` | Open an SSE connection (`text/event-stream`, no-cache, chunked). |
| `start_stream/2,3` | Atomically claim and open a per-tab SSE stream. Keyed claim failure returns a halted non-SSE 503; arity 3 accepts signal-fetch options. |
| `check_connection/1` | `{:ok, conn}` / `{:error, conn}` — is the client still there? |
| `fetch_signals/1,2` | Safely fetch object-only signals and return `{:ok, signals, conn}` or an input error with the updated conn. |
| `read_signals/1` | Read signals only when body/query params are already fetched. |
| `patch_signals/2,3` | Patch signals on the client. |
| `remove_signals/2,3` | Remove signals by dot-notated path (or list of paths). |
| `nudge/2,3` | Tell tabs a collection changed, so each reloads with its own filters. |
| `patch_elements/3` | Patch DOM elements. Needs a `:selector`, or ids on the HTML roots. |
| `remove_elements/2,3` | Remove DOM elements by selector. |
| `append_elements/3,4` | Append HTML as the last child of a container. |
| `upsert_elements/2,3` | Morph the element whose id matches the HTML root. |
| `execute_script/2,3` | Run JavaScript on the client. |
| `redirect/2,3` | Navigate the client. Same-origin path-absolute by default; off-origin `http`/`https` needs `external: true` or `allow:`. |
| `console_log/2,3` | Log to the browser console. |
| `post/1,2,3` `get/1,2,3` `put/1,2,3` `patch/1,2,3` `delete/1,2,3` | Build `@post(...)`-style action expressions for Datastar attributes. Arity 1 is the dynamic form (`Dstar.post("increment")`), which resolves and encodes the module client-side. |

### Safe signal input

Signal documents are JSON **objects**. Arrays, scalars, and `null` are rejected;
malformed JSON is not treated as an empty object. Page routes and
`Dstar.Plugs.Dispatch` return 400 for malformed/non-object input and 413 for an
oversized payload, before SSE or an application handler starts. Their raw-input
limit defaults to 1,000,000 bytes. Pages can set
`use Dstar.Page, max_signal_bytes: ...`; Dispatch accepts the same plug option.

Phoenix normally runs `Plug.Parsers` first, so controller actions can use
`Dstar.read_signals/1` on the already-fetched map. Bound the parser too — Dstar
cannot recover the original byte size after parsing:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  json_decoder: Jason,
  length: 1_000_000,
  read_length: 1_000_000
```

A plain Plug that still owns the raw body must use the conn-returning API:

```elixir
case Dstar.fetch_signals(conn, max_bytes: 64_000) do
  {:ok, signals, conn} ->
    conn |> Dstar.start() |> Dstar.patch_signals(process(signals))

  {:error, reason, conn} ->
    Dstar.Signals.send_error(conn, reason) # 400, or 413 for :too_large
end
```

Always thread the returned conn; `Plug.Conn.read_body/2` updates adapter/body
state. GET and DELETE use the `datastar` query parameter and enforce the same
configured byte limit before JSON decoding. Missing signals and an empty raw
body mean `%{}`; an explicitly empty `datastar=` value is malformed.

### Safe action URL values

Core, Page, and Component actions share one URL builder. Event names and
literal module values are UTF-8 percent-encoded as **one route segment**, so
`/`, `\`, `?`, `#`, `%`, quotes, controls, and Unicode arrive at the handler
as data rather than executable syntax or URL structure. Empty, `.` and `..`
segments raise `ArgumentError` because browsers normalize them. The default
dynamic module signal is encoded under the same rules at runtime; `module:` is
a literal module override, not JavaScript or a signal name.

A core `prefix:` must be a local absolute application path beginning with one
`/`. Relative, protocol-relative/cross-origin, dot-segment, backslash, query, fragment, and
control-containing, malformed-percent, and non-UTF-8 prefixes raise `ArgumentError`.

`event(..., opts: "...")` and `connect(opts: "...")` accept a raw JavaScript
options object for developer-authored Datastar configuration. This is an
explicit **trusted-code escape hatch**: never interpolate request parameters,
stored values, slugs, or other data into `:opts`. Put data in event/module
values or signals instead.

## Real-time Streaming

With `Dstar.Page`, declare subscriptions in `handle_connect/2` and implement `handle_info/2` — the library owns the loop (see Quick Start). The hand-rolled loop below remains fully supported for plain controllers:

```elixir
defmodule MyAppWeb.TickerController do
  use MyAppWeb, :controller

  def stream(conn, _params) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "ticker")
    conn = Dstar.start(conn)
    loop(conn)
  end

  defp loop(conn) do
    receive do
      {:tick, count} ->
        # Optional: check connection health
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{tick: count})
            loop(conn)
          
          {:error, _conn} ->
            # Client disconnected, clean up
            Phoenix.PubSub.unsubscribe(MyApp.PubSub, "ticker")
            :ok
        end
    end
  end
end
```

**Template:**

Use `@post` with `retryMaxCount: Infinity` — Datastar handles reconnection
automatically. Add `data-on:online__window` to reconnect when the browser
comes back online (laptop lid, WiFi drop, etc.):

```heex
<div data-signals:tick="0"
     data-init="@post('/ticker/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/ticker/stream', {retryMaxCount: Infinity})">
  <span data-text="$tick"></span>
</div>
```

No keepalive loop needed on the server. Datastar's built-in retry handles
dropped connections, and `online__window` re-establishes the stream when the
network returns.

The library provides the SSE plumbing. Your app provides the PubSub topic and the business logic.

## Live Collections

Keeping a list current in every open tab is the most common streaming payload, and the obvious approach is a trap. The stream opened at page load and SSE is one-way, so it can never learn a tab's *current* filter, sort or page — blindly appending or morphing rows produces silently wrong UIs in every tab that isn't showing a plain feed.

The default is the **nudge**: push only "this data changed", and let each tab re-run its own load action, which carries that tab's signals.

```elixir
# Default — correct for filtered/sorted/paginated views
def handle_info({:posts_changed, _}, conn), do: nudge(conn, "posts")

# Fast path — plain, unfiltered feed only
def handle_info({:post_created, post}, conn),
  do: append_elements(conn, post_row(%{post: post}), "#posts")
```

```heex
<div id="posts" {on_nudge("posts", event("reload"))}>
```

Full pattern, DOM-id discipline and the consistency window: [Live collections](usage-rules/live-collections.md).

## Stream Deduplication (Optional)

With full-page navigation, SSE stream processes don't learn the client
disconnected until they try to write — which only happens on the next
PubSub broadcast or keepalive tick. In the meantime, zombie processes
hold subscriptions, run wasted DB queries on every broadcast, and on
HTTP/1.1 can exhaust the browser's 6-connection-per-origin limit.

`Dstar.Utility.StreamRegistry` fixes this. Its opt-in coordinator makes
claims linearizable: every user+tab key has one active owner, even when many
requests race. A new owner receives the key atomically, while the previous
generation gets a graceful Page teardown window and then bounded kill
escalation if it refuses to release.

This is the **one process** in Dstar. It's opt-in: if you don't need it,
the library stays zero-process. If you do, you add one child to your
existing supervision tree.

> With `Dstar.Page`, just define a `stream_key/1` callback — `Dstar.Page.Plug` calls `start_stream/2` for you. The manual `start`/`start_stream` swap in step 3 below applies to hand-rolled controller loops.

### 1. Add to your supervision tree

```elixir
# lib/my_app/application.ex
children = [
  Dstar.Utility.StreamRegistry,
  # ...
]
```

### 2. Add a `tabId` signal to your root layout

```heex
<body data-signals:tab-id="sessionStorage.getItem('_ds_tab') || (() => { const id = crypto.randomUUID(); sessionStorage.setItem('_ds_tab', id); return id; })()">
```

`sessionStorage` is per-tab — each tab gets its own UUID that persists
across navigations but is unique per tab. Multiple tabs work independently.

> **Why `tab-id` and not `tabId`?** HTML lowercases attribute names, so
> `data-signals:tabId` arrives as `tabid` and creates a signal named
> `tabid` — which never matches the `tabId` the registry reads, leaving
> dedup silently disabled. Datastar camelizes on hyphens, so `tab-id`
> is what produces `tabId`. This applies to every multi-word
> `data-signals:*` / `data-bind:*` attribute.

> **Why not `_tabId`?** Datastar treats `_`-prefixed signals as client-only
> and never sends them to the server. The signal needs to reach the backend,
> so it must not have a `_` prefix.

### 3. Replace `Dstar.start(conn)` in stream controllers

```elixir
conn = Dstar.start_stream(conn, scope.user.id)

if conn.halted do
  # A valid keyed request could not claim the coordinator. This is an
  # ordinary non-SSE 503 response; do not subscribe or enter the loop.
  conn
else
  Phoenix.PubSub.subscribe(MyApp.PubSub, "updates")

  try do
    loop(conn)
  after
    Dstar.Utility.StreamRegistry.release(conn)
    Phoenix.PubSub.unsubscribe(MyApp.PubSub, "updates")
  end
end
```

The second argument is any term that identifies the user or session
(e.g., `user.id`, `{user.id, workspace.id}`). The coordinator keys on
`{scope_key, tab_id}` so different users and different tabs never collide.
It calls `Dstar.start/1` only after a keyed claim succeeds. If that claim
fails, it fails closed with a halted, plain-text 503 conn — never an
undeduplicated stream advertised as deduplicated.

If no usable `tabId` signal is present, `start_stream/2` intentionally falls
back to `Dstar.start/1` so existing streams keep working during rollout. That
unkeyed fallback is different from a failed claim. On every loop exit,
hand-rolled streams should call `Dstar.Utility.StreamRegistry.release(conn)`;
`Dstar.Page` does this automatically before `handle_disconnect/1`.

### What it does

| Scenario | Before | After |
|---|---|---|
| User clicks 5 pages in 3s (same tab) | 5 zombie processes doing wasted PubSub work | 1 active owner; displaced generations are tracked through bounded teardown |
| 3 tabs open | 3 streams (fine) | 3 active owners (unchanged) |
| Concurrent reconnect burst | Claim/register race can leave an untracked stream | Claims are serialized; final claimant is the sole active owner |

### Deduplication vs. auto-reconnect

A replaced stream that ends **cleanly** — the ordinary HTTP/1.1 takeover,
where the loop halts and the response terminates properly — does not
reconnect: the Datastar client only reconnects after a clean end when you
set `retry: "always"` (the default is `"auto"`).

When the takeover ends the stream as a **transport error** instead, the two
features fight: tab A reconnects, replacing tab B, which reconnects,
forever. That happens on HTTP/2 (the stream process is killed outright
rather than halting) and on the registry's kill escalation.

`retryMaxCount` cannot stop that loop. It counts *consecutive failures to
connect*, and the client resets it — and the backoff interval — on every
200, so a loop that connects successfully each pass never accumulates a
budget. Only `0` breaks the cycle:

```heex
<div data-init={connect(opts: "{retryMaxCount: 0}")}>
```

Note this also disables reconnection after ordinary network blips, so
apply it to the deduplicated stream, not indiscriminately.

## SSE Connection Limits & HTTP/2

Browsers allow only **6 concurrent HTTP/1.1 connections per domain**. Each
SSE stream holds one connection open. With rapid navigation, zombie streams
(server hasn't noticed the client left yet) plus the new page's stream can
exhaust the pool — silently stalling **all** requests to that domain: fetches,
asset loads, even page navigation. The page appears to hang with no error.

**HTTP/2 fixes this.** It multiplexes ~100 streams over a single TCP
connection, so SSE streams no longer compete with other requests. Bandit
(Phoenix's default adapter) auto-negotiates HTTP/2 over TLS — no extra
config beyond enabling HTTPS.

### Enable HTTPS in dev

The fast path is the built-in task ([mkcert](https://github.com/FiloSottile/mkcert) required, `brew install mkcert nss` on macOS):

```bash
mix dstar.https
```

It adds a `my-app.test` entry to `/etc/hosts` and generates a
**browser-trusted** certificate via mkcert's local CA — no certificate
warnings, and tools that reject self-signed certs keep working. It asks
before touching anything (`--dry-run` to preview, `mix help dstar.https`
for all options), then prints the `config/dev.exs` snippet to apply.
Steps 3–4 and 6 below still apply.

#### Manual setup (no mkcert)

1. Generate a self-signed certificate:

```bash
mix phx.gen.cert
```

If `mix phx.gen.cert` fails (missing `:public_key` on some OTP versions), use openssl:

```bash
mkdir -p priv/cert
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
  -subj "/CN=localhost" \
  -keyout priv/cert/selfsigned_key.pem \
  -out priv/cert/selfsigned.pem
```

2. Switch `http:` to `https:` in `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  https: [
    ip: {127, 0, 0, 1},
    port: 4000,
    cipher_suite: :strong,
    keyfile: "priv/cert/selfsigned_key.pem",
    certfile: "priv/cert/selfsigned.pem"
  ],
  url: [host: "localhost", scheme: "https"],
  # ...
```

3. If `config/runtime.exs` sets `http: [port: ...]` for dev, change it to `https:` too.

4. Add `priv/cert/` to `.gitignore` — each developer generates their own.

5. Open `https://localhost:4000` and accept the self-signed cert warning once.

6. **Tidewave users:** switching to HTTPS means Tidewave's MCP endpoint
   (plain HTTP) is no longer auto-discovered. Re-add it explicitly:

   ```bash
   claude mcp add tidewave --transport http http://localhost:4000/tidewave/mcp -s local
   ```

### Alternative: terminate TLS at a local proxy (Caddy)

`mix dstar.https` puts HTTPS inside your app. A local reverse proxy puts
it in front instead — your app keeps serving plain HTTP on one port, and
the proxy handles TLS and HTTP/2. The connection limit is browser-side,
so fixing the browser↔proxy hop is enough.

Prefer this when you run several projects locally, or want zero TLS
config in the app.

1. Install and trust Caddy's local CA (once, for all projects):

   ```bash
   brew install caddy
   sudo caddy trust
   ```

2. Create a `Caddyfile` (e.g. `/opt/homebrew/etc/Caddyfile`):

   ```
   my-app.localhost {
       reverse_proxy localhost:4000
   }
   ```

3. Run it: `brew services start caddy`

4. Tell Phoenix its public URL in `config/dev.exs` (keep the `http:` key):

   ```elixir
   url: [host: "my-app.localhost", port: 443, scheme: "https"],
   ```

Open `https://my-app.localhost`. No `/etc/hosts` edits — `*.localhost`
always resolves to loopback. No per-project certs — every future project
is one more 3-line block. Caddy auto-detects `text/event-stream` and
streams SSE unbuffered. And since the app itself stays plain HTTP,
Tidewave's MCP endpoint keeps working with no reconfiguration.

### Verify HTTP/2 is active

Open DevTools → Network tab → right-click column headers → enable
**Protocol**. All requests should show `h2`.

### Recommendation

Use **Stream Deduplication** (previous section) and **HTTP/2** together.
Dedup kills zombie processes server-side so they stop doing wasted DB
queries. HTTP/2 prevents client-side connection exhaustion so the browser
never stalls. Either one helps on its own; both together eliminate the
problem entirely.

## Without Dispatch

You can skip both the page model and the dispatch plug entirely and use plain controller actions:

```elixir
# router.ex
post "/counter/increment", CounterController, :increment
```

```elixir
# controller — Phoenix's Plug.Parsers already populated body_params
def increment(conn, _params) do
  signals = Dstar.read_signals(conn)
  count = (signals["count"] || 0) + 1

  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{count: count})
end
```

```heex
<button data-on:click="@post('/counter/increment')">+1</button>
```

Dispatch gives you convention and a single route. Plain controllers give
you full routing control. Both use the same Dstar functions underneath.

## CSRF Protection Setup

Phoenix expects the CSRF token in the `_csrf_token` body param — and
Datastar can't deliver that: its `_`-prefixed signal keys are
front-end-only and never sent to the backend. So we do a little shimming:
carry the token as a non-prefixed signal, and one plug copies it into
`_csrf_token` before `Plug.CSRFProtection` runs.

### The signal pattern (pages, components, and helper routes alike)

1. Add the plug to your browser pipeline, before `:protect_from_forgery`:

```elixir
plug Dstar.Plugs.RenameCsrfParam
plug :protect_from_forgery
```

2. Expose the token as a **non-prefixed** signal in your root layout:

```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

Because `csrf` is not `_`-prefixed, Datastar includes it in every request.
How it travels depends on the HTTP method:

- **POST / PUT / PATCH** — in the JSON request body, as a top-level param.
- **GET / DELETE** — in the `datastar` URL query parameter (`?datastar={...}`),
  since these methods carry no body.

The plug copies the token into `body_params["_csrf_token"]` from either
channel, where `Plug.CSRFProtection` looks. This one setup covers page
`event()` POSTs, stream `connect()` POSTs, component events, and the verb
helpers — including `Dstar.delete/2,3`, which `:protect_from_forgery` does
check.

When more than one token is present, `RenameCsrfParam` only writes
`body_params["_csrf_token"]` if that key is missing, in this order:
existing body `_csrf_token`, the body `csrf` signal, `csrf` inside the
`datastar` query param, then a last-resort top-level `csrf` param. A
query-string `_csrf_token` is not a source and does not hide a valid body
or `datastar` token. `Plug.CSRFProtection` then checks the body token
first, then the `x-csrf-token` header.

#### CSRF is not optional for cookie-authenticated mutations

Session and auth checks identify the victim; they do not prove who
initiated the request. A hostile same-site origin — or a cross-site origin
under permissive cookie settings — can POST to a predictable event or
dispatch route without reading the SSE response. SameSite cookies and
login checks are defense-in-depth, not CSRF validation.

Cookie-authenticated state-changing Datastar routes need a real CSRF
defense:

- **Default:** `Dstar.Plugs.RenameCsrfParam` then `:protect_from_forgery`.
- **Strongest hygiene:** send `x-csrf-token` from a custom Datastar action.
  `Plug.CSRFProtection` accepts that header directly, and the token never
  lands in a URL.
- **Alternative:** a deliberately implemented Origin / Fetch-Metadata
  policy of comparable strength. Skipping `:protect_from_forgery` without
  one of these is not a supported setup.

#### A note on GET/DELETE and the token in URLs

The token riding on every request is the point of this setup, but on
GET/DELETE that means a per-session credential ends up in the **URL query
string**, which flows into server/proxy access logs and same-origin
`Referer` headers. Validation is unaffected — `Plug.CSRFProtection` still
compares the token cryptographically against the session-derived value —
but if that exposure matters to you:

- Redact the entire `datastar` query value from access/proxy logs and APM
  (the token is nested JSON, not a `_csrf_token` field).
- Set `Referrer-Policy` to `no-referrer` or `origin`. `same-origin` still
  sends the full URL — including the query — on same-origin requests.
- Prefer `x-csrf-token` header transport when you want the token out of
  URLs entirely.

## Lower-level Modules

The `Dstar` module delegates to these. Use them directly when you need more control.

| Module | Functions |
|--------|-----------|
| `Dstar.Page` | behaviour + `use` macro: `mount/2`, `authorize/2`, `render/1`, `handle_event/3`, `handle_connect/2`, `handle_info/2`, `stream_key/1`, `handle_disconnect/1` |
| `Dstar.Page.Plug` | request driver: handles page, event, and stream actions |
| `Dstar.Component` | shared UI with colocated event handlers |
| `Dstar.Router` | `dstar/2` (page routes), `dstar_components/2` (dispatch route) |
| `Dstar.Test` | `sse_events/1`, `patched_signals/1`, `assert_patched_signals/2`, `assert_patched_element/2` |
| `Dstar.SSE` | `start/1`, `check_connection/1`, `send_event/3,4`, `send_event!/3,4`, `format_event/2` |
| `Dstar.Signals` | `fetch/1,2`, `read/1`, `send_error/2`, `patch/2,3`, `patch_raw/2,3`, `nudge/2,3`, `remove_signals/2,3`, `format_patch/1,2`, `format_remove/1,2` |
| `Dstar.Elements` | `patch/2,3`, `remove/2,3`, `append/3,4`, `upsert/2,3`, `format_patch/1,2`, `format_remove/1,2` |
| `Dstar.Actions` | `post/1,2,3`, `get/1,2,3`, `put/1,2,3`, `patch/1,2,3`, `delete/1,2,3`, `on_nudge/2`, `encode_module/1`, `decode_module/1` |
| `Dstar.Scripts` | `execute/2,3`, `redirect/2,3`, `console_log/2,3` |
| `Dstar.Plugs.Dispatch` | Standard Plug for dynamic event routing |
| `Dstar.Plugs.RenameCsrfParam` | Standard Plug for CSRF param compatibility |
| `Dstar.Utility.StreamRegistry` | Opt-in per-tab stream deduplication (see [Stream Deduplication](#stream-deduplication-optional)) |

## Dependencies

Just two:

- [`plug`](https://hex.pm/packages/plug) — Conn manipulation
- [`jason`](https://hex.pm/packages/jason) — JSON encoding/decoding

## License

MIT
