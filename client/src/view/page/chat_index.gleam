import chat.{type ChatRoom}
import gleam/dict
import gleam/list
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import routes
import sync
import utils/mouse
import view/ui

pub fn view(
  rooms kv_rooms: sync.KV(String, ChatRoom),
  on_nav_to on_nav_to: fn(uri.Uri) -> msg,
  on_request_chat on_request_chat: msg,
) -> List(Element(msg)) {
  let header = ui.page_title("Chat Rooms", "chat-rooms-title")

  // Add request chat button to header
  let request_button =
    html.button(
      [
        attr.class(
          "bg-pink-500 hover:bg-pink-600 text-white px-4 py-2 rounded transition-colors",
        ),
        mouse.on_mouse_down_no_right(on_request_chat),
      ],
      [html.text("Request Chat")],
    )

  let header_with_button = ui.flex_between(header, request_button)

  let room_items =
    kv_rooms.data
    |> dict.values
    |> list.map(fn(room) {
      let room_uri = routes.to_uri(routes.ChatRoom(room.id))
      ui.card(room.id, [
        html.div([], [
          html.h3([attr.class("text-lg font-semibold mb-1")], [
            html.text(case room.public {
              True -> "Public"
              False -> "Private"
            }),
          ]),
          html.p([attr.class("text-pink-800 mb-2")], [
            html.text("Room Name: " <> room.name),
          ]),
          html.p([attr.class("text-zinc-400 text-sm mb-2")], [
            html.text("Room ID: " <> room.id),
          ]),
          html.div([], [
            html.button(
              [
                attr.class("text-pink-500 hover:text-pink-400 underline"),
                mouse.on_mouse_down_no_right(on_nav_to(room_uri)),
              ],
              [html.text("Open room →")],
            ),
          ]),
        ]),
      ])
    })

  [header_with_button, ui.content_container(room_items)]
}
