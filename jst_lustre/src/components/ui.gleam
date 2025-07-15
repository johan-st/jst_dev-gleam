import gleam/option.{type Option, None, Some}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// LOADING STATES -------------------------------------------------------------

pub fn loading_spinner() -> Element(msg) {
  html.div([attr.class("loading-spinner")], [])
}

pub fn loading_spinner_large() -> Element(msg) {
  html.div([attr.class("loading-spinner loading-spinner-lg")], [])
}

pub fn skeleton_text(width_class: String) -> Element(msg) {
  html.div([attr.class("skeleton-text " <> width_class)], [])
}

pub fn skeleton_title() -> Element(msg) {
  html.div([attr.class("skeleton-title w-3/4")], [])
}

// Minimal loading indicators for subtle loading states
pub fn loading_indicator_inline() -> Element(msg) {
  html.div([attr.class("inline-flex items-center text-zinc-500 text-sm")], [
    html.div([attr.class("loading-spinner mr-2")], []),
    html.span([], [html.text("Loading...")]),
  ])
}

pub fn loading_indicator_small() -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-4")], [
    html.div([attr.class("flex items-center text-zinc-400 text-sm")], [
      html.div([attr.class("loading-spinner mr-2")], []),
      html.span([], [html.text("Loading content...")]),
    ]),
  ])
}

pub fn loading_indicator_subtle() -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-8")], [
    html.div([attr.class("text-zinc-500 text-sm")], [html.text("Loading...")]),
  ])
}

pub fn loading_indicator_bar() -> Element(msg) {
  html.div([attr.class("w-full bg-zinc-800 rounded-full h-1 mb-4")], [
    html.div([attr.class("bg-pink-600 h-1 rounded-full loading-bar")], []),
  ])
}

pub fn loading_state(message: String) -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-12")], [
    html.div([attr.class("flex flex-col items-center space-y-4")], [
      loading_spinner_large(),
      html.p([attr.class("text-zinc-400")], [html.text(message)]),
    ]),
  ])
}

// ERROR STATES ---------------------------------------------------------------

pub type ErrorType {
  ErrorNetwork
  ErrorNotFound
  ErrorPermission
  ErrorGeneric
}

pub fn error_state(
  error_type: ErrorType,
  title: String,
  message: String,
  retry_action: Option(msg),
) -> Element(msg) {
  let icon_class = case error_type {
    ErrorNetwork -> "text-orange-400"
    ErrorNotFound -> "text-blue-400"
    ErrorPermission -> "text-red-400"
    ErrorGeneric -> "text-yellow-400"
  }

  html.div(
    [attr.class("flex flex-col items-center justify-center py-12 text-center")],
    [
      html.div([attr.class("mb-4")], [
        html.div([attr.class("w-16 h-16 mx-auto mb-4 " <> icon_class)], [
          case error_type {
            ErrorNetwork -> html.text("🌐")
            ErrorNotFound -> html.text("🔍")
            ErrorPermission -> html.text("🔒")
            ErrorGeneric -> html.text("⚠️")
          },
        ]),
      ]),
      html.h3([attr.class("text-xl font-medium text-zinc-200 mb-2")], [
        html.text(title),
      ]),
      html.p([attr.class("text-zinc-400 mb-6 max-w-md")], [html.text(message)]),
      case retry_action {
        Some(action) ->
          html.button([attr.class("btn-secondary"), event.on_click(action)], [
            html.text("Try Again"),
          ])
        None -> element.none()
      },
    ],
  )
}

// BUTTONS --------------------------------------------------------------------

pub fn button_primary(
  text: String,
  disabled: Bool,
  loading: Bool,
  onclick: msg,
) -> Element(msg) {
  html.button(
    [
      attr.class("btn-primary"),
      attr.disabled(disabled),
      event.on_click(onclick),
    ],
    case loading {
      True -> [
        loading_spinner(),
        html.span([attr.class("ml-2")], [html.text(text)]),
      ]
      False -> [html.text(text)]
    },
  )
}

pub fn button_secondary(
  text: String,
  disabled: Bool,
  onclick: msg,
) -> Element(msg) {
  html.button(
    [
      attr.class("btn-secondary"),
      attr.disabled(disabled),
      event.on_click(onclick),
    ],
    [html.text(text)],
  )
}

pub fn button_danger(
  text: String,
  disabled: Bool,
  loading: Bool,
  onclick: msg,
) -> Element(msg) {
  html.button(
    [attr.class("btn-danger"), attr.disabled(disabled), event.on_click(onclick)],
    case loading {
      True -> [
        loading_spinner(),
        html.span([attr.class("ml-2")], [html.text(text)]),
      ]
      False -> [html.text(text)]
    },
  )
}

// FORMS ----------------------------------------------------------------------

