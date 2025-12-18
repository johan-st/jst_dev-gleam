import gleam/option.{Some}
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import view/ui

pub fn view(msg_nav_to: fn(uri.Uri) -> msg) -> List(Element(msg)) {
  let assert Ok(nats_uri) = uri.parse("/article/nats-all-the-way-down")
  [
    ui.page_header(
      "Welcome to jst.dev!",
      Some(
        "...or, A lesson on overengineering for fun and... well just for fun.",
      ),
    ),
    ui.content_container([
      html.div([attr.class("prose prose-lg text-zinc-300 max-w-none")], [
        html.p([attr.class("text-xl leading-relaxed mb-8")], [
          html.text(
            "This site and its underlying IT infrastructure is the primary 
            place for me to experiment with technologies and topologies. I 
            also share some of my thoughts and learnings here. Feel free to 
            check out my overview: ",
          ),
          ui.link_primary("NATS all the way down →", msg_nav_to(nats_uri)),
        ]),
        html.p([attr.class("mb-6")], [
          html.text(
            "It too is a work in progress and I mostly keep it here for my own reference.",
          ),
        ]),
      ]),
    ]),
  ]
}
