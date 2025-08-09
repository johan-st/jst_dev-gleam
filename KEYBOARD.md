### Keyboard chords (Gleam + Lustre)

This document describes how keyboard chords are modeled and wired in this app. It is implementation-oriented and tailored to `Gleam` + `Lustre` with `plinth` events.

## Goals

- Track held keys in the `Model` and match against context-aware chords.
- Alt is the navigation key; Ctrl is the command key.
  - Holding Alt shows a quick navigation overlay (immediately, no delay).
  - Holding Ctrl shows command hints in the bottom status bar (immediately).
  - Example nav chords: Alt+1 (Articles), Alt+L (Login), Alt+P (Profile), Alt+Space (Toggle preview/edit where applicable).
  - Example command chords: Ctrl+S (Save draft on edit), Ctrl+E (Start editing), Ctrl+N (New article in list).
- Keep chord definitions close to their pages (page-aware binding builder).
- Prevent browser defaults on critical chords (e.g., Ctrl+S, Alt+Space, Ctrl+N) using `plinth`.

## What exists today

- `jst_lustre/src/keyboard.gleam`: key parsing to normalized codes, chord (subset) matching, global listeners (`keydown`/`keyup`).
- `jst_lustre/src/jst_lustre.gleam`:
  - `Model.keys_down : Set(key.Key)` tracks held keys.
  - `Model.chords_available : Set(key.Chord)` (currently empty by default).
  - `Msg.KeyboardDown` and `Msg.KeyboardUp` receive the raw `plinth` keyboard event.
  - `update_chord` updates `keys_down` and can detect a matched chord, but does not dispatch actions yet.

## Missing pieces (filled by this design)

- A first-class way to map matched chords to app `Msg` and presentable hints.
- A per-page binding builder that returns global + page-specific chords based on context (route, session, page data).
- Hints UI driven by the active bindings, shown immediately when Alt/Ctrl are held.

## Types and model

Add a binding layer that associates a chord with a `Msg` and hint metadata:

```gleam
pub type ChordGroup {
  Nav
  Cmd
}

pub type ChordBinding {
  ChordBinding(
    chord: key.Chord,   // Set(Key)
    msg: Msg,           // Action to dispatch
    group: ChordGroup,  // Nav (Alt) or Cmd (Ctrl)
    label: String,      // For overlay/status hints
    block_default: Bool // Prevent browser defaults
  )
}
```

Extend `Model` with the live binding list (and derive `chords_available` from it):

- `chord_bindings : List(ChordBinding)` — context-filtered.
- `chords_available : Set(key.Chord)` — derived: `chord_bindings |> list.map(.chord) |> set.from_list`.

Notes:
- `Model.keys_down` remains the source of truth for held keys.
- Keep `keyboard.gleam` focused on parsing/matching; put the binding types where `Msg` is available (e.g., in `jst_lustre.gleam` or a small `keyboard_bindings.gleam` that imports `Msg`).

## Per-page binding builder

Build the bindings from the current page and session. This keeps definitions near page logic while avoiding cycles.

```gleam
fn ch(keys: List(key.Key)) -> key.Chord {
  key.Chord(set.from_list(keys))
}

fn bindings_for(page: pages.Page) -> List(ChordBinding) {
  let alt = key.Captured(key.Alt)
  let ctrl = key.Captured(key.Ctrl)

  let global_nav =
    [
      // Alt+1 → Articles
      ChordBinding(
        chord: ch([alt, key.Captured(key.Digit1)]),
        msg: UserMouseDownNavigation(routes.Articles |> routes.to_uri),
        group: Nav,
        label: "Articles",
        block_default: False,
      ),
      // Alt+L (only when unauthenticated)
      // Alt+P (only when authenticated)
      // Alt+Space (only where toggle makes sense)
    ]
    |> filter_by_session(page)

  let page_cmd =
    case page {
      pages.PageArticleList(_, session) ->
        case session {
          session.Authenticated(_) -> [
            // Ctrl+N → New article
            ChordBinding(
              chord: ch([ctrl, key.Captured(key.N)]),
              msg: ArticleCreateClicked,
              group: Cmd,
              label: "New article",
              block_default: True,
            ),
          ]
          _ -> []
        }

      pages.PageArticle(article, session) ->
        case article.can_edit(article, session) {
          True -> [
            // Ctrl+E → Start editing
            ChordBinding(
              chord: ch([ctrl, key.Captured(key.E)]),
              msg: UserMouseDownNavigation(routes.ArticleEdit(article.id) |> routes.to_uri),
              group: Cmd,
              label: "Edit",
              block_default: True,
            ),
          ]
          False -> []
        }

      pages.PageArticleEdit(article, _) -> [
        // Ctrl+S → Save draft
        ChordBinding(
          chord: ch([ctrl, key.Captured(key.S)]),
          msg: ArticleDraftSaveClicked(article),
          group: Cmd,
          label: "Save draft",
          block_default: True,
        ),
        // Alt+Space → Toggle preview/edit
        ChordBinding(
          chord: ch([alt, key.Captured(key.Space)]),
          msg: EditViewModeToggled,
          group: Nav,
          label: "Toggle preview/edit",
          block_default: True,
        ),
      ]

      _ -> []
    }

  list.append(global_nav, page_cmd)
}
```

Recompute `chord_bindings` on navigation and auth changes (see next section), then set `chords_available` from it.

## Wiring: when to recompute bindings

Recompute `chord_bindings` and `chords_available` whenever page context changes:

