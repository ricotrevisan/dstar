# Datastar Attributes Cheat Sheet

> **Version:** Datastar v1.0.0  
> **Audience:** Intermediate Elixir Phoenix developers using Dstar library  
> **Purpose:** Quick reference for all client-side Datastar attributes with practical HEEx/Dstar examples

---

## 1. Signals

Declare reactive state that syncs between client and server.

### Basic Signals
```heex
<!-- Server-synced signal -->
<div data-signals:count="0">
  <!-- Value is a JS expression -->
</div>

<!-- Client-only signal (underscore prefix, not sent to server) -->
<div data-signals:_csrf_token="'abc123'">
  <!-- Common for headers, UI state -->
</div>
```

### Value Quoting Rules
```heex
<!-- Numbers: unquoted -->
<div data-signals:count="42">

<!-- Strings: need JS quotes -->
<div data-signals:name="'John Doe'">

<!-- Booleans: unquoted -->
<div data-signals:active="true">

<!-- Arrays: JS array literal -->
<div data-signals:items="[1, 2, 3]">

<!-- Objects: JS object literal -->
<div data-signals:user="{id: 1, name: 'Alice'}">
```

### Dynamic Values with HEEx
```heex
<!-- Inject Elixir values into JS expressions -->
<div data-signals:user_id={"'#{@user.id}'"}>
<div data-signals:count={"#{@initial_count}"}>
<div data-signals:config={Jason.encode!(@config)}>
```

### Nested Signals
```heex
<div data-signals:user="{name: 'John', age: 30, settings: {theme: 'dark'}}">
  <!-- Access with: $user.name, $user.settings.theme -->
</div>
```

---

## 2. Text & Content

Bind text content to signals reactively.

```heex
<!-- Simple binding -->
<span data-text="$count"></span>

<!-- Template literals -->
<span data-text="`Count: ${$count}`"></span>
<span data-text="`Hello, ${$user.name}!`"></span>

<!-- Ternary expressions -->
<span data-text="$active ? 'Active' : 'Inactive'"></span>
<span data-text="$count > 0 ? `${$count} items` : 'No items'"></span>
```

---

## 3. Visibility

Toggle element visibility based on conditions.

```heex
<!-- Show/hide with display: none -->
<div data-show="$isVisible">
  Content shown when $isVisible is truthy
</div>

<div data-show="$count > 0">
  Only visible when count is positive
</div>

<div data-show="!$loading">
  Hidden during loading
</div>
```

---

## 4. CSS Classes

Toggle CSS classes based on conditions.

```heex
<!-- Single class toggle -->
<button data-class:active="$isActive">
  Click me
</button>

<!-- Multiple classes (use multiple attributes) -->
<div 
  data-class:bg-blue-500="$type === 'primary'"
  data-class:bg-gray-500="$type === 'secondary'"
  data-class:opacity-50="$loading">
  Button with dynamic classes
</div>

<!-- Common pattern: loading states -->
<button data-class:cursor-not-allowed="$_loading">
  Submit
</button>
```

---

## 5. Attributes

Bind any HTML attribute dynamically.

```heex
<!-- Dynamic href -->
<a data-attr:href="$profileUrl">Profile</a>

<!-- Disable button while loading -->
<button data-attr:disabled="$_loading">
  Submit
</button>

<!-- Dynamic image source -->
<img data-attr:src="$imageUrl" alt="Dynamic image">

<!-- Dynamic class string (different from data-class:) -->
<div data-attr:class="$loading ? 'opacity-50 cursor-wait' : ''">
  Content
</div>

<!-- Dynamic inline style -->
<div data-attr:style="`width: ${$percentage}%`">
  Progress bar
</div>

<!-- Dynamic aria attributes -->
<button data-attr:aria-expanded="$isOpen">
  Toggle
</button>
```

---

## 6. Two-Way Binding

Automatic synchronization between form inputs and signals.

```heex
<!-- Text input -->
<input type="text" data-model="name" placeholder="Enter name">

<!-- Number input -->
<input type="number" data-model="quantity">

<!-- Email input -->
<input type="email" data-model="email">

<!-- Textarea -->
<textarea data-model="message"></textarea>

<!-- Checkbox -->
<input type="checkbox" data-model="agree">

<!-- Radio buttons (same signal name) -->
<input type="radio" name="color" value="red" data-model="color">
<input type="radio" name="color" value="blue" data-model="color">

<!-- Select dropdown -->
<select data-model="country">
  <option value="us">United States</option>
  <option value="ca">Canada</option>
</select>
```

---

## 7. Event Handling

Respond to DOM events.

