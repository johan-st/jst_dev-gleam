import article.{type Article}
import gleam/dict
import gleam/int
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import sync
import utils/short_url.{type ShortUrl}
import view/ui

pub fn view(
  kv_article: sync.KV(String, Article),
  kv_short_url: sync.KV(String, ShortUrl),
) -> List(Element(msg)) {
  let header =
    ui.flex_between(
      ui.page_title("Debug", "debug-title"),
      html.div([attr.class("flex items-center gap-3")], [
        // Articles KV status
        case kv_article.state {
          sync.NotInitialized ->
            ui.status_badge("Articles: Not initialized", ui.ColorNeutral)
          sync.Connecting ->
            ui.status_badge("Articles: Connecting", ui.ColorTeal)
          sync.CatchingUp ->
            ui.status_badge("Articles: Catching up", ui.ColorOrange)
          sync.InSync -> ui.status_badge("Articles: In sync", ui.ColorGreen)
          sync.KVError(_) -> ui.status_badge("Articles: Error", ui.ColorRed)
        },
        // Short URL KV status
        case kv_short_url.state {
          sync.NotInitialized ->
            ui.status_badge("URLs: Not initialized", ui.ColorNeutral)
          sync.Connecting -> ui.status_badge("URLs: Connecting", ui.ColorTeal)
          sync.CatchingUp ->
            ui.status_badge("URLs: Catching up", ui.ColorOrange)
          sync.InSync -> ui.status_badge("URLs: In sync", ui.ColorGreen)
          sync.KVError(_) -> ui.status_badge("URLs: Error", ui.ColorRed)
        },
      ]),
    )

  let total_messages = kv_article.message_count + kv_short_url.message_count
  let total_stats = ui.card_with_title("total-stats", "Total Messages", [
    html.div([], [
      html.p([], [
        html.text("Total Messages: " <> { total_messages |> int.to_string }),
      ]),
      html.p([], [
        html.text("Articles Messages: " <> { kv_article.message_count |> int.to_string }),
      ]),
      html.p([], [
        html.text("URL Messages: " <> { kv_short_url.message_count |> int.to_string }),
      ]),
    ]),
  ])

  let article_stats =
    ui.card_with_title("kv-articles", "Articles KV", [
      html.div([], [
        html.p([], [html.text("Bucket: " <> kv_article.bucket)]),
        html.p([], [
          html.text(
            "Items: " <> { kv_article.data |> dict.size |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text("Revision: " <> { kv_article.revision |> int.to_string }),
        ]),
        html.p([], [
          html.text("Messages: " <> { kv_article.message_count |> int.to_string }),
        ]),
      ]),
    ])

  let url_stats =
    ui.card_with_title("kv-shorturls", "Short URLs KV", [
      html.div([], [
        html.p([], [html.text("Bucket: " <> kv_short_url.bucket)]),
        html.p([], [
          html.text(
            "Items: " <> { kv_short_url.data |> dict.size |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text("Revision: " <> { kv_short_url.revision |> int.to_string }),
        ]),
        html.p([], [
          html.text("Messages: " <> { kv_short_url.message_count |> int.to_string }),
        ]),
      ]),
    ])

  [header, ui.content_container([total_stats, article_stats, url_stats])]
}
