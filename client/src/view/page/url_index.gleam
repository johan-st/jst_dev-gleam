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
  [
    ui.flex_between(
      ui.page_title("URL Shortener", "url-shortener-title"),
      html.div([attr.class("flex items-center gap-3")], [
        case kv.state {
          sync.NotInitialized ->
            ui.status_badge("Not initialized", ui.ColorNeutral)
          sync.Connecting -> ui.status_badge("Connecting", ui.ColorTeal)
          sync.CatchingUp -> ui.status_badge("Catching up", ui.ColorOrange)
          sync.InSync -> ui.status_badge("In sync", ui.ColorGreen)
          sync.KVError(_) -> ui.status_badge("Error", ui.ColorRed)
        },
      ]),
    ),
    ui.content_container([list]),
  ]
}
