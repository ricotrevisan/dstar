# Dstar Streaming Usage

## Real-time Streaming Pattern

Dstar uses **long-lived SSE connections** with Phoenix PubSub for real-time updates.

On `Dstar.Page`, optional `authorize/2` runs **before** `handle_connect/2`
and before any `stream_key/1` registration. Reject there with a normal
401/403; `mount/2` does not run on the stream POST. The router pipeline
is still the place for session-wide authentication.

## Basic Pattern

```elixir
def stream(conn, _params) do
  # 1. Subscribe BEFORE starting SSE
  Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")
  
  # 2. Open SSE connection
  conn = Dstar.start(conn)
  
  # 3. Enter receive loop
  loop(conn)
end

defp loop(conn) do
  receive do
    {:update, data} ->
      conn = Dstar.patch_signals(conn, %{data: data})
      loop(conn)
    
    {:dom_update, html} ->
      conn = Dstar.patch_elements(conn, html, selector: "#target")
      loop(conn)
  end
end
```

## Optional per-tab deduplication

Add `Dstar.Utility.StreamRegistry` to the supervision tree and a
`data-signals:tab-id` value backed by `sessionStorage`. Then a hand-rolled loop
can claim before subscribing:

```elixir
def stream(conn, _params) do
  conn = Dstar.start_stream(conn, conn.assigns.current_user.id)

  if conn.halted do
    # Valid tabId, but the atomic claim failed: ordinary non-SSE 503.
    conn
  else
    Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")

    try do
      loop(conn)
    after
      Dstar.Utility.StreamRegistry.release(conn)
      Phoenix.PubSub.unsubscribe(MyApp.PubSub, "topic")
    end
  end
end
```

A missing/invalid `tabId` intentionally starts an unkeyed stream for rollout
compatibility. A valid keyed request is different: claims are linearizable and
fail closed, so `Dstar.start/1` is never called after claim failure. Concurrent
contenders can succeed in coordinator order and then be replaced; the final
claimant is the sole active owner, while displaced generations remain tracked
through graceful release or bounded kill escalation.

`Dstar.Page` owns this flow when `stream_key/1` is defined. It returns claim
failure before `handle_connect/2`, matches generation-tagged replacements so a
stale keep-alive mailbox message cannot stop the next stream, and releases the
exact generation before `handle_disconnect/1`.

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
- Subscribe after `Dstar.start()` (messages lost)
- Forget to loop (connection closes immediately)
- Use `Task.async` or `spawn` for the loop (defeats streaming purpose)
- Store state in GenServers keyed by connection (no process identity)

**✅ Do:**
- Subscribe → start → loop (exact order)
- Tail-call loop/1 for memory efficiency
- Use PubSub for broadcasting to all connections
- Return updated conn from each patch in loop
