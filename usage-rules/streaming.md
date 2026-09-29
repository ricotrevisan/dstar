# Dstar Streaming Usage

## Real-time Streaming Pattern

Dstar uses **long-lived SSE connections** with Phoenix PubSub for real-time updates.

On `Dstar.Page`, optional `authorize/2` runs **before** `handle_connect/2`
and before any `stream_key/1` registration. Reject there with a normal
401/403; `mount/2` does not run on the stream POST. The router pipeline
is still the place for session-wide authentication.

## Basic Pattern

In a plain controller, use `Dstar.Stream`: `open/2` starts SSE, `run/2` owns
the receive loop.

```elixir
def stream(conn, _params) do
  case Dstar.Stream.open(conn) do
    {:ok, conn} ->
      Dstar.Stream.run(conn,
        # 1. Subscribe in :connect (runs once, after SSE starts)
        connect: fn conn ->
          Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")
          conn
        end,
        # 2. Handle each message; return conn, or {:halt, conn} to end
        info: fn
          {:update, data}, conn -> Dstar.patch_signals(conn, %{data: data})
          {:dom_update, html}, conn -> Dstar.patch_elements(conn, html, selector: "#target")
        end,
        # 3. Clean up once, when the client is gone or :info halts
        disconnect: fn _conn -> Phoenix.PubSub.unsubscribe(MyApp.PubSub, "topic") end
      )

    {:error, conn} ->
      # Ordinary halted HTTP response (400/413/503), never SSE
      conn
  end
end
```

`run/2` probes idle connections every `:idle_check` ms (default 30_000) and
skips adapter plumbing — including Bandit's HTTP/2 flow-control messages,
which a catch-all `receive` would swallow and stall the stream.

A loop that must own its `receive` can still use `Dstar.start/1` and recurse
by hand. That is the lower-level path: adapter and takeover messages are then
the loop's responsibility, which is why `Dstar.Stream.run/2` exists.

## Optional per-tab deduplication

Add `Dstar.Utility.StreamRegistry` to the supervision tree and a
`data-signals:tab-id` value backed by `sessionStorage`. Then pass a `key:`
so the claim happens before SSE starts:

```elixir
case Dstar.Stream.open(conn, key: conn.assigns.current_user.id) do
  {:ok, conn} -> Dstar.Stream.run(conn, connect: &subscribe/1, info: &handle/2)
  # Valid tabId, but the atomic claim failed: ordinary non-SSE 503.
  {:error, conn} -> conn
end
```

A missing/invalid `tabId` intentionally starts an unkeyed stream for rollout
compatibility. A valid keyed request is different: claims are linearizable and
fail closed, so SSE never starts after claim failure. Concurrent
contenders can succeed in coordinator order and then be replaced; the final
claimant is the sole active owner, while displaced generations remain tracked
through graceful release or bounded kill escalation.

`Dstar.Stream.run/2` matches generation-tagged replacements so a stale
keep-alive mailbox message cannot stop the next stream, releases the exact
generation before `:replaced`/`:disconnect`, and releases again if a callback
raises. `Dstar.Page` runs on it when `stream_key/1` is defined, returning
claim failure before `handle_connect/2` and releasing before
`handle_disconnect/1`.

Lower-level alternative for a loop that owns its `receive`:
`Dstar.start_stream/2,3`, check `conn.halted` before subscribing, and call
`Dstar.Utility.StreamRegistry.release(conn)` in an `after` block.

## Client-side Setup

**Initialize stream on mount:**
```heex
<div data-init="@post('/stream', {retryMaxCount: Infinity})">
```

**Auto-reconnect on network restore:**
```heex
<div data-on:online__window="@post('/stream', {retryMaxCount: Infinity})">
```

**Both (recommended):**
```heex
<div data-init="@post('/stream', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/stream', {retryMaxCount: Infinity})">
  <span data-text="$data"></span>
</div>
```

**`retryMaxCount` cannot bound a reconnect loop.** It counts consecutive
failures to *connect*, and the client resets it — plus the backoff
interval — on every 200, so a loop that reconnects successfully each pass
never accumulates a budget. Only `retryMaxCount: 0` stops one.

This matters when a stream ends as a **transport error** (HTTP/2 takeover,
a kill, a crash) or when you set `retry: "always"`. A cleanly ended stream
does not reconnect at all under the default `retry: "auto"` — including
the ordinary HTTP/1.1 `StreamRegistry` takeover, where the loop halts and
the response terminates properly.

Where takeovers do end as errors, cap the deduplicated stream with
`retryMaxCount: 0`, or the two features fight: each tab's reconnect
replaces the other's stream, and round it goes.

## No Keepalive Needed

SSE connections stay open automatically. No need for manual ping/pong.

## Common Mistakes

**❌ Don't:**
- Subscribe before `Dstar.Stream.open/2` succeeds (a refused claim leaks the subscription)
- Forget `Dstar.Stream.run/2` or a loop (connection closes immediately)
- Use `Task.async` or `spawn` for the loop (defeats streaming purpose)
- Store state in GenServers keyed by connection (no process identity)

**✅ Do:**
- Open → subscribe in `:connect` → handle in `:info`
- Use PubSub for broadcasting to all connections
- Return the updated conn from each `:info` call (or loop iteration)
