import components/ui
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import view/common
import gleam/option.{None}

pub type Callbacks(msg) {
  Callbacks(
    on_title: fn(String) -> msg,
    on_message: fn(String) -> msg,
    on_category: fn(String) -> msg,
    on_priority: fn(String) -> msg,
    on_ntfy_topic: fn(String) -> msg,
    on_send: msg,
  )
}

pub fn view(
  notification_form_title: String,
  notification_form_message: String,
  notification_form_category: String,
  notification_form_priority: String,
  notification_form_ntfy_topic: String,
  notification_sending: Bool,
  cbs: Callbacks(msg),
) -> List(Element(msg)) {
  [
    common.title("Send Notification", "notifications"),
    common.simple_paragraph(
      "Send push notifications to your devices via ntfy.sh. Configure your ntfy topic to receive notifications on your mobile device or desktop.",
    ),
    view_help(),
    view_form(
      notification_form_title,
      notification_form_message,
      notification_form_category,
      notification_form_priority,
      notification_form_ntfy_topic,
      notification_sending,
      cbs,
    ),
  ]
}

fn view_help() -> Element(msg) {
  html.div(
    [attr.class("mt-6 p-4 bg-teal-900/30 border border-teal-600/40 rounded-lg")],
    [
      html.h4([attr.class("text-teal-400 font-medium mb-2")], [
        html.text("How to use:"),
      ]),
      html.ul([attr.class("text-sm text-zinc-300 space-y-1")], [
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Download the ntfy app on your phone or subscribe to a topic on ntfy.sh",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Enter your custom topic or leave empty to use your default user topic",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Choose priority: Low (silent), Normal (default sound), High (louder), Urgent (critical alert)",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Categories help organize your notifications (e.g., 'system', 'alerts', 'reminders')",
          ),
        ]),
      ]),
    ],
  )
}

fn view_form(
  notification_form_title: String,
  notification_form_message: String,
  notification_form_category: String,
  notification_form_priority: String,
  notification_form_ntfy_topic: String,
  notification_sending: Bool,
  cbs: Callbacks(msg),
) -> Element(msg) {
  html.div(
    [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
    [
      html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
        html.text("Send Notification"),
      ]),
      html.div([attr.class("space-y-4")], [
        ui.form_input(
          "Title",
          notification_form_title,
          "Enter notification title",
          "text",
          True,
          None,
          cbs.on_title,
        ),
        ui.form_input(
          "Message",
          notification_form_message,
          "Enter notification message",
          "text",
          True,
          None,
          cbs.on_message,
        ),
        ui.form_input(
          "Category",
          notification_form_category,
          "e.g., system, alerts, reminders, info",
          "text",
          True,
          None,
          cbs.on_category,
        ),
        html.div([attr.class("space-y-2")], [
          html.label([attr.class("block text-sm font-medium text-zinc-400")], [
            html.text("Priority"),
          ]),
          html.select(
            [
              attr.class(
                "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
              ),
              event.on_input(cbs.on_priority),
            ],
            [
              html.option([
                attr.value("low"),
                attr.selected(notification_form_priority == "low"),
              ], "Low"),
              html.option([
                attr.value("normal"),
                attr.selected(notification_form_priority == "normal"),
              ], "Normal"),
              html.option([
                attr.value("high"),
                attr.selected(notification_form_priority == "high"),
              ], "High"),
              html.option([
                attr.value("urgent"),
                attr.selected(notification_form_priority == "urgent"),
              ], "Urgent"),
            ],
          ),
        ]),
        ui.form_input(
          "Ntfy Topic (optional)",
          notification_form_ntfy_topic,
          "Custom topic name or leave empty for user_{your_id}",
          "text",
          False,
          None,
          cbs.on_ntfy_topic,
        ),
        ui.button(
          case notification_sending {
            True -> "Sending..."
            False -> "Send Notification"
          },
          ui.ColorTeal,
          case notification_sending, notification_form_title == "" || notification_form_message == "" || notification_form_category == "" {
            True, _ -> ui.ButtonStatePending
            False, True -> ui.ButtonStateDisabled
            _, _ -> ui.ButtonStateNormal
          },
          cbs.on_send,
        ),
      ]),
    ],
  )
}

