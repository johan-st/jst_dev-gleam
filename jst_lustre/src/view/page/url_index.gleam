import gleam/option.{None}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import view/ui

pub fn view(list: Element(msg)) -> List(Element(msg)) {
  [
    ui.page_header("URL Shortener", None),
    ui.content_container([
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [
          html.text("Create and manage short URLs for easy sharing."),
        ]),
      ]),
      list,
    ]),
  ]
}
