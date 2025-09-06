import article.{type Article}
import birl
import chat.{type ChatMessage, type ChatRoom, type TimeMsg, TimeMsg}
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import sync.{type KV, type Subscription, type SyncState}
import utils/short_url.{type ShortUrl}
import view/ui

pub fn view(
  kv_article: sync.KV(String, Article),
  kv_short_url: sync.KV(String, ShortUrl),
  sub_time: sync.Subscription(TimeMsg),
  kv_chat_room: sync.KV(String, ChatRoom),
  sub_chat_message: sync.Subscription(ChatMessage),
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
        // Chat room KV status
        case kv_chat_room.state {
          sync.NotInitialized ->
            ui.status_badge("Chat rooms: Not initialized", ui.ColorNeutral)
          sync.Connecting ->
            ui.status_badge("Chat rooms: Connecting", ui.ColorTeal)
          sync.CatchingUp ->
            ui.status_badge("Chat rooms: Catching up", ui.ColorOrange)
          sync.InSync -> ui.status_badge("Chat rooms: In sync", ui.ColorGreen)
          sync.KVError(_) -> ui.status_badge("Chat rooms: Error", ui.ColorRed)
        },
        // Chat message subscription status
        case sub_chat_message.state {
          sync.NotInitialized ->
            ui.status_badge("Chat messages: Not initialized", ui.ColorNeutral)
          sync.Connecting ->
            ui.status_badge("Chat messages: Connecting", ui.ColorTeal)
          sync.CatchingUp ->
            ui.status_badge("Chat messages: Catching up", ui.ColorOrange)
          sync.InSync ->
            ui.status_badge("Chat messages: In sync", ui.ColorGreen)
          sync.KVError(_) ->
            ui.status_badge("Chat messages: Error", ui.ColorRed)
        },
        // Time subscription status
        case sub_time.state {
          sync.NotInitialized ->
            ui.status_badge("Time: Not initialized", ui.ColorNeutral)
          sync.Connecting -> ui.status_badge("Time: Connecting", ui.ColorTeal)
          sync.CatchingUp ->
            ui.status_badge("Time: Catching up", ui.ColorOrange)
          sync.InSync -> ui.status_badge("Time: In sync", ui.ColorGreen)
          sync.KVError(_) -> ui.status_badge("Time: Error", ui.ColorRed)
        },
      ]),
    )

  let total_messages = kv_article.message_count + kv_short_url.message_count
  let total_stats =
    ui.card_with_title("total-stats", "Total Messages", [
      html.div([], [
        html.p([], [
          html.text("Total Messages: " <> { total_messages |> int.to_string }),
        ]),
        html.p([], [
          html.text(
            "Articles Messages: "
            <> { kv_article.message_count |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text(
            "URL Messages: " <> { kv_short_url.message_count |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text(
            "Chat room Messages: "
            <> { kv_chat_room.message_count |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text(
            "Chat message Messages: "
            <> { sub_chat_message.message_count |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text(
            "Time Messages: " <> { sub_time.message_count |> int.to_string },
          ),
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
          html.text(
            "Messages: " <> { kv_article.message_count |> int.to_string },
          ),
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
          html.text(
            "Messages: " <> { kv_short_url.message_count |> int.to_string },
          ),
        ]),
      ]),
    ])

  let chat_room_stats =
    ui.card_with_title("kv-chat-rooms", "Chat Rooms KV", [
      html.div([], [
        html.p([], [html.text("Bucket: " <> kv_chat_room.bucket)]),
        html.p([], [
          html.text(
            "Items: " <> { kv_chat_room.data |> dict.size |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text("Revision: " <> { kv_chat_room.revision |> int.to_string }),
        ]),
        html.p([], [
          html.text(
            "Messages: " <> { kv_chat_room.message_count |> int.to_string },
          ),
        ]),
      ]),
    ])

  let chat_message_stats =
    ui.card_with_title("sub-chat-messages", "Chat Messages Subscription", [
      html.div([], [
        html.p([], [html.text("Subject: " <> sub_chat_message.subject)]),
        html.p([], [
          html.text(
            "Messages: " <> { sub_chat_message.message_count |> int.to_string },
          ),
        ]),
        html.p([], [
          html.text(
            "latest: "
            <> {
              sub_chat_message.data
              |> list.first
              |> result.map(fn(t) { t.id })
              |> result.unwrap("-")
            },
          ),
        ]),
        html.p([], [
          html.text(
            "Error: " <> { sub_chat_message.error |> option.unwrap("-") },
          ),
        ]),
      ]),
    ])
  let time_stats =
    ui.card_with_title("sub-time", "Time Subscription", [
      html.div([], [
        html.p([], [html.text("Subject: " <> sub_time.subject)]),
        html.p([], [
          html.text("Messages: " <> { sub_time.message_count |> int.to_string }),
        ]),
        html.p([], [
          html.text("Error: " <> { sub_time.error |> option.unwrap("") }),
        ]),
        html.ul(
          [],
          sub_time.data
            |> list.take(5)
            |> list.map(fn(t) {
              html.li([], [
                html.text(
                  t.unix_milli
                  |> birl.from_unix_milli
                  |> birl.to_naive_time_string,
                ),
                html.text(" " <> t.fly_app_name),
                html.text("@" <> t.fly_region |> string.uppercase),
              ])
            }),
        ),
      ]),
    ])

  [
    header,
    ui.content_container([
      total_stats,
      article_stats,
      url_stats,
      chat_room_stats,
      chat_message_stats,
      time_stats,
    ]),
  ]
}
