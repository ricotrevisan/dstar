# Error Handling Patterns for Dstar

Practical patterns for handling errors in Dstar SSE handlers, including validation errors, crashes, streaming failures, and client-side display.

---

## 0. Authorization before SSE

On `Dstar.Page`, `handle_event/3` and `handle_connect/2` run *after*
`Dstar.SSE.start/1`. A 401/403 from those callbacks is too late — the
response is already a chunked 200.

Use optional `authorize/2` to reject with a normal status. `mount/2`
does not run on event or stream POSTs; a check only there is not a
boundary. The router pipeline is still the place for session-wide
authentication.

```elixir
def authorize(conn, {:event, "delete:" <> id}) do
  case Items.fetch_for_user(conn.assigns.current_user, id) do
    {:ok, item} -> assign(conn, :item, item)
    :error ->
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

Component handlers call `start/1` themselves. Authorize the record
before that call if you need a normal 401/403. Interpolating an id
into the event name is not an authorization check.

---

## 0.5 Keyed stream claim failures

`Dstar.start_stream/2,3` fails closed for a valid `tabId`: if the opt-in
`Dstar.Utility.StreamRegistry` cannot atomically claim the key, it returns a
halted plain-text 503 conn and does **not** start SSE. A hand-rolled controller
must check `conn.halted` before subscribing or entering its loop. Missing or
invalid `tabId` is different — it is the intentional unkeyed rollout fallback.

`Dstar.Page` handles the branch automatically: `handle_connect/2` and the loop
never run after claim failure. It also releases the exact ownership generation
before `handle_disconnect/1`, so stale escalation cannot kill a reused
keep-alive process.

---

## 1. Rescue in Handlers

Wrap handler logic in explicit error handling. Send error signals back to the client on failure.

### Basic Pattern with Expected Errors

```elixir
def handle_event(conn, "save_user", signals) do
  conn = Dstar.start(conn)
  
  case MyApp.Users.create_user(signals) do
    {:ok, user} ->
      conn
      |> Dstar.patch_signals(%{success: "User created!", errors: %{}, user_id: user.id})
      
    {:error, %Ecto.Changeset{} = changeset} ->
      errors = changeset |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
      conn
      |> Dstar.patch_signals(%{success: false, errors: errors})
  end
end
```

### External API Failures

```elixir
def handle_event(conn, "check_stock", %{"sku" => sku}) do
  conn = Dstar.start(conn)
  
  case ExternalAPI.check_inventory(sku) do
    {:ok, %{available: true, quantity: qty}} ->
      conn
      |> Dstar.patch_signals(%{
        stock_available: true,
        quantity: qty,
        error: nil
      })
      
    {:ok, %{available: false}} ->
      conn
      |> Dstar.patch_signals(%{
        stock_available: false,
        error: "Out of stock"
      })
      
    {:error, :timeout} ->
      conn
      |> Dstar.patch_signals(%{
        stock_available: false,
        error: "Inventory service unavailable. Please try again."
      })
      
    {:error, reason} ->
      Logger.warning("Inventory check failed for #{sku}: #{inspect(reason)}")
      conn
      |> Dstar.patch_signals(%{
        stock_available: false,
        error: "Could not check inventory. Please try again."
      })
  end
end
```

### Important: `start()` is idempotent

If `Dstar.start(conn)` hasn't been called yet, you can call it in the rescue block. If it was already called, you can still send patches—it's just chunked responses over the same connection.

---

## 2. Unexpected Errors (Crash Recovery)

Use `try/rescue` for unexpected exceptions. Log server-side, send generic error to client.

### Pattern: Start Already Called

```elixir
def handle_event(conn, "risky_action", signals) do
  conn = Dstar.start(conn)
  
  try do
    # Risky business logic
    result = perform_complex_operation(signals)
    
    conn
    |> Dstar.patch_signals(%{result: result, error: nil})
  rescue
    e ->
      Logger.error("""
      Handler crashed on risky_action:
        Error: #{Exception.message(e)}
        Signals: #{inspect(signals)}
        Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
      """)
      
      # Connection already started, just send error signals
      conn
      |> Dstar.patch_signals(%{
        error: "Something went wrong. Please try again.",
        result: nil
      })
  end
end
```

### Pattern: Start Not Called Yet

```elixir
defp maybe_start(conn) do
  # Check if SSE has been started (look for resp_body set to :chunked)
  case conn.state do
    :chunked -> conn
    _ -> Dstar.start(conn)
  end
