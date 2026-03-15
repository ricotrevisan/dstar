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
