# Dstar API Patterns

Copy-pasteable code examples for common Dstar use cases.

## Stateless Counter

**Controller:**
```elixir
defmodule MyAppWeb.CounterController do
  use MyAppWeb, :controller
  
  def increment(conn, _params) do
    signals = Dstar.read_signals(conn)
    count = (signals["count"] || 0) + 1
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
  
  def decrement(conn, _params) do
    signals = Dstar.read_signals(conn)
    count = max((signals["count"] || 0) - 1, 0)
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{count: count})
  end
end
```

**Template:**
```heex
<div data-signals:count="0">
  <p>Count: <span data-text="$count"></span></p>
  <button data-on:click="@post('/counter/increment')">+</button>
  <button data-on:click="@post('/counter/decrement')">-</button>
</div>
```

## DOM Patching with Server-Rendered HTML

**Controller:**
```elixir
defmodule MyAppWeb.TodoController do
  use MyAppWeb, :controller
  
  def add_todo(conn, _params) do
    signals = Dstar.read_signals(conn)
    
    todo = %{
      id: UUID.uuid4(),
      text: signals["new_todo"],
      done: false
    }
    
    # Persist
    {:ok, _} = Todos.create_todo(todo)
    
    # Render partial
    html = Phoenix.Template.render_to_string(
      MyAppWeb.TodoView,
      "todo_item.html",
      todo: todo
    )
    
    conn
    |> Dstar.start()
    |> Dstar.patch_elements(html, selector: "#todo-list", mode: :append)
    |> Dstar.patch_signals(%{new_todo: ""})
  end
  
  def delete_todo(conn, _params) do
    signals = Dstar.read_signals(conn)
    todo_id = signals["deleting_id"]
    
    {:ok, _} = Todos.delete_todo(todo_id)
    
    conn
    |> Dstar.start()
    |> Dstar.remove_elements("#todo-#{todo_id}")
  end
end
```

**Partial (todo_item.html.heex):**
```heex
<li id={"todo-#{@todo.id}"} class="todo-item">
  <span><%= @todo.text %></span>
  <button data-signals:deleting_id={"'#{@todo.id}'"}
          data-on:click="@delete('/todos/delete')">
    Delete
  </button>
</li>
```

## Real-time Streaming

**Controller:**
```elixir
defmodule MyAppWeb.FeedController do
  use MyAppWeb, :controller
  
  def live_feed(conn, _params) do
    user_id = conn.assigns.current_user.id
    
    # Subscribe BEFORE start
    Phoenix.PubSub.subscribe(MyApp.PubSub, "feed:#{user_id}")
    
    # Open SSE connection
    conn = Dstar.start(conn)
    
    # Enter receive loop
    stream_loop(conn)
  end
  
  defp stream_loop(conn) do
    receive do
      {:new_message, message} ->
        conn = Dstar.patch_signals(conn, %{
          latest_message: message.text,
          message_count: message.total_count
        })
        stream_loop(conn)
      
      {:notification, notification} ->
        html = Phoenix.Template.render_to_string(
          MyAppWeb.NotificationView,
          "notification.html",
          notification: notification
        )
        
        conn = Dstar.patch_elements(
          conn,
          html,
          selector: "#notifications",
          mode: :prepend
        )
        stream_loop(conn)
    end
  end
end
```

**Template:**
```heex
<div data-init="@post('/feed/live', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/feed/live', {retryMaxCount: Infinity})"
     data-signals:latest_message="''"
     data-signals:message_count="0">
  
  <div id="notifications" class="notifications"></div>
  
  <div class="status">
    <p data-text="$latest_message"></p>
    <span data-text="`${$message_count} messages`"></span>
  </div>
</div>
```

## Dispatch Handler Module

**Router:**
```elixir
post "/ds/:module/:event", Dstar.Plugs.Dispatch,
  modules: [MyApp.Handlers.SearchHandler]
```

**Handler:**
```elixir
defmodule MyApp.Handlers.SearchHandler do
  @moduledoc """
  Handles search events via Dstar.Plugs.Dispatch
  """
  
  def handle_event(conn, "search", signals) do
    query = signals["query"] || ""
    
    results = if String.length(query) >= 2 do
      MyApp.Search.search(query, limit: 10)
    else
      []
    end
    
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{
      results: results,
      loading: false
    })
  end
  
  def handle_event(conn, "clear", _signals) do
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{
      query: "",
      results: [],
      loading: false
    })
  end
end
```

