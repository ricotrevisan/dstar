# Loading State Patterns

Patterns for managing loading states in Dstar applications.

## Overview

Dstar sends SSE events via functions like `Dstar.patch_signals/2` and `Dstar.patch_elements/2`. Datastar on the client manages loading states through signals and attributes. Most loading states require **zero server code** thanks to Datastar's built-in `data-indicator` attribute.

---

## 1. Built-in Indicator (Recommended)

**Best for:** Most use cases. Zero server code required.

Datastar's `data-indicator` attribute automatically manages a boolean signal during SSE request flight:

```heex
<button data-on:click={Dstar.post(Handler, "save")}
        data-indicator="_saving"
        data-attr:disabled="$_saving">
  <span data-show="!$_saving">Save</span>
  <span data-show="$_saving">Saving...</span>
</button>
```

**How it works:**
- The `_` prefix makes the signal client-only (not sent to server)
- Datastar sets `_saving` to `true` when the SSE request starts
- Datastar sets `_saving` to `false` when the SSE response completes
- No server-side code needed!

**Complete example:**

```heex
<div id="user-form">
  <input data-model="name" type="text">
  <button data-on:click={Dstar.post(UserHandler, "save")}
          data-indicator="_saving"
          data-attr:disabled="$_saving">
    <span data-show="!$_saving">Save User</span>
    <span data-show="$_saving">Saving...</span>
  </button>
</div>
```

```elixir
defmodule UserHandler do
  def handle_event(conn, "save", signals) do
    # Do work
    {:ok, user} = save_user(signals["name"])
    
    # Just send the result - loading state auto-clears
    conn
    |> Dstar.start()
    |> Dstar.patch_signals(%{name: user.name, saved: true})
  end
end
```

---

## 2. Manual Loading Signal

**Best for:** Complex flows needing server control over loading state.

Manage loading state explicitly from both client and server:

```heex
<div data-signals:loading="false">
  <button data-on:click="$loading = true; @post('/action')"
          data-attr:disabled="$loading">
    <span data-show="!$loading">Submit</span>
    <span data-show="$loading">Loading...</span>
  </button>
</div>
```

```elixir
def handle_event(conn, "action", signals) do
  result = do_work(signals)
  
  conn
  |> Dstar.start()
  |> Dstar.patch_signals(%{loading: false, result: result})
end
```

**When to clear manually:**
- Multi-step operations (clear at specific steps)
- Streaming responses (clear when stream ends)
- Error states (keep loading=true to show error UI)

---

## 3. Skeleton/Placeholder UI

**Best for:** Content areas that take time to load.

Show skeleton UI while loading, real content when ready:

```heex
<div data-signals:_loading="false">
  <!-- Skeleton -->
  <div data-show="$_loading" class="space-y-2">
    <div class="h-4 bg-gray-200 rounded animate-pulse"></div>
    <div class="h-4 bg-gray-200 rounded animate-pulse w-3/4"></div>
    <div class="h-4 bg-gray-200 rounded animate-pulse w-1/2"></div>
  </div>
  
  <!-- Real content -->
  <div data-show="!$_loading" id="content">
    <!-- Patched by server -->
  </div>
  
  <button data-on:click={Dstar.post(ContentHandler, "load")}
          data-indicator="_loading">
    Load Content
  </button>
</div>
```

```elixir
def handle_event(conn, "load", _signals) do
  content = load_expensive_content()
  
  conn
  |> Dstar.start()
  |> Dstar.patch_elements([
    %{
      selector: "#content",
      merge_mode: :morph,
      html: render_content(content)
    }
  ])
end
```

---

## 4. Disabled Form During Submission

**Best for:** Preventing double-submission and race conditions.

Disable all form inputs while submitting:

```heex
<div data-signals:_submitting="false">
  <input data-model="name" 
         data-attr:disabled="$_submitting"
         type="text">
  
  <input data-model="email" 
         data-attr:disabled="$_submitting"
         type="email">
  
  <textarea data-model="message"
            data-attr:disabled="$_submitting">
  </textarea>
  
  <button data-on:click={Dstar.post(FormHandler, "submit")}
          data-indicator="_submitting"
          data-attr:disabled="$_submitting">
    <span data-show="!$_submitting">Submit</span>
    <span data-show="$_submitting">
      <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" 
                stroke="currentColor" stroke-width="4" fill="none"/>
        <path class="opacity-75" fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
      </svg>
      Submitting...
    </span>
  </button>
</div>
```

```elixir
def handle_event(conn, "submit", signals) do
  case submit_form(signals) do
    {:ok, result} ->
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{success: true, result: result})
    
    {:error, errors} ->
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{errors: errors})
  end
end
```

---

## 5. CSS-Based Loading States

**Best for:** Visual feedback without DOM changes.

Use `data-class` to apply loading styles:

```heex
<button data-on:click={Dstar.post(Handler, "action")}
        data-indicator="_busy"
        data-class:opacity-50="$_busy"
        data-class:cursor-wait="$_busy"
        data-class:pointer-events-none="$_busy"
        data-attr:disabled="$_busy">
  Do Thing
</button>
```

**With list items:**

