import chat.{type ChatMessage}
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import sync
import utils/mouse
import view/ui

pub fn view(
  room_id room_id: String,
  messages sub_messages: sync.Subscription(ChatMessage),
  user_name user_name: Option(String),
  on_set_name on_set_name: fn(String) -> msg,
) -> List(Element(msg)) {
  let header = ui.page_title("Room: " <> room_id, "chat-room-title")

  // Show name prompt if no name set
  let name_prompt = case user_name {
    None -> [
      html.div(
        [attr.class("mb-4 p-4 bg-yellow-100 rounded border border-yellow-300")],
        [
          html.p([attr.class("mb-2 text-yellow-800 font-medium")], [
            html.text("Enter your name to join the chat:"),
          ]),
          html.input([
            attr.class(
              "w-full p-2 border border-yellow-300 rounded focus:outline-none focus:ring-2 focus:ring-yellow-500",
            ),
            attr.placeholder("Your name"),
            attr.id("user-name-input"),
          ]),
          html.button(
            [
              attr.class(
                "mt-2 bg-yellow-500 hover:bg-yellow-600 text-white px-4 py-2 rounded transition-colors",
              ),
              mouse.on_mouse_down_no_right(on_set_name("")),
              // Will be updated with actual input value
            ],
            [html.text("Join Chat")],
          ),
        ],
      ),
    ]
    Some(name) -> [
      html.div(
        [attr.class("mb-4 p-2 bg-green-100 rounded border border-green-300")],
        [
          html.p([attr.class("text-green-800")], [
            html.text("Joined as: " <> name),
          ]),
        ],
      ),
    ]
  }

  let items =
    sub_messages.data
    |> list.map(fn(msg) {
      ui.card(msg.id, [
        html.div([], [
          html.div([attr.class("text-sm text-zinc-400")], [
            html.text("User: " <> msg.user_id),
          ]),
          html.p([attr.class("mt-1")], [html.text(msg.content)]),
        ]),
      ])
    })

  [
    ui.flex_between(header, html.div([], [])),
    ui.content_container(name_prompt),
    ui.content_container(items),
  ]
}
