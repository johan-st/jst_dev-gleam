/// DOM utility functions for browser interactions
import lustre/effect

@external(javascript, "../app.ffi.mjs", "focus_and_select_element")
fn focus_and_select_element_js(element_id: String) -> Nil

pub fn focus_and_select_element(element_id: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    focus_and_select_element_js(element_id)
    Nil
  })
} 