```heex
<!-- Click handler -->
<button data-on:click="$count++">
  Increment
</button>

<!-- Submit handler with Dstar helper -->
<form data-on:submit={Dstar.post(MyApp.SearchHandler, "search")}>
  <input type="text" data-model="query">
  <button type="submit">Search</button>
</form>

<!-- Input event -->
<input data-on:input="$query = $el.value">

<!-- Keydown event -->
<input data-on:keydown="console.log('Key pressed')">

<!-- Change event -->
<select data-on:change={Dstar.post(MyApp.FilterHandler, "update")}>
  <option>Option 1</option>
</select>

<!-- Window events -->
<div data-on:load__window={Dstar.get(MyApp.AppHandler, "init")}>

<!-- Network events -->
<div data-on:online__window="console.log('Back online!')">
```

---

## 8. Event Modifiers

**CRITICAL:** Modifiers append with double underscore `__`.

### Debounce
```heex
<!-- Debounce: wait 500ms after last event -->
<input 
  data-model="search"
  data-on:input__debounce_500ms={Dstar.post(MyApp.SearchHandler, "search")}>
```

### Throttle
```heex
<!-- Throttle: max once per 1000ms -->
<input 
  data-on:input__throttle_1000ms="console.log('Throttled:', $el.value)">
```

### Common Modifiers
```heex
<!-- Fire once only -->
<button data-on:click__once="alert('First click only')">

<!-- Prevent default (e.g., form submission) -->
<form data-on:submit__prevent={Dstar.post(MyApp.FormHandler, "submit")}>

<!-- Stop propagation -->
<div data-on:click__stop="console.log('Stopped')">

<!-- Capture phase -->
<div data-on:click__capture="console.log('Captured')">

<!-- Passive listener (better scroll performance) -->
<div data-on:scroll__passive="console.log('Scrolling')">

<!-- Outside click (dropdowns, modals) -->
<div data-on:click__outside="$dropdownOpen = false">
  Dropdown content
</div>

<!-- Listen on window -->
<div data-on:keydown__window="console.log('Global keypress')">

<!-- Listen on document -->
<div data-on:click__document="console.log('Document clicked')">
```

### Chaining Modifiers
```heex
<!-- Multiple modifiers -->
<form data-on:submit__prevent__debounce_300ms={Dstar.post(MyApp.FormHandler, "submit")}>
  <input data-model="email">
  <button type="submit">Submit</button>
</form>
```

### Practical Example: Search-as-you-type
```heex
<!-- HEEx template -->
<div data-signals:search="''">
  <input 
    type="search" 
    data-model="search"
    data-on:input__debounce_300ms={Dstar.post(MyApp.SearchHandler, "search")}
    placeholder="Search...">
  
  <div id="results">
    <!-- Results rendered here -->
  </div>
</div>
```

```elixir
# Elixir handler
defmodule MyApp.SearchHandler do
  use Dstar.Handler
  
  def handle_event("search", %{"search" => query}, socket) do
    results = MyApp.Search.query(query)
    
    socket
    |> Dstar.patch_elements("#results", """
      <%= for result <- @results do %>
        <div><%= result.title %></div>
      <% end %>
    """, results: results)
  end
end
```

---

## 9. Initialization

Run code when element mounts.

```heex
<!-- Establish persistent SSE stream -->
<div 
  data-signals:_csrf_token={"'#{Plug.CSRFProtection.get_csrf_token()}'"}
  data-init={~s|@post('#{~p"/stream"}', {retryMaxCount: Infinity})|}>
  App content
</div>

<!-- Initialize client-side library -->
<div data-init="initChart($chartData)">
  <canvas id="chart"></canvas>
</div>

<!-- Focus input on mount -->
<input data-init="$el.focus()" type="text">
```

---

## 10. Iteration

Render lists from array signals.

**Must be on a `<template>` element.**

```heex
<!-- Basic iteration -->
<div data-signals:items="['Apple', 'Banana', 'Cherry']">
  <template data-for="item in $items">
    <div data-text="item"></div>
  </template>
</div>

<!-- Object array with property access -->
<div data-signals:users="[{id: 1, name: 'Alice'}, {id: 2, name: 'Bob'}]">
  <template data-for="user in $users">
    <div>
      <span data-text="`ID: ${user.id}`"></span>
      <span data-text="user.name"></span>
    </div>
  </template>
</div>
```

### Practical Example: Todo List
```heex
<!-- HEEx template -->
<div data-signals:todos="[]">
  <ul>
    <template data-for="todo in $todos">
      <li>
        <input type="checkbox" data-model="todo.done">
        <span data-text="todo.title"></span>
      </li>
    </template>
  </ul>
</div>
```

```elixir
# Elixir: update todos from server
socket
|> Dstar.merge_signals(%{
  todos: [
    %{id: 1, title: "Buy milk", done: false},
    %{id: 2, title: "Walk dog", done: true}
  ]
})
```

---

## 11. Focus & Refs

Reference elements for programmatic access.