end

def handle_event(conn, "early_crash", signals) do
  try do
    # Might crash before we call start()
    validate_preconditions!(signals)
    
    conn
    |> Dstar.start()
    |> process_and_respond(signals)
  rescue
    e ->
      Logger.error("Handler crashed: #{Exception.message(e)}")
      
      # Safe: call start() if needed, then send error
      conn
      |> maybe_start()
      |> Dstar.patch_signals(%{error: "Something went wrong. Please try again."})
  end
end
```

### Helper for Consistent Error Responses

```elixir
defmodule MyAppWeb.EventHelpers do
  require Logger
  
  @doc """
  Wraps a handler block with error recovery.
  
  Usage:
    def handle_event(conn, "action", signals) do
      with_error_recovery(conn, "action", signals, fn conn ->
        conn
        |> process_action(signals)
      end)
    end
  """
  def with_error_recovery(conn, event_name, signals, handler_fn) do
    try do
      conn
      |> Dstar.start()
      |> handler_fn.()
    rescue
      e ->
        Logger.error("""
        Event handler crashed:
          Event: #{event_name}
          Error: #{Exception.message(e)}
          Signals: #{inspect(signals)}
          Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
        """)
        
        conn
        |> maybe_start()
        |> Dstar.patch_signals(%{
          error: "An unexpected error occurred. Please try again.",
          loading: false
        })
    end
  end
  
  defp maybe_start(conn) do
    case conn.state do
      :chunked -> conn
      _ -> Dstar.start(conn)
    end
  end
end
```

---

## 3. Streaming Loop Error Handling

What happens when a send fails in a streaming loop? How to detect disconnections and clean up resources.

### Basic Pattern with Connection Check

```elixir
defmodule MyAppWeb.StreamHandler do
  require Logger
  
  def handle_event(conn, "subscribe_updates", %{"topic" => topic}) do
    # Subscribe to PubSub
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{subscribed: true, topic: topic})
    |> stream_loop(topic)
  end
  
  defp stream_loop(conn, topic) do
    receive do
      {:update, data} ->
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{data: data, last_update: DateTime.utc_now()})
            stream_loop(conn, topic)
            
          {:error, _conn} ->
            Logger.info("Client disconnected from #{topic}")
            cleanup(topic)
            :ok
        end
        
      {:error, error_data} ->
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{error: error_data})
            stream_loop(conn, topic)
            
          {:error, _conn} ->
            cleanup(topic)
            :ok
        end
        
    after
      60_000 ->
        # Heartbeat: check if connection is still alive
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{heartbeat: DateTime.utc_now()})
            stream_loop(conn, topic)
            
          {:error, _conn} ->
            Logger.info("Connection timeout on #{topic}")
            cleanup(topic)
            :ok
        end
    end
  end
  
  defp cleanup(topic) do
    Phoenix.PubSub.unsubscribe(MyApp.PubSub, topic)
    Logger.debug("Cleaned up subscription to #{topic}")
  end
end
```

### Pattern: Streaming with Graceful Shutdown

```elixir
defmodule MyAppWeb.LiveDataHandler do
  def handle_event(conn, "stream_metrics", signals) do
    # Register this process for cleanup
    ref = Process.monitor(self())
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{streaming: true})
    |> stream_with_cleanup(ref)
  end
  
  defp stream_with_cleanup(conn, ref) do
    try do
      stream_loop(conn)
    catch
      kind, reason ->
        Logger.error("Stream crashed: #{inspect({kind, reason})}")
        cleanup()
    after
      Process.demonitor(ref, [:flush])
      cleanup()
    end
  end
  
  defp stream_loop(conn) do
    receive do
      {:metric, data} ->
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn
            |> Dstar.patch_signals(%{metric: data})
            |> stream_loop()
            
          {:error, _conn} ->
            :ok  # Exit loop, cleanup in `after` block
        end
        
    after
      30_000 ->
        case Dstar.check_connection(conn) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _conn} -> :ok
        end
    end
  end
  
  defp cleanup do
    # Unsubscribe, release resources, etc.
    :ok
  end
