# Dstar JavaScript Islands Usage

## When to use

Reach for a JavaScript island when you embed a stateful component whose DOM is
owned by a JS library — a rich-text editor, map, chart, canvas, date-picker — in
a Datastar page. Datastar morphs the DOM on every patch; a library that manages
its own subtree must coexist with that. Use plain Datastar (signals + `data-*`)
for everything else — don't reach for an island for a counter or a toggle.

## The contract

**An island is a custom element that is also a Datastar form control.**

| Concern | Mechanism |
|---|---|
| Config in | element attributes (`data-*`), read in `connectedCallback` |
| State out | the element exposes a `value` property and dispatches `input`/`change`; `data-bind` two-way binds it (Datastar's bind plugin special-cases custom elements that expose a `value` property) |
| Content in | the server patches the bound signal; Datastar writes `el.value`; the element's `value` setter applies it to the managed DOM |
| Commands in | element-targeted `CustomEvent`s — the server emits a one-line `Dstar.execute_script` that dispatches at the element by id |
| Morph survival | `data-ignore-morph` on the element — Datastar's morph skips it and its subtree while still binding/scanning the element itself |

State flows out through the bound signal; content and commands flow in through
the signal and through events. The element owns its subtree; Datastar owns
everything around it.

## Minimal example

`<plain-editor>` wraps a JS-managed `contenteditable` div.

```heex
<plain-editor id="note-1" data-bind="note" data-ignore-morph data-content={@note}></plain-editor>
```

```javascript
// A minimal Datastar JS-island.
class PlainEditor extends HTMLElement {
  connectedCallback() {
    if (this._box) return; // already mounted (e.g. re-connected after a morph move)
    this._box = document.createElement("div");
    this._box.contentEditable = "true";
    this._box.className = "plain-editor__box";
    this._box.innerHTML = this.dataset.content || "";
    // state out: user edits -> dispatch input so data-bind writes el.value -> signal
    this._box.addEventListener("input", () => {
      if (this._applying) return;
      this.dispatchEvent(new Event("input", { bubbles: true }));
    });
    this.appendChild(this._box);
    // command in
    this.addEventListener("plain-editor:clear", () => { this.value = ""; });
  }

  disconnectedCallback() {
    // idiomorph relocates nodes via disconnect->reconnect; tear down only on real removal
    queueMicrotask(() => { if (!this.isConnected) this._box = null; });
  }

  get value() {
    return this._box ? this._box.innerHTML : (this.dataset.content || "");
  }

  set value(html) {
    if (!this._box) { this.dataset.content = html || ""; return; } // not yet mounted — stash so connectedCallback applies it
    if ((html || "") === this._box.innerHTML) return;              // idempotent
    this._applying = true;
    this._box.innerHTML = html || "";
    this._applying = false;
  }
}

customElements.define("plain-editor", PlainEditor);
```

```css
/* Scope island CSS to the element, never a marker attribute. */
plain-editor .plain-editor__box {
  min-height: 4rem;
  padding: 0.5rem;
}
```

Drive it from the server:

```elixir
# content in: patch the bound signal; the element's value setter applies it
def handle_event(conn, "seed", _signals) do
  Dstar.patch_signals(conn, %{note: "<p>Hello from the server</p>"})
end

# command in: dispatch a CustomEvent at the element by id
def handle_event(conn, "clear", _signals) do
  Dstar.execute_script(
    conn,
    "document.getElementById('note-1')?.dispatchEvent(new CustomEvent('plain-editor:clear'))"
  )
end
```

## Lifecycle

`connectedCallback`/`disconnectedCallback` are the island's lifecycle — don't
hand-roll a `MutationObserver` or a global registry to find and initialise
islands; the platform does it for you, including for elements Datastar patches in
later.

The `queueMicrotask(() => { if (!this.isConnected) … })` guard in
`disconnectedCallback` is required: a DOM morph can *relocate* a node, which fires
`disconnectedCallback` immediately followed by `connectedCallback`. Tearing down
synchronously on disconnect would destroy the island on unrelated patches.

## Anti-patterns

❌ **A global observer/registry to manage islands.** ✅ Use the custom-element
lifecycle.

❌ **A non-idempotent `value` setter, or one that runs before the element is
mounted.** Datastar's bind runs an *immediate* signal→element effect on mount, so
the setter fires with the signal's current value the moment the element binds. If
it isn't idempotent (`if html === current, return`) and a no-op before the managed
DOM exists, it re-applies content over freshly-loaded state and can clobber it.

❌ **Assuming `Dstar.patch_signals` nests dotted keys.** It JSON-encodes the map
as-is. A signal bound as `data-bind="foo.bar"` must be set with the matching shape
— pick one representation (`%{"foo.bar" => v}`) and use it consistently across
call sites (a nested map like `%{foo: %{bar: v}}` would emit `{"foo":{"bar":…}}` and never match a signal bound as `foo.bar`).

❌ **Scoping island CSS to a marker attribute** (e.g. `[data-island] …`). A marker
can be dropped in a refactor and silently un-scope every rule. ✅ Scope to the
element name (`plain-editor …`). Also: `data-ignore-morph` ≠ `data-ignore` — the
latter stops Datastar binding/scanning the element entirely; you want the morph
skipped, not the binding.

❌ **Letting the signal drive content on an island with its own sync transport**
(a collaborative editor over a websocket/CRDT). The transport, not the signal, is
the source of truth there. Ignore signal-driven applies until the transport has
synced, and seed from server content only if the transport's document is empty.

❌ **Putting the island's managed subtree inside a `patch_elements` target without
`data-ignore-morph`.** The morph will reconcile away the JS-managed DOM.

## Real-world reference

`defacto`'s `<defacto-rich-editor>` (Tiptap + Yjs/Hocuspocus collaborative
editing) implements this contract.
