import lustre/effect.{type Effect}
import plinth/browser/event
import plinth/browser/window

pub type Key {
  Captured(captured_key: CapturedKey)
  Unhandled(code: String, key: String)
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
}

pub fn to_string(key: CapturedKey) -> String {
  case key {
    Escape -> "Escape"
    Space -> "Space"
    Enter -> "Enter"
    Shift -> "Shift"
    Ctrl -> "Ctrl"
    Alt -> "Alt"

    Digit1 -> "1"
    Digit2 -> "2"
    Digit3 -> "3"
    Digit4 -> "4"
    Digit5 -> "5"
    Digit6 -> "6"
    Digit7 -> "7"
    Digit8 -> "8"
    Digit9 -> "9"
    Digit0 -> "0"

    S -> "S"
    E -> "E"
    N -> "N"
    L -> "L"
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

    _, _ -> Unhandled(code, key)
  }
}

pub fn setup(down: fn(Key) -> msg, up: fn(Key) -> msg) -> Effect(msg) {
  let eff_down =
    effect.from(fn(dispatch) {
      window.add_event_listener("keydown", fn(event) {
        let code = event.code(event)
        let key = event.key(event)

        case parse_key(code, key) {
          Captured(captured_key) -> {
            // event.prevent_default(event)
            dispatch(down(Captured(captured_key)))
          }
          Unhandled(code, key) -> {
            dispatch(down(Unhandled(code, key)))
          }
        }
      })
    })
  let eff_up =
    effect.from(fn(dispatch) {
      window.add_event_listener("keyup", fn(event) {
        let code = event.code(event)
        let key = event.key(event)

        case parse_key(code, key) {
          Captured(captured_key) -> {
            // event.prevent_default(event)
            dispatch(up(Captured(captured_key)))
          }
          Unhandled(code, key) -> {
            dispatch(up(Unhandled(code, key)))
          }
        }
      })
    })
  effect.batch([eff_down, eff_up])
}