```heex
<!-- Element reference -->
<input data-ref="emailInput" type="email">

<!-- Access via $refs.emailInput in expressions -->
<button data-on:click="$refs.emailInput.focus()">
  Focus Email Input
</button>
```

---

## 12. Intersection Observer

Trigger actions when element enters viewport.

```heex
<!-- Basic intersection -->
<div data-intersect={Dstar.get(MyApp.ContentHandler, "load_more")}>
  Load more when visible
</div>

<!-- Fire once (lazy loading) -->
<img 
  data-intersect__once="$imageSrc = 'https://example.com/image.jpg'"
  data-attr:src="$imageSrc">

<!-- Modifiers -->
<div data-intersect__half="console.log('50% visible')">
<div data-intersect__full="console.log('100% visible')">
<div data-intersect__once="console.log('First time only')">
```

### Practical Example: Infinite Scroll
```heex
<!-- HEEx template -->
<div data-signals:page="1">
  <div id="items">
    <!-- Items rendered here -->
  </div>
  
  <!-- Sentinel element -->
  <div 
    data-intersect={Dstar.post(MyApp.ItemsHandler, "load_more")}
    class="h-1">
  </div>
</div>
```

```elixir
# Elixir handler
def handle_event("load_more", _params, socket) do
  page = socket.assigns.signals["page"] + 1
  items = MyApp.Items.get_page(page)
  
  socket
  |> Dstar.merge_signals(%{page: page})
  |> Dstar.patch_elements("#items", """
    <%= for item <- @items do %>
      <div><%= item.name %></div>
    <% end %>
  """, items: items, merge: :append)
end
```

---

## 13. Teleport

Move element to another DOM location.

```heex
<!-- Teleport to body (common for modals) -->
<div data-teleport="body">
  <div class="modal">
    Modal content
  </div>
</div>

<!-- Teleport to specific selector -->
<div data-teleport="#modal-root">
  Content moved here
</div>
```

**Use case:** Render modals, dropdowns, tooltips inside components but move to `<body>` to avoid z-index/overflow issues.

---

## 14. Scroll

Scroll element into viewport.

```heex
<!-- Basic scroll into view -->
<div data-scroll-into-view>
  I'll scroll into view when rendered
</div>

<!-- Smooth scrolling -->
<div data-scroll-into-view__smooth>
  Smooth scroll
</div>

<!-- Instant scrolling -->
<div data-scroll-into-view__instant>
  Instant scroll
</div>

<!-- Alignment modifiers -->
<div data-scroll-into-view__smooth__hcenter__vstart>
  <!-- Horizontal center, vertical start -->
</div>
```

**Available modifiers:**
- Behavior: `__smooth`, `__instant`, `__auto`
- Horizontal: `__hstart`, `__hcenter`, `__hend`, `__hnearest`
- Vertical: `__vstart`, `__vcenter`, `__vend`, `__vnearest`

**Use case:** Scroll to validation errors, new messages, or selected items.

---

## 15. View Transitions

Named view transitions for smooth UI updates.

```heex
<!-- Name transition elements -->
<div data-view-transition="hero-image">
  <img src="hero.jpg">
</div>
```

```elixir
# Elixir: enable view transitions on patch
socket
|> Dstar.patch_elements("#content", """
  <div data-view-transition="hero-image">
    <img src="new-hero.jpg">
  </div>
""", use_view_transitions: true)
```

**Use case:** Smooth morphing between states (image galleries, page transitions).

---

## 16. Persistence

Persist signals to localStorage.

```heex
<!-- Persist all signals -->
<div 
  data-signals:theme="'light'"
  data-signals:sidebarOpen="true"
  data-persist>
  <!-- All signals auto-saved to localStorage -->
</div>

<!-- Persist specific signals -->
<div 
  data-signals:theme="'light'"
  data-signals:sidebarOpen="true"
  data-signals:tempValue="''"
  data-persist="theme sidebarOpen">
  <!-- Only theme and sidebarOpen persisted -->
</div>
```

**Use case:** Remember user preferences, theme, form drafts across page loads.

---

## 17. Replace URL

Update browser URL without navigation.

```heex
<!-- Update URL to match filter state -->
<div data-signals:filter="'all'">
  <select data-model="filter">
    <option value="all">All</option>
    <option value="active">Active</option>
  </select>
  
  <div data-replace-url="`?filter=${$filter}`">
  </div>
</div>
```

**Use case:** Keep filter/search state in URL for shareable links, without full page reload.

---

## 18. Computed Signals

Derive signals from other signals.

```heex
<!-- Calculate derived values -->
<div 
  data-signals:price="10"
  data-signals:quantity="2"
  data-computed:total="$price * $quantity">
  
  <span data-text="`Total: $${$total}`"></span>
</div>

<!-- Complex computations -->
<div 
  data-signals:items="[{price: 10}, {price: 20}]"
  data-computed:sum="$items.reduce((acc, item) => acc + item.price, 0)">
  
  <span data-text="`Sum: $${$sum}`"></span>
</div>
```