end
```

---

## 4. Dispatch-Level Error Handling

`Dstar.Plugs.Dispatch` lets crashes bubble up. Use Phoenix's error handling (ErrorView) or a custom plug for catch-all.

### Custom Error Plug

```elixir
defmodule MyAppWeb.Plugs.DstarErrorHandler do
  import Plug.Conn
  require Logger
  
  def init(opts), do: opts
  
  def call(conn, _opts) do
    try do
      # Continue down the plug pipeline
      conn
    rescue
      e in [Ecto.NoResultsError, Ecto.StaleEntryError] ->
        Logger.warning("Database error in Dstar handler: #{Exception.message(e)}")
        send_dstar_error(conn, "The requested resource was not found or has been modified.")
        
      e ->
        Logger.error("""
        Unhandled error in Dstar pipeline:
          Error: #{Exception.message(e)}
          Path: #{conn.request_path}
          Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
        """)
        send_dstar_error(conn, "An unexpected error occurred. Please refresh and try again.")
    end
  end
  
  defp send_dstar_error(conn, message) do
    conn
    |> maybe_start()
    |> Dstar.patch_signals(%{
      error: message,
      loading: false
    })
    |> halt()
  end
  
  defp maybe_start(conn) do
    case conn.state do
      :chunked -> conn
      _ -> Dstar.start(conn)
    end
  end
end
```

### Usage in Router

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  import Dstar.Plugs.Dispatch
  
  pipeline :dstar_events do
    plug MyAppWeb.Plugs.DstarErrorHandler  # Catch-all error handler
    plug :accepts, ["text/event-stream"]
  end
  
  scope "/dstar" do
    pipe_through :dstar_events
    
    dispatch "/events/:event", MyAppWeb.EventHandler
  end
end
```

### Phoenix ErrorView Pattern

If using Phoenix's default error handling:

```elixir
defmodule MyAppWeb.ErrorView do
  use MyAppWeb, :view
  
  # Special case for SSE/Dstar errors
  def render("500.event-stream", %{conn: conn, reason: reason}) do
    require Logger
    Logger.error("SSE error: #{inspect(reason)}")
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{
      error: "A server error occurred. Please try again.",
      loading: false
    })
  end
  
  # ... other error templates
end
```

---

## 5. Client-Side Error Display Patterns

### Basic Error/Success Display

```heex
<div data-signals:error="''" data-signals:success="''" data-signals:loading="false">
  <!-- Error alert -->
  <div 
    data-show="$error" 
    data-text="$error" 
    class="alert alert-error"
    role="alert">
  </div>
  
  <!-- Success alert -->
  <div 
    data-show="$success" 
    data-text="$success" 
    class="alert alert-success"
    role="alert">
  </div>
  
  <!-- Your form or content -->
  <form data-on-submit="@action@save">
    <!-- Clear errors on interaction -->
    <input 
      type="text" 
      name="name"
      data-on-focus="@action@clear_messages">
    
    <button 
      type="submit" 
      data-bind-disabled="$loading">
      <span data-show="!$loading">Save</span>
      <span data-show="$loading">Saving...</span>
    </button>
  </form>
</div>
```

### Handler: Clear Messages Event

```elixir
def handle_event(conn, "clear_messages", _signals) do
  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{error: nil, success: nil})
end
```

### Auto-Dismiss with execute_script

```heex
<div data-signals:error="''" data-signals:success="''">
  <div 
    data-show="$success" 
    data-text="$success"
    data-on-load="@action@dismiss_success"
    class="alert alert-success">
  </div>
</div>
```

Handler to auto-dismiss after delay:

```elixir
def handle_event(conn, "dismiss_success", _signals) do
  # Send a script that clears success after 3 seconds
  conn
  |> Dstar.start()
  |> Dstar.execute_script("""
    setTimeout(() => {
      window.dsDatastar.signals.success = '';
    }, 3000);
  """)
end
```

Or use fragments with morph-and-remove:

```elixir
def handle_event(conn, "save", signals) do
  conn = Dstar.start(conn)
  
  case MyApp.save(signals) do
    {:ok, _} ->
      success_html = """
      <div 
        id="success-toast" 
        class="alert alert-success"
        data-on-load="@action@remove_toast">
        Saved successfully!
      </div>
      """
      
      conn
      |> Dstar.patch_signals(%{errors: %{}})
      |> Dstar.patch_fragments(%{
        "#toast-container" => success_html
      })
      
    {:error, changeset} ->
      # Handle errors...
  end
end

def handle_event(conn, "remove_toast", _signals) do
  conn
  |> Dstar.start()
  |> Dstar.execute_script("""
    setTimeout(() => {
      document.getElementById('success-toast')?.remove();
    }, 3000);
  """)
end
```

---

## 6. Validation Error Display

Per-field error display pattern using nested error maps from Ecto changesets.

