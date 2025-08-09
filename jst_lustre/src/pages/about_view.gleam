import components/ui
import gleam/option.{None}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> List(Element(msg)) {
  [
    ui.page_header("About", None),
    ui.content_container([
      html.p([attr.class("text-zinc-300")], [
        html.text(
          "I'm a software developer and a writer. I'm also a father and a husband. "
          <> "I'm also a software developer and a writer. I'm also a father and a "
          <> "husband. I'm also a software developer and a writer. I'm also a "
          <> "father and a husband. I'm also a software developer and a writer. "
          <> "I'm also a father and a husband.",
        ),
      ]),
      html.p([attr.class("text-zinc-300")], [
        html.text(
          "If you enjoy these glimpses into my mind, feel free to come back "
          <> "semi-regularly. But not too regularly, you creep.",
        ),
      ]),
    ]),
  ]
}
