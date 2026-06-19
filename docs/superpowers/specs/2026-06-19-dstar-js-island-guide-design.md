# Dstar JavaScript Islands guide — design

- **Date:** 2026-06-19
- **Status:** Approved design — ready for implementation plan
- **Repo:** `dstar` (this library). A one-line back-pointer is also added in the
  `defacto` app (the reference implementation).
- **Origin:** Cycle 2 of the Tiptap-as-Datastar-island work. Cycle 1 (the
  `defacto` `<defacto-rich-editor>` refactor) is complete and shipped; this guide
  lifts the proven, battle-tested contract into reusable documentation. See
  `defacto/docs/superpowers/specs/2026-06-18-tiptap-web-component-design.md`.

## Context & goal

`dstar` documents streaming, signals, attributes, error-handling, loading-states,
and heex-rendering — but nothing on **integrating a stateful, JS-managed-DOM
component into a Datastar page**. That is a recurring need (rich-text editors,
maps, charts, canvases, date-pickers) and a genuine source of bugs, because
Datastar morphs the DOM and a JS library that owns a subtree must coexist with
that.

Cycle 1 produced a working, reviewed, behaviorally-verified implementation of
this pattern (a Tiptap editor as a custom element) and, in doing so, surfaced
several non-obvious failure modes. This guide captures the **contract** and those
**failure modes** so other Datastar implementations can follow it.

## Goal

A concise, library-agnostic usage-rules topic teaching the Datastar ↔ JS-island
contract, matching the style of the existing `usage-rules/` topics (patterns +
code + anti-patterns), with the hard-won gotchas as the highest-value content.

## Non-goals

- Not Tiptap-specific. The worked example is a minimal generic island;
  `defacto`'s editor is cited once as a real-world instance.
- No ExDoc/hexdocs `extras` entry in this cycle (the existing topics aren't
  extras; staying consistent). Can be reconsidered later.
- No new library code in `dstar` — this is documentation only.
- No `Dstar`-provided base class / helper for islands — the pattern is
  documented, not abstracted (YAGNI; revisit only if a second consumer wants it).

## Deliverables

1. **`usage-rules/javascript-islands.md`** (new) — the topic, in the existing
   `# Dstar … Usage` style. This is the primary deliverable; it flows into
   consuming apps' agent context via `usage_rules` (matching `streaming.md`
   et al.).
2. **A short "JavaScript Islands" pointer section in `usage-rules.md`** (the main
   file) — 2–3 lines + a link to the topic, mirroring how streaming appears both
   in the main file and as a topic, so the pattern is discoverable from the index.
3. **A one-line back-pointer in `defacto`** — in `docs/dstar-follow-ups.md`
   (and/or a code comment near `<defacto-rich-editor>`) noting the canonical
   pattern lives in this dstar guide. The reference implementation cites the doc.

## The topic's structure

Mirrors existing topics (concise, code-forward, anti-patterns at the end).

### 1. When to use
Embedding a stateful component whose DOM is managed by a JS library (editor, map,
chart, canvas, date-picker) in a Datastar page — i.e. a subtree Datastar must not
morph and that needs imperative JS lifecycle.

### 2. The contract
*An island is a custom element that is also a Datastar form control.* Presented
as a compact table:

