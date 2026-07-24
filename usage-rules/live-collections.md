# Live Collections

How to keep a list current in every open tab.

## The blind-stream trap

A stream process opens once, at page load. The SSE stream is one-way, so it
can **never learn what the tab is looking at now** — the filter, the sort, the
page number all live in browser signals that only travel *up* on a request,
and the open stream is not a request.

So the obvious approach is a trap:

```elixir
# WRONG for any list that can be filtered, sorted or paginated
def handle_info({:post_created, post}, conn),
  do: append_elements(conn, post_row(%{post: post}), "#posts")
```

Tab A is showing "drafts only, sorted by title, page 2". A new *published*
post arrives. The stream appends it anyway — it has no idea. The user now
sees a row that does not match their filter, in the wrong sort position, on a
page that should not contain it. Nothing errors. The UI is just quietly wrong.

The same blindness breaks updates (a row that should have *left* the filtered
view stays) and deletes (page counts drift).

## The two patterns

**Nudge, then reload — the default.** The server says only "this data
changed". Each tab re-runs its own load action, which — like every Datastar
request — carries that tab's current signals. Each tab asks its own question
and gets an answer correct for that tab.

```elixir
def handle_info({:posts_changed, _}, conn), do: nudge(conn, "posts")
```

**Row mutation — the fast path.** Only for a plain, unfiltered, unsorted,
unpaginated feed, where "what changed" and "what this tab shows" cannot
disagree.

```elixir
def handle_info({:post_created, post}, conn),
  do: append_elements(conn, post_row(%{post: post}), "#posts")

def handle_info({:post_updated, post}, conn),
  do: upsert_elements(conn, post_row(%{post: post}))

def handle_info({:post_deleted, id}, conn),
  do: remove_elements(conn, "#post-#{id}")
```

**The rule:** if the view has a filter, a sort, or pages — nudge. Otherwise
mutate rows. When in doubt, nudge: it costs one query per tab per change and
is never wrong.

## DOM-id discipline

Row mutation targets elements by `id`, so every row needs a stable, unique
one. The suggested shape is `"{singular}-{record-id}"`:

```heex
<li id={"post-#{@post.id}"}>...</li>
```

`upsert_elements/2` sends **no selector** — Datastar matches the root
element's `id`. If this tab has no element with that id, Datastar logs
`PatchElementsNoTargetsFound` and **drops the patch**. A row the tab never
rendered stays absent. That is correct for a feed (the row is off-screen
anyway) and wrong for a filtered view — which is the nudge's job.

`append_elements/3` needs a container selector, and appends as its last
child. Note it applies to *every* element matching the selector, so keep
container selectors unique.

## Wiring a nudge end-to-end

**1. Mark the container** with the client half:

```heex
<div id="posts" {on_nudge("posts", event("reload"))}>
  <.post_list posts={@posts} filter={@filter} />
</div>
```

That emits the Datastar attributes that re-run the action when — and only
when — `nudges.posts` changes:

```html
data-on-signal-patch="@post(…/_event/reload)"
data-on-signal-patch-filter='{"include":"^nudges\\.posts$"}'
```

Unlike `data-effect`, it does not fire on page init.

**2. Reload with the tab's own signals** — an ordinary page event:

```elixir
def handle_event(conn, "reload", signals) do
  posts = list_posts(filter: signals["filter"], sort: signals["sort"], page: signals["page"])

  conn
  |> assign(posts: posts)
  |> patch(&post_list/1, posts: posts, filter: signals["filter"])
end
```

**3. Nudge from the stream** when the data changes:

```elixir
def handle_connect(conn, _params) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
  conn
end

def handle_info({:posts_changed, _}, conn), do: nudge(conn, "posts")
```

Nudges are namespaced under one `nudges` signal so they never collide with
app signals, and keys must be a single path segment (`~r/^[a-zA-Z0-9_]+$/`).
Each nudge sends a fresh integer — the client only reacts when a value
actually *changes*, so a constant would be a silent no-op.

## The consistency window

`handle_connect` subscribes **after** the GET has already rendered the page,
so a change landing in that gap is missed. The nudge pattern self-heals on
the next change. If a feed must not miss anything, nudge once on connect:

```elixir
def handle_connect(conn, _params) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
  nudge(conn, "posts")
end
```

## Naming note

The conn-first helpers carry the `_elements` suffix (`append_elements`,
`upsert_elements`, `remove_elements`, `patch_elements`) because the bare
verbs on `Dstar` are the URL builders (`Dstar.patch/2`, `Dstar.post/2`).
`nudge/2` has no such clash, so it keeps the short name.
