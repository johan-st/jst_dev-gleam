import gleam/option.{None}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import view/ui

pub fn view() -> List(Element(msg)) {
  [
    ui.page_header("About", None),
    ui.content_container([
      ui.simple_paragraph(
        "I'm a software developer focused on modern web technologies, infrastructure, and building reliable systems.",
      ),
      ui.simple_paragraph(
        "If you enjoy these glimpses into my mind, feel free to come back semi-regularly. But not too regularly, don't be a creep.",
      ),
    ]),
  ]
}
