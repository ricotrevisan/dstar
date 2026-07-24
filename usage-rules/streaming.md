# Dstar Streaming Usage

## Real-time Streaming Pattern

Dstar uses **long-lived SSE connections** with Phoenix PubSub for real-time updates.

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
