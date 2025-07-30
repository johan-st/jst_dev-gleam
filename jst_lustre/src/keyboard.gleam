import lustre/effect.{type Effect}
import plinth/browser/event
import plinth/browser/window

pub type Key {
  Captured(CapturedKey)
  Unhandled(String, String)
}

pub type CapturedKey {
  Escape

  Ctrl
  CtrlS
  CtrlE
  CtrlN
  CtrlSpace

  Shift
  Shift1
  Shift2
}

pub fn parse_key(code: String, key: String, ctrl: Bool, shift: Bool) -> Key {
  case code, key, ctrl, shift {
    // Escape key (no modifiers)
    "Escape", _, False, False -> Captured(Escape)

    // Ctrl
    _, "Control", _, _ -> Captured(Ctrl)
    _, "s", True, False -> Captured(CtrlS)
    _, "e", True, False -> Captured(CtrlE)
    _, "n", True, False -> Captured(CtrlN)
    _, "Space", True, False -> Captured(CtrlSpace)

    // Shift
    _, "Shift", _, _ -> Captured(Shift)
    "Digit1", _, False, True -> Captured(Shift1)
    "Digit2", _, False, True -> Captured(Shift2)

    // Not in our whitelist
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
        let shift = event.shift_key(event)

        case parse_key(code, key, ctrl, shift) {
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
        case parse_key(code, key, ctrl, shift) {
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