**Template:**
```heex
<div data-signals:query="''"
     data-signals:results="[]"
     data-signals:loading="false">
  
  <input type="search"
         data-model="query"
         data-on:input={Dstar.post(SearchHandler, "search")}
         placeholder="Search...">
  
  <button data-on:click={Dstar.post(SearchHandler, "clear")}>
    Clear
  </button>
  
  <div data-show="$loading">Searching...</div>
  
  <ul>
    <template data-for="result in $results">
      <li data-text="result.title"></li>
    </template>
  </ul>
</div>
```

## CSRF Setup

### Header-based (Recommended)

**Root Layout (root.html.heex):**
```heex
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="csrf-token" content={get_csrf_token()} />
  <script src="/assets/datastar.js"></script>
</head>
<body data-signals:_csrf-token={"'#{get_csrf_token()}'"}>
  <%= @inner_content %>
</body>
</html>
```

Dstar's verb helpers (`post/2,3`, `get/2,3`, `put/2,3`, `patch/2,3`, `delete/2,3`) automatically include `_csrf-token` in headers.

### Form-compatible

**Router (plug goes before `:protect_from_forgery`):**
```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_flash
  plug Dstar.Plugs.RenameCsrfParam  # safely no-ops when param isn't present
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end
```

**Layout:**
```heex
<body data-signals:csrf={"'#{get_csrf_token()}'"}>
```

## Multiple Patches in One Response

```elixir
def complex_update(conn, _params) do
  signals = Dstar.read_signals(conn)
  
  # Process data
  result = process_data(signals["input"])
  
  # Render HTML fragment
  html = Phoenix.Template.render_to_string(
    MyAppWeb.ResultView,
    "result.html",
    result: result
  )
  
  # Chain multiple updates
  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{
    processing: false,
    last_update: DateTime.utc_now() |> to_string(),
    result_count: length(result.items)
  })
  |> Dstar.patch_elements(html, selector: "#results", mode: :inner)
  |> Dstar.console_log("Update complete", level: :info)
end
```

## Form with Validation

**Controller:**
```elixir
def submit_form(conn, _params) do
  signals = Dstar.read_signals(conn)
  
  changeset = User.changeset(%User{}, %{
    name: signals["name"],
    email: signals["email"]
  })
  
  case Repo.insert(changeset) do
    {:ok, user} ->
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{
        success: "User created!",
        errors: %{},
        name: "",
        email: ""
      })
    
    {:error, %Ecto.Changeset{} = changeset} ->
      errors = changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{
        errors: errors,
        success: ""
      })
  end
end
```

**Template:**
```heex
<div data-signals:name="''"
     data-signals:email="''"
     data-signals:errors="{}"
     data-signals:success="''">
  
  <div data-show="$success" data-text="$success" class="success"></div>
  
  <input type="text" data-model="name" placeholder="Name">
  <div data-show="$errors.name" data-text="$errors.name" class="error"></div>
  
  <input type="email" data-model="email" placeholder="Email">
  <div data-show="$errors.email" data-text="$errors.email" class="error"></div>
  
  <button data-on:click="@post('/users/create')">
    Submit
  </button>
</div>
```

## Streaming with Disconnect Detection

**Controller:**
```elixir
defmodule MyAppWeb.MetricsController do
  use MyAppWeb, :controller
  
  def live_metrics(conn, _params) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "metrics:live")
    
    conn = Dstar.start(conn)
    stream_loop(conn)
  end
  
  defp stream_loop(conn) do
    receive do
      {:metric_update, metrics} ->
        # Check connection before sending
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            conn = Dstar.patch_signals(conn, %{
              cpu: metrics.cpu,
              memory: metrics.memory,
              requests: metrics.requests
            })
            stream_loop(conn)
          
          {:error, _conn} ->
            # Client disconnected, clean up and exit
            Phoenix.PubSub.unsubscribe(MyApp.PubSub, "metrics:live")
            :ok
        end
    after
      30_000 ->
        # Periodic health check (optional)
        case Dstar.check_connection(conn) do
          {:ok, conn} ->
            stream_loop(conn)
          
          {:error, _conn} ->
            Phoenix.PubSub.unsubscribe(MyApp.PubSub, "metrics:live")
            :ok
        end
    end
  end
end
```