- In `init`, compute for the initial page.
- In `update_navigation` after route changes.
- On auth changes: `AuthLoginResponse`, `AuthLogoutResponse`, `AuthCheckResponse`.
- Optionally on article data transitions that affect editability.

Example pattern inside `update_navigation` (after computing `page`):

```gleam
let new_bindings = bindings_for(page)
let new_chords = new_bindings |> list.map(fn(b) { b.chord }) |> set.from_list
let model = Model(..model, chord_bindings: new_bindings, chords_available: new_chords)
```

## Wiring: matching in `update_chord`

Replace the current "matched but do nothing" branch with binding lookup and action dispatch. Also prevent defaults when requested.

Key rules:
- Update `keys_down` with the parsed key from the incoming event.
- Use `keyboard.triggered_chord(model.keys_down, model.chords_available)` to detect a chord.
- On match, find the `ChordBinding` with the same `chord`.
- If `binding.block_default`, call `p_event.prevent_default(ev)`.
- Clear the matched keys from `keys_down`.
- Delegate to `update(model, binding.msg)` to reuse existing handlers (like `ProfileMenuAction`).

Sketch (omitting unrelated branches):

```gleam
case key.triggered_chord(model.keys_down, model.chords_available) {
  None -> #(model, effect.none())
  Some(chord) ->
    let binding_opt =
      list.find(model.chord_bindings, fn(b) { b.chord == chord })

    case binding_opt {
      Error(_) -> #(model, effect.none())
      Ok(binding) -> {
        // Prevent default if requested
        case binding.block_default { True -> p_event.prevent_default(ev) False -> Nil }

        // Clear pressed chord keys
        let keys = case chord { key.Chord(keys) -> keys }
        let model = Model(..model, keys_down: set.difference(model.keys_down, keys))

        // Dispatch the bound message through the regular update
        update(model, binding.msg)
      }
    }
}
```

Notes:
- Current matching is subset-based. If you later need exact-only matching, add `exact: Bool` to `ChordBinding` and check `set.is_subset(keys, model.keys_down) && set.is_subset(model.keys_down, keys)` before accepting.
- Consider ignoring `repeat` keydown (if accessible via `plinth`) to reduce duplicate triggers.

## Preventing browser defaults

Use the raw keyboard event available in `KeyboardDown` to cancel default behavior for chords that should override the browser:

- Example candidates: `Ctrl+S` (save page), `Ctrl+N` (new window), `Alt+Space` (OS menu on Windows).
- Call `p_event.prevent_default(ev)` before dispatching the `Msg`.

No additional JS is required.

## Hints UI (immediate, no delay)

- Alt overlay: show when `key.Captured(key.Alt)` is present in `Model.keys_down`.
  - Source items from `model.chord_bindings` where `group == Nav` and the binding is valid for the current page/session.
  - Use the binding’s `label` and derive key strings from the chord keys for display.
- Ctrl hints in status bar: when `Ctrl` is held, show `group == Cmd` bindings in the bottom bar alongside your existing Ctrl/Alt indicators.

Deriving printable key names:
- Use `key.to_string(captured_key, shift)` for `Captured` keys. For `Unhandled`, show `(code)` or filter out if not used in bindings.

## Example chords to ship

- Global (Nav):
  - Alt+1 → Articles
  - Alt+L → Login (Unauthenticated/Pending only)
  - Alt+P → Profile (Authenticated only)
  - Alt+Space → Toggle preview/edit (only where applicable)
- Articles list (Cmd): Ctrl+N → New article
- Article page (Cmd): Ctrl+E → Start editing (if permitted)
- Article edit (Cmd): Ctrl+S → Save draft

All Ctrl commands should set `block_default = True`.

## Matching semantics

- Current implementation uses subset matching; the chosen chord is the first subset found. If you introduce overlapping chords, consider a deterministic chooser:
  - Prefer chords with more keys.
  - Then by group priority (Cmd vs Nav) or `id`/label.
  - Or switch matching to exact-only for critical combos.

## Edge cases / guardrails

- Bare modifiers (Alt-only, Ctrl-only) should not trigger actions; they only control hint visibility.
- Inputs/contenteditable: initial version can keep matching globally; if this becomes disruptive, add focus-aware gating later.
- OS conflicts: `Alt+Space` often conflicts on Windows; keep `block_default = True` there.
- Window blur: clear `keys_down` (already implemented via `WindowUnfocused`).

## Test plan

- No tests initially.

## Migration checklist

1) Add `ChordGroup` and `ChordBinding` types where `Msg` is visible.
2) Add `Model.chord_bindings : List(ChordBinding)` and derive `Model.chords_available` from it.
3) Implement `bindings_for(page: pages.Page)` returning global + page-specific bindings.
4) Recompute bindings in `init`, `update_navigation`, and auth transitions (`AuthLoginResponse`, `AuthLogoutResponse`, `AuthCheckResponse`).
5) Replace the no-op chord branch in `update_chord` with binding lookup, `prevent_default`, key clearing, and `update(model, binding.msg)` delegation.
6) Enable the Alt overlay and populate it from `group == Nav` bindings. Enhance the status bar to show `group == Cmd` when Ctrl is held.
7) Manually verify: Alt overlay and Ctrl hints appear instantly; chords trigger and prevent defaults as intended on all relevant pages.

## Notes on organization

- Keep `keyboard.gleam` focused on parsing, matching and listener setup (already good).
- Keep chord definitions as close to the pages as practical; the binding builder centralizes them while remaining page-aware.
- If the app grows, consider a `src/keyboard_bindings.gleam` module exporting `bindings_for/1` to declutter `jst_lustre.gleam`.