| Concern | Mechanism |
|---|---|
| Config in | element attributes (`data-*`) read at `connectedCallback` |
| State out | element exposes a `value` property + dispatches `input`/`change`; `data-bind` two-way binds it (Datastar's bind plugin special-cases custom elements with a `value` property) |
| Content/state in | server patches the bound signal; Datastar writes `el.value`; the element's `value` setter applies it |
| Commands in | element-targeted `CustomEvent`s — server emits `Dstar.execute_script` dispatching at the element by id |
| Morph survival | `data-ignore-morph` on the element (Datastar's morph skips it + its subtree; the element still binds) |

### 3. Minimal example
A minimal **generic** island — a `<plain-editor>` wrapping a single
JS-managed `contenteditable` div (the archetypal "JS owns the DOM" case, stripped
of any library). Concretely it shows:

- **HEEx:** `<plain-editor id={@id} data-bind="note" data-ignore-morph data-content={@note}></plain-editor>`
- **Custom element (JS):**
  - `connectedCallback()` → build the managed DOM (a `contenteditable` div),
    seed it from `data-content`, attach an `input` listener that dispatches
    `new Event("input", {bubbles:true})` on the host (unless mid-apply).
  - `get value()` → return the managed DOM's HTML (or `data-content` before
    built).
  - `set value(html)` → idempotent apply (`if html === current, return`); set an
    `_applying` flag around the write so it doesn't echo.
  - `disconnectedCallback()` → `queueMicrotask(() => { if (!this.isConnected) cleanup() })`.
  - `customElements.define("plain-editor", …)`.
  - a `this.addEventListener("editor:clear", …)` for a sample command.
- **Server:** content-in via `Dstar.patch_signals(conn, %{note: "<p>hi</p>"})`;
  command via `Dstar.execute_script(conn, "document.getElementById('note-1')?.dispatchEvent(new CustomEvent('editor:clear'))")`.

The example must be complete and runnable-in-spirit (no `…` placeholders in the
final guide), but small — roughly the size of `streaming.md`'s example.

### 4. Lifecycle
Custom-element callbacks replace any hand-rolled `MutationObserver`/registry.
The `queueMicrotask` + `isConnected` move-guard is required because idiomorph
(Datastar's morph) can relocate a node via disconnect→reconnect; without the
guard the island tears down on unrelated patches.

### 5. Anti-patterns / gotchas (the highest-value section)
Each as a short "❌ / ✅" or "Don't / Do" with one-line rationale:

1. **Don't hand-roll a global observer/registry** to find islands — use the
   element lifecycle (`connectedCallback`/`disconnectedCallback`).
2. **Make the `value` setter idempotent and a no-op before init.** Datastar's
   bind runs an *immediate* signal→element effect on mount; a non-idempotent
   setter re-applies content over freshly-loaded state and can clobber it (this
   bit us with a collaborative document).
3. **`Dstar.Signals.patch` JSON-encodes the map as-is** — it does *not* expand
   dotted keys into nested signals. To set a signal bound as `data-bind="foo.bar"`,
   match the binding (`%{"foo.bar" => v}`); pick one representation and be
   consistent across call sites.
4. **Scope island CSS to the element** (`plain-editor …`), not a marker
   attribute — a marker can be dropped during refactors and silently un-scope
   every rule. And `data-ignore-morph` ≠ `data-ignore`: the latter stops Datastar
   binding/scanning the element entirely (you want morph-skip, not bind-skip).
5. **Islands with their own sync transport** (e.g. collaborative editors over a
   websocket/CRDT): ignore signal-driven content applies until the transport has
   synced — the signal is not the source of truth there; let the transport load
   initial content (seed from server content only if the transport doc is empty).
6. **Don't put the island's managed subtree inside a `patch_elements` target**
   without `data-ignore-morph` — the morph will reconcile away the JS-managed DOM.

### 6. Real-world reference
One line: `defacto`'s `<defacto-rich-editor>` (Tiptap + Yjs/Hocuspocus)
implements this contract.

## Open checks (resolve during plan/impl)
- Confirm a new `usage-rules/javascript-islands.md` is picked up by a consumer's
  `usage_rules` sync the same way the existing topics are (placement matches, so
  expected yes; verify).
- Confirm the exact defacto host for the back-pointer (`docs/dstar-follow-ups.md`
  is the intended spot).

## Success criteria
- The topic reads like a peer of `usage-rules/streaming.md` (tone, length,
  code-forward), is library-agnostic, and contains a complete minimal example
  with no placeholders.
- All six gotchas present with rationale.
- Discoverable from `usage-rules.md` and cited from defacto.
