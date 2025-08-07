import lustre/effect.{type Effect}
import plinth/browser/event
import plinth/browser/window

pub type Key {
  Captured(CapturedKey)
  Unhandled(String, String)
}

pub type CapturedKey {
  Escape
  Enter

  Ctrl
  CtrlS
  CtrlE
  CtrlN
  CtrlSpace

  Alt
  Alt1
  Alt2
  Alt3
  Alt4
  Alt5
  Alt6
  Alt7
  AltL
}

pub fn parse_key(code: String, key: String, ctrl: Bool, alt: Bool) -> Key {
  case code, key, ctrl, alt {
    "Escape", _, False, False -> Captured(Escape)
    "Enter", _, False, False -> Captured(Enter)

    _, "Control", _, _ -> Captured(Ctrl)
    _, "Alt", _, _ -> Captured(Alt)

    _, "s", True, False -> Captured(CtrlS)
    _, "e", True, False -> Captured(CtrlE)
    _, "n", True, False -> Captured(CtrlN)
    _, " ", True, False -> Captured(CtrlSpace)

    // Alt + number combinations
    "Digit1", _, False, True -> Captured(Alt1)
    "Digit2", _, False, True -> Captured(Alt2)
    "Digit3", _, False, True -> Captured(Alt3)
    "Digit4", _, False, True -> Captured(Alt4)
    "Digit5", _, False, True -> Captured(Alt5)
    "Digit6", _, False, True -> Captured(Alt6)
    "Digit7", _, False, True -> Captured(Alt7)

    // Alt + letter combinations
    "KeyL", _, False, True -> Captured(AltL)

    _, _, _, _ -> Unhandled(code, key)
  }
}

pub fn setup(down: fn(Key) -> msg, up: fn(Key) -> msg) -> Effect(msg) {
  let eff_down =
    effect.from(fn(dispatch) {
      window.add_event_listener("keydown", fn(event) {
        let code = event.code(event)
        let key = event.key(event)
        let ctrl = event.ctrl_key(event)
        let alt = event.alt_key(event)

        case parse_key(code, key, ctrl, alt) {
          Captured(shortcut) -> {
            event.prevent_default(event)
            dispatch(down(Captured(shortcut)))
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
        let ctrl = event.ctrl_key(event)
        let shift = event.shift_key(event)

        // For keyup events, we need to be more flexible with key matching
        // to handle cases where the key property might differ between down/up
        let parsed_key = case code, key, ctrl, shift {
          // Escape key (no modifiers)
          "Escape", _, False, False -> Captured(Escape)
          "Enter", _, False, False -> Captured(Enter)

          // Modifier keys - use the key property for these
          _, "Control", _, _ -> Captured(Ctrl)
          _, "Alt", _, _ -> Captured(Alt)

          // Ctrl combinations - handle both upper and lower case
          _, "s", True, False -> Captured(CtrlS)
          _, "S", True, False -> Captured(CtrlS)
          _, "e", True, False -> Captured(CtrlE)
          _, "E", True, False -> Captured(CtrlE)
          _, "n", True, False -> Captured(CtrlN)
          _, "N", True, False -> Captured(CtrlN)
          _, " ", True, False -> Captured(CtrlSpace)

          // Alt + number combinations
          "Digit1", _, False, True -> Captured(Alt1)
          "Digit2", _, False, True -> Captured(Alt2)
          "Digit3", _, False, True -> Captured(Alt3)
          "Digit4", _, False, True -> Captured(Alt4)
          "Digit5", _, False, True -> Captured(Alt5)
          "Digit6", _, False, True -> Captured(Alt6)
          "Digit7", _, False, True -> Captured(Alt7)

          // Alt + letter combinations
          "KeyL", _, False, True -> Captured(AltL)

          // Not in our whitelist - use code for consistency
          _, _, _, _ -> Unhandled(code, key)
        }

        case parsed_key {
          Captured(shortcut) -> {
            event.prevent_default(event)
            dispatch(up(Captured(shortcut)))
          }
          Unhandled(code, key) -> {
            dispatch(up(Unhandled(code, key)))
          }
        }
      })
    })
  effect.batch([eff_down, eff_up])
}