### Handler: Return Nested Error Map

```elixir
def handle_event(conn, "save_profile", signals) do
  conn = Dstar.start(conn)
  
  case MyApp.Users.update_profile(signals) do
    {:ok, user} ->
      conn
      |> Dstar.patch_signals(%{
        success: "Profile updated!",
        errors: %{},
        user: serialize_user(user)
      })
      
    {:error, %Ecto.Changeset{} = changeset} ->
      # Transform errors to nested map: %{field_name: ["error1", "error2"]}
      errors = 
        changeset
        |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
          Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
            opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
          end)
        end)
      
      conn
      |> Dstar.patch_signals(%{
        success: nil,
        errors: errors
      })
  end
end
```

### Template: Per-Field Errors

```heex
<form 
  data-on-submit="@action@save_profile"
  data-signals:errors="{}"
  data-signals:success="''">
  
  <!-- Success message -->
  <div data-show="$success" class="alert alert-success" data-text="$success"></div>
  
  <!-- Name field with error -->
  <div class="form-group">
    <label for="name">Name</label>
    <input 
      id="name"
      type="text" 
      name="name"
      data-model="name"
      data-bind-class-error="$errors.name">
    
    <div 
      data-show="$errors.name" 
      data-text="$errors.name?.[0]"
      class="error-message">
    </div>
  </div>
  
  <!-- Email field with error -->
  <div class="form-group">
    <label for="email">Email</label>
    <input 
      id="email"
      type="email" 
      name="email"
      data-model="email"
      data-bind-class-error="$errors.email">
    
    <div 
      data-show="$errors.email"
      data-text="$errors.email?.[0]"
      class="error-message">
    </div>
  </div>
  
  <!-- Password field with multiple possible errors -->
  <div class="form-group">
    <label for="password">Password</label>
    <input 
      id="password"
      type="password" 
      name="password"
      data-model="password"
      data-bind-class-error="$errors.password">
    
    <!-- Show all password errors if multiple -->
    <template data-for="(error, index) in ($errors.password || [])">
      <div class="error-message" data-text="error"></div>
    </template>
  </div>
  
  <button type="submit">Save Profile</button>
</form>
```

### Alternative: Error Summary

Show all errors in a summary block:

```heex
<form 
  data-on-submit="@action@save_profile"
  data-signals:errors="{}"
  data-signals:success="''">
  
  <!-- Error summary -->
  <div 
    data-show="Object.keys($errors).length > 0"
    class="alert alert-error">
    <h4>Please fix the following errors:</h4>
    <ul>
      <template data-for="(msgs, field) in $errors">
        <template data-for="msg in msgs">
          <li>
            <strong data-text="field"></strong>: 
            <span data-text="msg"></span>
          </li>
        </template>
      </template>
    </ul>
  </div>
  
  <!-- Form fields... -->
</form>
```

### CSS for Error States

```css
.form-group input.error,
.form-group select.error,
.form-group textarea.error {
  border-color: #dc2626;
  background-color: #fef2f2;
}

.error-message {
  color: #dc2626;
  font-size: 0.875rem;
  margin-top: 0.25rem;
}

.alert {
  padding: 1rem;
  border-radius: 0.375rem;
  margin-bottom: 1rem;
}

.alert-error {
  background-color: #fef2f2;
  border: 1px solid #fecaca;
  color: #991b1b;
}

.alert-success {
  background-color: #f0fdf4;
  border: 1px solid #bbf7d0;
  color: #166534;
}
```

---

## Summary

**Key Principles:**

1. **Expected errors** (validation, business logic): Handle explicitly with `case` or pattern matching, send structured error signals
2. **Unexpected errors**: Wrap in `try/rescue`, log server-side, send generic error message to client
3. **Streaming loops**: Use `Dstar.check_connection/1` before every send, clean up resources on disconnect
4. **Dispatch level**: Use a custom plug or Phoenix ErrorView to catch unhandled crashes
5. **Client side**: Initialize error/success signals to empty, show conditionally, clear on next interaction
6. **Validation errors**: Return nested maps matching form field names, display per-field with `data-show`

**Remember:**
- `Dstar.start(conn)` is safe to call multiple times (returns chunked conn as-is)
- After `start()`, all `Dstar.patch_*` functions just send more chunks—no risk of "double response"
- Always log unexpected errors with context (event name, signals, stacktrace)
- For long-running streams, use heartbeats and `check_connection/1` to detect disconnects early
