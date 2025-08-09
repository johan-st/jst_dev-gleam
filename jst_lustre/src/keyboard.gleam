import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lustre/effect.{type Effect}
import plinth/browser/event
import plinth/browser/window

pub type Key {
  Captured(CapturedKey)
  Unhandled(code: String)
}

pub type Chord {
  Chord(keys: Set(Key))
}

pub type CapturedKey {
  Escape
  Space
  Enter
  Shift
  Ctrl
  Alt

  Digit1
  Digit2
  Digit3
  Digit4
  Digit5
  Digit6
  Digit7
  Digit8
  Digit9
  Digit0

  E
  L
  N
  S
  P
}

pub fn to_string(key: CapturedKey, shift: Bool) -> String {
  case key, shift {
    Escape, _ -> "Escape"
    Space, _ -> "Space"
    Enter, _ -> "Enter"
    Shift, _ -> "Shift"
    Ctrl, _ -> "Ctrl"
    Alt, _ -> "Alt"

    Digit1, _ -> "1"
    Digit2, _ -> "2"
    Digit3, _ -> "3"
    Digit4, _ -> "4"
    Digit5, _ -> "5"
    Digit6, _ -> "6"
    Digit7, _ -> "7"
    Digit8, _ -> "8"
    Digit9, _ -> "9"
    Digit0, _ -> "0"

    S, False -> "s"
    S, True -> "S"
    E, False -> "e"
    E, True -> "E"
    N, False -> "n"
    N, True -> "N"
    L, False -> "l"
    L, True -> "L"
    P, False -> "p"
    P, True -> "P"
  }
}

pub fn parse_key(code: String, key: String) -> Key {
  case code, key {
    "Escape", _ -> Captured(Escape)
    "Space", _ -> Captured(Space)
    "Enter", _ -> Captured(Enter)
    _, "Shift" -> Captured(Shift)
    _, "Control" -> Captured(Ctrl)
    _, "Alt" -> Captured(Alt)

    "Digit1", _ -> Captured(Digit1)
    "Digit2", _ -> Captured(Digit2)
    "Digit3", _ -> Captured(Digit3)
    "Digit4", _ -> Captured(Digit4)
    "Digit5", _ -> Captured(Digit5)
    "Digit6", _ -> Captured(Digit6)
    "Digit7", _ -> Captured(Digit7)
    "Digit8", _ -> Captured(Digit8)
    "Digit9", _ -> Captured(Digit9)
    "Digit0", _ -> Captured(Digit0)

    "KeyS", _ -> Captured(S)
    "KeyE", _ -> Captured(E)
    "KeyN", _ -> Captured(N)
    "KeyL", _ -> Captured(L)
    "KeyP", _ -> Captured(P)

    _, _ -> Unhandled(code)
  }
}

pub fn triggered_chord(
  keys_down: Set(Key),
  active_chords: Set(Chord),
) -> Option(Chord) {
  let #(triggered_chords, _) = to_chords(keys_down, active_chords)
  case set.to_list(triggered_chords) {
    [] -> None
    [chord, ..] -> Some(chord)
  }
}

pub fn to_chords(
  keys_set: Set(Key),
  chords: Set(Chord),
) -> #(Set(Chord), Set(Key)) {
  let #(chords_set, remaining) =
    do_to_chords(set.to_list(chords), keys_set, set.new())
  #(chords_set, remaining)
}

fn do_to_chords(
  chords: List(Chord),
  keys_set: Set(Key),
  matched_chords: Set(Chord),
) -> #(Set(Chord), Set(Key)) {
  case chords, set.to_list(keys_set) {
    [], _ -> #(matched_chords, keys_set)
    _, [] -> #(matched_chords, keys_set)
    [Chord(chord_set), ..rest_chords], _ -> {
      let is_subset = set.is_subset(chord_set, keys_set)
      let rest_keys = set.difference(keys_set, chord_set)

      case is_subset {
        True ->
          do_to_chords(
            rest_chords,
            rest_keys,
            set.insert(matched_chords, Chord(chord_set)),
          )
        False -> do_to_chords(rest_chords, rest_keys, matched_chords)
      }
    }
  }
}

pub fn setup(
  should_prevent: fn(event.Event(event.UIEvent(event.KeyboardEvent))) -> Bool,
  down: fn(event.Event(event.UIEvent(event.KeyboardEvent))) -> msg,
  up: fn(event.Event(event.UIEvent(event.KeyboardEvent))) -> msg,
) -> Effect(msg) {
  let eff_down =
    effect.from(fn(dispatch) {
      window.add_event_listener("keydown", fn(ev) {
        case should_prevent(ev) {
          True -> event.prevent_default(ev)
          False -> Nil
        }
        dispatch(down(ev))
      })
    })

  let eff_up =
    effect.from(fn(dispatch) {
      window.add_event_listener("keyup", fn(event) { dispatch(up(event)) })
    })

  effect.batch([eff_down, eff_up])
}
