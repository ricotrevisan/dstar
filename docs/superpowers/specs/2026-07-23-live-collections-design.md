# Live collections — core helpers + nudge convention (design)

**Date:** 2026-07-23
**Issue:** [#7](https://github.com/ricotrevisan/dstar/issues/7) (part of epic [#16](https://github.com/ricotrevisan/dstar/issues/16))
**Status:** implemented 2026-07-24 (spike verified against Datastar v1 free bundle
and Pro v1.0.2). Facade names resolved to `append_elements` / `upsert_elements` /
`nudge` — see "Open decision" below.
**Scope:** dstar core only. The Ash adapter (`AshDstar.Stream`, #9) is specced separately in the `ash_dstar` repo and builds on this.

## Context

Dstar has the plumbing for real-time pages (`handle_connect`, the library-owned
receive loop, `handle_info/2`) but no guidance or helpers for the most common
payload: **keeping a list current in every open tab**.

The naive approach — render the changed row server-side and push it (append /
morph / remove) — is correct only for plain, unfiltered feeds. The stream
process is blind: it opened at page load and the SSE stream is one-way, so it
can never learn the tab's current filter/sort/page (that state lives in browser
signals and does not flow back up the open stream). Blind row mutation against
a filtered/sorted/paginated view produces silently wrong UIs: appended rows
that don't match the filter, stale rows that should have left the view, broken
sort order and page counts.

The fix is the **data-changed nudge**: the server pushes only a "this data
changed" signal bump; the client re-runs its own load action, which — like
every Datastar request — carries the tab's *current* signals. Each tab asks its
own question; each tab gets a view correct for that tab. Stateless and always
correct, at the cost of one query per tab per change.

This spec bakes both patterns into core as thin, named functions plus a docs
topic, so the correct default is the path of least resistance instead of a
production bug every user discovers independently.

## Grounding facts (verified against dstar source @ 0.1.3)

- `Dstar.Elements.patch(conn, html, opts)` — `:selector` optional; with no
  selector Datastar matches elements by their `id` attribute. `:mode` supports
  `:append` (into the selector target's children).
- `Dstar.remove_elements(conn, selector, opts \\ [])` exists — row-remove needs
  no new function.
- `Dstar.Signals.patch(conn, map, opts \\ [])` deep-merges nested maps on the
  client, so `%{nudges: %{posts: n}}` patches only `nudges.posts`.
- `Dstar.Page.Helpers` (imported by `use Dstar.Page`) holds `event/1,2`,
  `connect/0,1`, `patch/3,4`. `Dstar.Actions` builds Datastar action
  expressions (`"@post('…')"`).
- House rule (per issue #7): the stream process is one-way and cannot learn a
  tab's view state after connect. **Nudge-then-reload is the default for
  filtered/sorted/paginated views; row mutation is the fast path for plain
  feeds.**

## Goals

1. Name the two patterns and make each a one-line call from `handle_info/2`.
2. Framework-agnostic: proven with a plain `Phoenix.PubSub` broadcast, zero Ash
   awareness, no new deps (`plug` + `jason` unchanged).
3. Document the blind-stream trap and the DOM-id discipline in a usage-rules
   topic that adapter packages (ash_dstar #9) and app code can link to.

## Non-goals

- Anything Ash-aware (notification translation, resource introspection) — #9.
- A new module (design decision: option B, fold into existing modules — the
  concept's home is the docs topic, not a namespace).
- True create-or-update upsert (morph-if-present *else append*). Server-side
  code cannot know DOM presence; the nudge covers that case correctly.
- Debounce/throttle helpers for hot topics (client-side `__debounce` modifiers
  already exist; revisit if real apps need server-side coalescing).

## Public API

All new functions get facade delegations on `Dstar`.

### `Dstar.Elements.append(conn, html, container, opts \\ [])`

Appends `html` as the last child of `container` (a CSS selector). Delegates to
`patch(conn, html, [selector: container, mode: :append] ++ opts)`. For
create-events on plain feeds.

### `Dstar.Elements.upsert(conn, html, opts \\ [])`

Outer-morphs the element whose DOM `id` matches the root of `html` — exactly
issue #7's "upsert by id". Delegates to `patch(conn, html, opts)` (no
selector). **Documented sharp edge (moduledoc):** if no element with that id
exists in the tab, Datastar drops the patch — rows the tab never rendered stay
absent. Acceptable for feeds; when it isn't, use the nudge.

### `Dstar.Signals.nudge(conn, key, opts \\ [])`

Patches `%{nudges: %{key => value}}` where `value` is
`System.unique_integer([:positive, :monotonic])` — guaranteed to differ from
the client's current value within a node, and any *change* is sufficient to
fire the client handler. `key` must match `~r/^[a-zA-Z0-9_]+$/` (it becomes a
signal path segment); raises `ArgumentError` otherwise. Namespacing every
nudge under the single `nudges` signal avoids collisions with app signals and
gives the client one stable path shape to watch (`$nudges.posts`).

### `Dstar.Actions.on_nudge(key, action)`

The client half. Returns an attribute **map** for HEEx spread:

```heex
<div id="posts" {on_nudge("posts", event("reload"))}>
```

emits (attribute names verified against the v1 bundle, 2026-07-24):

```html
data-on-signal-patch="@post(…reload…)"
data-on-signal-patch-filter="{&quot;include&quot;:&quot;^nudges\\.posts$&quot;}"
```

**Not** `data-on:signal-patch` — the plugin's registered name is literally
`on-signal-patch`, and the attribute parser splits plugin-from-key on `:`
only (`t.split(/:(.+)/)`). `data-on:signal-patch` parses as plugin `on` with
key `signal-patch`, i.e. a listener for a DOM event that is never dispatched
(the real event is `datastar-signal-patch`) — a silent no-op. The filter is a
sibling attribute read with `getAttribute`, not a key.

so the action re-runs only when *that* nudge changes — and, unlike
`data-effect`, not on page init. Same `key` validation as `nudge/3`.
Re-exported from `Dstar.Page.Helpers` (defdelegate) so pages get it alongside
`event/2`; usable anywhere via `Dstar.on_nudge/2`.

### Canonical usage (from `handle_info/2`)

```elixir
# Fast path — plain feed:
def handle_info({:post_created, post}, conn),
  do: append_elements(conn, post_row(%{post: post}), "#posts")

def handle_info({:post_updated, post}, conn),
  do: upsert_elements(conn, post_row(%{post: post}))

def handle_info({:post_deleted, id}, conn),
  do: remove_elements(conn, "#post-#{id}")

# Default for filtered/sorted/paginated views:
def handle_info({:posts_changed, _}, conn),
  do: nudge(conn, "posts")
```

The reload handler is an ordinary page event that re-queries with the signals
it receives (filter/sort/page) and patches the list container.

## Docs

New `usage-rules/live-collections.md`:

1. The blind-stream trap (why row mutation breaks under filters).
2. The two patterns, with the decision rule stated as the default.
3. DOM-id discipline: every row carries a stable, unique `id`
   (`"{collection-singular}-{record-id}"` suggested).
4. The nudge wiring end-to-end: `nudge/2` → `on_nudge/2` → reload event.
5. Consistency window note: subscribe happens in `handle_connect` (after the
   GET render), so changes landing between render and subscribe are missed —
   the nudge pattern self-heals on the next change; feeds may want an initial
   nudge on connect.

README gets a short "Live collections" section linking to the topic.

## Spike results (verified against the Datastar v1 bundle, 2026-07-24)

- [x] **Attribute names — assumption was wrong.** Correct:
      `data-on-signal-patch` + `data-on-signal-patch-filter`. See the
      `on_nudge/2` section above for why the colon form silently no-ops.
      Filter syntax `{include, exclude}` confirmed; the attribute value is
      parsed with `JSON.parse` first and falls back to `Function("return (…)")`,
      and `include` accepts a **string** as well as a regex literal
      (`typeof e == "string" ? RegExp(e.replace(/^\/|\/$/g, "")) : e`).
      Emit the JSON string form — it needs no eval, so it survives a strict
      CSP. Defaults: `include: /.*/`, `exclude: /(?!)/`.
- [x] **Unchanged values do not fire — `unique_integer` is load-bearing.**
      The signal write returns a changed-flag
      (`if (e.t !== (e.t = t[0])) { … return true } return false`) and the
      patch-event enqueue is gated on it. Patching a nudge to its current
      value dispatches nothing.
- [x] **Missing id: patch is dropped**, with
      `console.warn(PatchElementsNoTargetsFound, {element: {id}})`. The
      `upsert/3` sharp edge as documented is accurate.
- [x] **`mode: :append` appends as last child** (`target.append(clone)`).
      Datastar additionally throws `PatchElementsExpectedSelector` for any
      mode other than `outer`/`replace` without a selector, so `append/4`'s
      required `container` argument matches client-side enforcement. Note for
      the docs: non-`outer` modes apply to *every* `querySelectorAll` match,
      cloning the element per target.

## Testing strategy (TDD)

- **Unit (Dstar.Test, wire-level):** `append/4` emits selector+mode lines;
  `upsert/3` emits no selector line; `nudge/3` emits a
  `datastar-patch-signals` for `nudges.<key>` with changing values across two
  calls; key validation raises; `on_nudge/2` returns the exact attribute map
  (regex-escaped key).
- **Acceptance (Ash-free, per issue #7):** a test page defined **inline in the
  test file** (there is no `test/support` dir and no `elixirc_paths` override
  for `:test`; `test/dstar/page/plug_test.exs` defines its pages inline —
  follow that rather than adding build config), subscribed to a plain
  `Phoenix.PubSub` topic; broadcasts drive
  append/upsert/remove and a nudge through the real `Dstar.Page.Plug` loop;
  assert the accumulated SSE body. Phoenix is already an optional test dep
  (page tests exist today), so this adds no new deps.

## Decisions resolved

- **Option B (no new module).** Functions live in `Dstar.Elements` /
  `Dstar.Signals` / `Dstar.Actions` with facade delegations; the concept's
  named home is `usage-rules/live-collections.md`. (User decision, 2026-07-23.)
- **`upsert` = morph-by-id only** — no append-fallback magic; the dropped-when-
  absent behavior is documented, and the nudge is the answer when it matters.
- **Nudges namespaced under one `nudges` signal**, unique-integer values,
  validated keys.
- **No subscribe helper** — subscribing is app-side (`Phoenix.PubSub` or
  Endpoint), keeping core dep-free.

## Open decision — resolved 2026-07-24

**Facade names: `append_elements` / `upsert_elements` / `nudge`.** Module-level
names stay short (`Elements.append/4`, `Elements.upsert/3`,
`Signals.nudge/3`); the flat facade takes the `_elements` suffix, matching
`patch_elements` / `remove_elements`. The deciding fact is `lib/dstar/page.ex`:
pages import the conn-first ops unqualified, and the comment above that import
list already records that the bare verbs (`post`, `patch`, `event`) are the URL
builders. A bare `Dstar.append` would sit in the ambiguous middle. `nudge` has
no such clash, so it keeps the short name. In a page handler this reads:

```elixir
def handle_info({:post_created, post}, conn),
  do: append_elements(conn, post_row(%{post: post}), "#posts")

def handle_info({:posts_changed, _}, conn), do: nudge(conn, "posts")
```

## Relationship to roadmap

`AshDstar.Stream` (#9) maps `Ash.Notifier.Notification` action types onto
exactly these calls (`append`/`upsert`/`remove_elements`/`nudge`). The Kanban
hero demo (#15) is the two-tab acceptance test for the stack.