pub fn form_input(
  label: String,
  value: String,
  placeholder: String,
  input_type: String,
  required: Bool,
  error: Option(String),
  oninput: fn(String) -> msg,
) -> Element(msg) {
  html.div([attr.class("mb-4")], [
    html.label([attr.class("form-label")], [
      html.text(label),
      case required {
        True -> html.span([attr.class("text-red-400 ml-1")], [html.text("*")])
        False -> element.none()
      },
    ]),
    html.input([
      attr.class(case error {
        Some(_) ->
          "form-input border-red-500 focus:border-red-500 focus:ring-red-500/20"
        None -> "form-input"
      }),
      attr.type_(input_type),
      attr.value(value),
      attr.placeholder(placeholder),
      attr.required(required),
      event.on_input(oninput),
    ]),
    case error {
      Some(error_msg) ->
        html.p([attr.class("form-error")], [html.text(error_msg)])
      None -> element.none()
    },
  ])
}

pub fn form_textarea(
  label: String,
  value: String,
  placeholder: String,
  rows: Int,
  required: Bool,
  error: Option(String),
  oninput: fn(String) -> msg,
) -> Element(msg) {
  html.div([attr.class("mb-4")], [
    html.label([attr.class("form-label")], [
      html.text(label),
      case required {
        True -> html.span([attr.class("text-red-400 ml-1")], [html.text("*")])
        False -> element.none()
      },
    ]),
    html.textarea(
      [
        attr.class(case error {
          Some(_) ->
            "form-input border-red-500 focus:border-red-500 focus:ring-red-500/20 resize-none"
          None -> "form-input resize-none"
        }),
        attr.value(value),
        attr.placeholder(placeholder),
        attr.required(required),
        attr.rows(rows),
        event.on_input(oninput),
      ],
      value,
    ),
    case error {
      Some(error_msg) ->
        html.p([attr.class("form-error")], [html.text(error_msg)])
      None -> element.none()
    },
  ])
}

// NOTIFICATIONS --------------------------------------------------------------

pub type ToastType {
  ToastSuccess
  ToastError
  ToastWarning
  ToastInfo
}

pub fn toast(
  toast_type: ToastType,
  title: String,
  message: String,
  onclose: msg,
) -> Element(msg) {
  let type_classes = case toast_type {
    ToastSuccess -> "toast-success"
    ToastError -> "toast-error"
    ToastWarning -> "toast-warning"
    ToastInfo -> ""
  }

  html.div([attr.class("toast " <> type_classes)], [
    html.div([attr.class("flex justify-between items-start")], [
      html.div([attr.class("flex-1")], [
        html.h4([attr.class("font-medium text-zinc-100 mb-1")], [
          html.text(title),
        ]),
        html.p([attr.class("text-zinc-300 text-sm")], [html.text(message)]),
      ]),
      html.button(
        [
          attr.class("ml-4 text-zinc-400 hover:text-zinc-200 transition-colors"),
          event.on_click(onclose),
          attr.attribute("aria-label", "Close notification"),
        ],
        [html.text("×")],
      ),
    ]),
  ])
}

// MODALS ---------------------------------------------------------------------

pub fn modal_backdrop(onclose: msg) -> Element(msg) {
  html.div([attr.class("modal-backdrop"), event.on_click(onclose)], [])
}

pub fn modal(
  title: String,
  content: List(Element(msg)),
  actions: List(Element(msg)),
  onclose: msg,
) -> Element(msg) {
  html.div([attr.class("modal-content")], [
    html.div(
      [
        attr.class(
          "bg-zinc-800 border border-zinc-700 rounded-lg shadow-xl max-w-md w-full mx-4",
        ),
      ],
      [
        // Header
        html.div(
          [
            attr.class(
              "flex items-center justify-between p-6 border-b border-zinc-700",
            ),
          ],
          [
            html.h2([attr.class("text-lg font-medium text-zinc-100")], [
              html.text(title),
            ]),
            html.button(
              [
                attr.class(
                  "text-zinc-400 hover:text-zinc-200 transition-colors",
                ),
                event.on_click(onclose),
                attr.attribute("aria-label", "Close modal"),
              ],
              [html.text("×")],
            ),
          ],
        ),
        // Content
        html.div([attr.class("p-6")], content),
        // Actions
        case actions {
          [] -> element.none()
          _ ->
            html.div(
              [
                attr.class(
                  "flex justify-end space-x-3 p-6 border-t border-zinc-700",
                ),
              ],
              actions,
            )
        },
      ],
    ),
  ])
}

// CARDS ----------------------------------------------------------------------

pub fn card(content: List(Element(msg))) -> Element(msg) {
  html.div([attr.class("card")], content)
}

pub fn card_interactive(
  content: List(Element(msg)),
  onclick: msg,
) -> Element(msg) {
  html.div(
    [attr.class("card card-interactive"), event.on_click(onclick)],
    content,
  )
}

// EMPTY STATES ---------------------------------------------------------------

pub fn empty_state(
  title: String,
  message: String,
  action: Option(Element(msg)),
) -> Element(msg) {
  html.div([attr.class("text-center py-12")], [
    html.div([attr.class("text-6xl mb-4")], [html.text("📝")]),
    html.h3([attr.class("text-xl font-medium text-zinc-300 mb-2")], [
      html.text(title),
    ]),
    html.p([attr.class("text-zinc-400 mb-6 max-w-md mx-auto")], [
      html.text(message),
    ]),
    case action {
      Some(button) -> button
      None -> element.none()
    },
  ])
}
