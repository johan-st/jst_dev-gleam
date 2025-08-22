import gleam/dict
import gleam/option.{type Option, None}
import gleam/set.{type Set}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import sync
import utils/short_url.{type ShortUrl}
import view/page/url_list.{type Callbacks}
import view/ui

pub fn view(
  kv_url kv: sync.KV(String, ShortUrl),
  callbacks cb: Callbacks(msg),
  expanded_urls expanded: Set(String),
  delete_confirmation delete_confirmation: Option(#(String, msg)),
  copy_feedback copy_feedback: option.Option(String),
) -> List(Element(msg)) {
  let intro = case kv.state {
    sync.NotInitialized ->
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [
          html.text("url index not initialized"),
        ]),
      ])
    sync.Connecting ->
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [
          html.text("url index connecting"),
        ]),
      ])
    sync.CatchingUp ->
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [
          html.text("url index catching up"),
        ]),
      ])
    sync.InSync ->
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [html.text("url index in sync")]),
      ])
    sync.KVError(_error) ->
      ui.card("url-intro", [
        html.p([attr.class("text-zinc-300")], [html.text("url index error")]),
      ])
  }

  let list =
    url_list.list(
      kv.data |> dict.values,
      expanded,
      delete_confirmation,
      copy_feedback,
      cb,
    )
  //TODO: add list of urls
  // todo as "url index list: add list of urls" 
  [ui.page_header("URL Shortener", None), ui.content_container([intro])]
}