```heex
<div data-signals:_deleting="false">
  <div :for={item <- @items} data-class:opacity-30={"$_deleting == #{Dstar.js_value(item.id)}"}>
    {item.name}
    <button data-on:click={"$_deleting = #{Dstar.js_value(item.id)}; #{Dstar.post(ItemHandler, "delete:#{item.id}")}"}
            data-indicator="_deleting">
      Delete
    </button>
  </div>
</div>
```

---

## 6. Global Loading Bar

**Best for:** Page-level loading indicator for navigation or background tasks.

A fixed loading bar at the top of the page:

```heex
<!-- In your layout -->
<div data-signals:_globalLoading="false"
     data-show="$_globalLoading"
     class="fixed top-0 left-0 right-0 h-1 bg-blue-500 z-50">
  <div class="h-full bg-blue-600 animate-pulse"></div>
</div>

<!-- Any action can trigger it -->
<button data-on:click="$_globalLoading = true; @post('/heavy-operation')"
        data-indicator="_globalLoading">
  Start Heavy Task
</button>
```

**Indeterminate progress bar:**

```heex
<div data-signals:_loading="false"
     data-show="$_loading"
     class="fixed top-0 left-0 right-0 h-1 bg-gray-200 z-50">
  <div class="h-full bg-blue-500 w-full animate-[progress_2s_ease-in-out_infinite]">
  </div>
</div>

<style>
  @keyframes progress {
    0% { transform: translateX(-100%); }
    100% { transform: translateX(100%); }
  }
</style>
```

---

## 7. Multiple Concurrent Operations

**Best for:** When users can trigger multiple independent operations.

Use unique indicator names for each operation:

```heex
<div>
  <button data-on:click={Dstar.post(Handler, "save")}
          data-indicator="_saving"
          data-attr:disabled="$_saving">
    <span data-show="!$_saving">Save</span>
    <span data-show="$_saving">Saving...</span>
  </button>
  
  <button data-on:click={Dstar.post(Handler, "publish")}
          data-indicator="_publishing"
          data-attr:disabled="$_publishing">
    <span data-show="!$_publishing">Publish</span>
    <span data-show="$_publishing">Publishing...</span>
  </button>
  
  <button data-on:click={Dstar.post(Handler, "archive")}
          data-indicator="_archiving"
          data-attr:disabled="$_archiving">
    <span data-show="!$_archiving">Archive</span>
    <span data-show="$_archiving">Archiving...</span>
  </button>
</div>
```

Each button has its own loading state that doesn't interfere with others.

---

## 8. Optimistic Updates with Rollback

**Best for:** Fast perceived performance with safe rollback.

Show immediate feedback, rollback on error:

```heex
<div data-signals:items="[]" data-signals:_updating="null">
  <div :for={item <- @items} data-class:opacity-50={"$_updating == #{Dstar.js_value(item.id)}"}>
    <input type="checkbox"
           checked={item.completed}
           data-on:click={"$_updating = #{Dstar.js_value(item.id)}; $items = $items.map(i => i.id == #{Dstar.js_value(item.id)} ? {...i, completed: !i.completed} : i); #{Dstar.post(ItemHandler, "toggle:#{item.id}")}"}
           data-indicator="_updating">
    {item.name}
  </div>
</div>
```

```elixir
def handle_event(conn, "toggle", %{"id" => id}) do
  case toggle_item(id) do
    {:ok, item} ->
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{
        items: get_all_items(),  # Server state is source of truth
        _updating: nil
      })
    
    {:error, _reason} ->
      conn
      |> Dstar.start()
      |> Dstar.patch_signals(%{
        items: get_all_items(),  # Rollback
        _updating: nil,
        error: "Failed to update item"
      })
  end
end
```

---

## Best Practices

1. **Prefer `data-indicator`** - Use built-in indicators for 95% of cases
2. **Use `_` prefix** - Client-only signals don't round-trip to server
3. **Disable during load** - Always disable interactive elements to prevent double-submission
4. **Clear on error** - Make sure loading states clear even when operations fail
5. **Keep it simple** - Most loading states need zero server code
6. **Visual feedback** - Always show something changed when user acts
7. **Unique names** - Use specific indicator names for concurrent operations

---

## Common Pitfalls

❌ **Don't forget to disable buttons:**
```heex
<!-- Missing data-attr:disabled -->
<button data-on:click={Dstar.post(Handler, "save")}
        data-indicator="_saving">
  Save
</button>
```

✅ **Do disable buttons:**
```heex
<button data-on:click={Dstar.post(Handler, "save")}
        data-indicator="_saving"
        data-attr:disabled="$_saving">
  Save
</button>
```

❌ **Don't manually manage what indicators handle:**
```heex
<button data-on:click="$_loading = true; @post('/action')"
        data-indicator="_loading">
  <!-- Redundant! indicator already manages _loading -->
</button>
```

✅ **Do use indicator alone:**
```heex
<button data-on:click={Dstar.post(Handler, "action")}
        data-indicator="_loading">
  <!-- indicator handles everything -->
</button>
```

❌ **Don't use server-side signals for indicators:**
```heex
<!-- Missing _ prefix - will round-trip unnecessarily -->
<button data-indicator="loading">Save</button>
```

✅ **Do use client-only signals:**
```heex
<button data-indicator="_loading">Save</button>
```
