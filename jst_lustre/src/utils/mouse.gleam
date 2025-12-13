import gleam/dynamic/decode as dec
import lustre/attribute.{type Attribute}
import lustre/event

/// Mouse helpers
/// on mousedown, dispatch msg except when right-click (button == 2)
pub fn on_mouse_down_no_right(msg: msg) -> Attribute(msg) {
  let decoder = {
    use button <- dec.field("button", dec.int)
    case button {
      2 -> dec.failure(msg, "LeftOrMiddleClick")
      _ -> dec.success(msg)
    }
  }

  event.on("mousedown", decoder)
}