**Template:**
```heex
<div data-init="@post('/metrics/live', {retryMaxCount: Infinity})"
     data-on:online__window="@post('/metrics/live', {retryMaxCount: Infinity})"
     data-signals:cpu="0"
     data-signals:memory="0"
     data-signals:requests="0">
  
  <div class="metric">
    CPU: <span data-text="`${$cpu}%`"></span>
  </div>
  <div class="metric">
    Memory: <span data-text="`${$memory}MB`"></span>
  </div>
  <div class="metric">
    Requests/sec: <span data-text="$requests"></span>
  </div>
</div>
```

## Signal Removal

**Controller:**
```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller
  
  def logout(conn, _params) do
    # Clear session server-side
    conn = clear_session(conn)
    
    # Clear all user-related signals on client
    conn
    |> Dstar.start()
    |> Dstar.remove_signals([
      "user.id",
      "user.email",
      "user.name",
      "user.profile.avatar",
      "user.profile.theme",
      "user.preferences"
    ])
    |> Dstar.redirect("/login")
  end
  
  def delete_profile_section(conn, _params) do
    signals = Dstar.read_signals(conn)
    section = signals["deleting_section"]
    
    # Delete from database
    {:ok, _} = Users.delete_profile_section(
      conn.assigns.current_user,
      section
    )
    
    # Remove nested signal path
    conn
    |> Dstar.start()
    |> Dstar.remove_signals("user.profile.#{section}")
    |> Dstar.console_log("Profile section '#{section}' deleted")
  end
end
```

**Template:**
```heex
<div data-signals:user="{id: 123, email: 'user@example.com', profile: {avatar: '/img/avatar.jpg', theme: 'dark'}}">
  <div class="user-info">
    <img data-attr:src="$user.profile.avatar">
    <span data-text="$user.email"></span>
  </div>
  
  <button data-on:click="@post('/auth/logout')">
    Logout
  </button>
  
  <button data-signals:deleting_section="'avatar'"
          data-on:click={Dstar.post(AuthController, "delete_profile_section")}>
    Remove Avatar
  </button>
</div>
```

## SVG / MathML Patching

**Controller:**
```elixir
defmodule MyAppWeb.ChartController do
  use MyAppWeb, :controller
  
  def update_chart(conn, _params) do
    signals = Dstar.read_signals(conn)
    dataset = signals["selected_dataset"] || "sales"
    
    # Fetch data
    data = Analytics.get_chart_data(dataset)
    
    # Render SVG chart
    svg = render_svg_chart(data)
    
    conn
    |> Dstar.start()
    |> Dstar.patch_elements(
      svg,
      selector: "#chart-container",
      mode: :inner,
      namespace: :svg
    )
    |> Dstar.patch_signals(%{last_updated: DateTime.utc_now()})
  end
  
  def update_formula(conn, _params) do
    signals = Dstar.read_signals(conn)
    formula_id = signals["formula_id"]
    
    # Generate MathML
    mathml = """
    <math xmlns="http://www.w3.org/1998/Math/MathML">
      <mrow>
        <msup>
          <mi>x</mi>
          <mn>2</mn>
        </msup>
        <mo>+</mo>
        <msup>
          <mi>y</mi>
          <mn>2</mn>
        </msup>
        <mo>=</mo>
        <msup>
          <mi>z</mi>
          <mn>2</mn>
        </msup>
      </mrow>
    </math>
    """
    
    conn
    |> Dstar.start()
    |> Dstar.patch_elements(
      mathml,
      selector: "#formula-#{formula_id}",
      namespace: :mathml
    )
  end
  
  defp render_svg_chart(data) do
    """
    <svg viewBox="0 0 400 300" xmlns="http://www.w3.org/2000/svg">
      <rect x="50" y="#{250 - data.value * 2}" width="40" height="#{data.value * 2}" fill="#4CAF50"/>
      <text x="70" y="280" text-anchor="middle">#{data.label}</text>
    </svg>
    """
  end
end
```

**Template:**
```heex
<div data-signals:selected_dataset="'sales'"
     data-signals:last_updated="null">
  
  <select data-model="selected_dataset"
          data-on:change={Dstar.post(ChartController, "update_chart")}>
    <option value="sales">Sales</option>
    <option value="revenue">Revenue</option>
    <option value="users">Users</option>
  </select>
  
  <div id="chart-container">
    <!-- SVG chart injected here -->
  </div>
  
  <div id="formula-1">
    <!-- MathML formula injected here -->
  </div>
  
  <button data-signals:formula_id="'1'"
          data-on:click={Dstar.post(ChartController, "update_formula")}>
    Show Formula
  </button>
</div>
```
