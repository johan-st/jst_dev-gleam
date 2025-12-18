import gleam/io
import lustre/effect
import plinth/browser/document
import plinth/browser/window

pub fn setup(window_unfocused: msg) -> effect.Effect(msg) {
  effect.from(fn(dispatch) {
    window.add_event_listener("visibilitychange", fn(_event) {
      case document.visibility_state() {
        "hidden" -> dispatch(window_unfocused)
        "visible" -> Nil
        vis -> {
          io.println("unhandled window visibility: " <> vis)
          Nil
        }
      }
    })
    window.add_event_listener("blur", fn(_event) { dispatch(window_unfocused) })
  })
}
