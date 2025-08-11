import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import utils/mouse

pub fn title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class(
        "text-2xl sm:text-3xl sm:h-10 md:text-4xl md:h-12 font-bold text-pink-700",
      ),
    ],
    [html.text(title)],
  )
}

pub fn subtitle(text: String, slug: String) -> Element(msg) {
  html.div([attr.id("article-subtitle-" <> slug), attr.class("page-subtitle")], [
    html.text(text),
  ])
}

pub fn simple_paragraph(text: String) -> Element(msg) {
  html.p([attr.class("pt-8")], [html.text(text)])
}

pub fn internal_link(
  to: uri.Uri,
  content: List(Element(msg)),
  on_mousedown: msg,
) -> Element(msg) {
  html.a(
    [attr.class(""), attr.href(uri.to_string(to)), mouse.on_mouse_down_no_right(on_mousedown)],
    content,
  )
}