**Updates reactively** when any dependency ($price, $quantity, $items) changes.

---

## 19. Indicator

Track request in-flight status.

```heex
<!-- Datastar sets indicator signal to true during SSE request -->
<div data-signals:_loading="false">
  <form 
    data-on:submit={Dstar.post(MyApp.FormHandler, "submit", indicator: "_loading")}
    data-indicator="_loading">
    
    <input type="email" data-model="email">
    
    <!-- Disable button during request -->
    <button 
      type="submit"
      data-attr:disabled="$_loading">
      <span data-show="!$_loading">Submit</span>
      <span data-show="$_loading">Submitting...</span>
    </button>
  </form>
</div>
```

**Best practice:** Use underscore prefix (`_loading`) for client-only indicator signals.

### Practical Pattern: Button Loading State
```heex
<div data-signals:_submitting="false">
  <button 
    data-on:click={Dstar.post(MyApp.Handler, "save", indicator: "_submitting")}
    data-indicator="_submitting"
    data-attr:disabled="$_submitting"
    data-class:opacity-50="$_submitting">
    
    <span data-show="!$_submitting">Save</span>
    <span data-show="$_submitting">
      <svg class="animate-spin"><!-- spinner --></svg>
      Saving...
    </span>
  </button>
</div>
```

---

## 20. Custom Headers & Options

Configure SSE requests in `@post`/`@get`/`@put`/`@delete`.

### Persistent SSE Stream
```heex
<!-- Retry forever for server-sent events stream -->
<div data-init={~s|@post('#{~p"/stream"}', {retryMaxCount: Infinity})|}>
</div>
```

### Custom Headers
```heex
<!-- Dstar automatically includes CSRF token for Phoenix -->
<button 
  data-on:click={~s|@post('/api/action', {
    headers: {
      'X-Custom-Header': 'value',
      'X-API-Key': $apiKey
    }
  })|}>
  Send with custom headers
</button>
```

**Note:** Dstar verb helpers (`Dstar.post/3`, etc.) automatically handle CSRF tokens for Phoenix apps.

### Common Options
- `retryMaxCount: Infinity` — For persistent streams
- `headers: {...}` — Custom request headers
- `indicator: "signalName"` — Loading state signal

---

## Quick Reference: Common Patterns

### Form with Loading State
```heex
<form 
  data-signals:_loading="false"
  data-on:submit={Dstar.post(MyApp.FormHandler, "submit", indicator: "_loading")}
  data-indicator="_loading">
  
  <input type="text" data-model="name" data-attr:disabled="$_loading">
  <button type="submit" data-attr:disabled="$_loading">
    <span data-show="!$_loading">Submit</span>
    <span data-show="$_loading">Submitting...</span>
  </button>
</form>
```

### Search with Debounce
```heex
<div data-signals:query="''">
  <input 
    type="search" 
    data-model="query"
    data-on:input__debounce_300ms={Dstar.post(MyApp.SearchHandler, "search")}>
</div>
```

### Modal with Outside Click
```heex
<div data-signals:modalOpen="false">
  <button data-on:click="$modalOpen = true">Open Modal</button>
  
  <div data-show="$modalOpen" class="modal-backdrop">
    <div 
      data-on:click__outside="$modalOpen = false"
      class="modal-content">
      Modal body
      <button data-on:click="$modalOpen = false">Close</button>
    </div>
  </div>
</div>
```

### Persistent SSE Connection
```heex
<div 
  data-signals:_csrf_token={"'#{Plug.CSRFProtection.get_csrf_token()}'"}
  data-init={~s|@post('#{~p"/stream"}', {retryMaxCount: Infinity})|}>
  
  <div id="live-updates">
    <!-- Server pushes updates here -->
  </div>
</div>
```

---

## Tips for Elixir/Phoenix Developers

1. **Signal Naming:** Use underscore prefix (`_loading`, `_csrf_token`) for client-only signals
2. **CSRF:** Dstar automatically includes CSRF tokens; for custom fetch add `data-signals:_csrf_token`
3. **HEEx Escaping:** Wrap JS strings in HEEx interpolation: `data-signals:id={"'#{@id}'"}`
4. **Indicators:** Always use client-only signals for loading states
5. **Debounce:** Default to 300ms for search, 500ms for expensive operations
6. **SSE Streams:** Use `retryMaxCount: Infinity` for persistent connections
7. **View Transitions:** Enable with `use_view_transitions: true` in `patch_elements`

---

## Resources

- **Datastar Docs:** https://data-star.dev
- **Dstar Library:** https://github.com/phaleth/dstar
- **Version:** Datastar v1.0.0
