import gleam/option.{type Option, None, Some}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// LOADING STATES -------------------------------------------------------------

pub fn loading_spinner() -> Element(msg) {
  html.div(
    [
      attr.class(
        "loading-spinner inline-block w-4 h-4 border-2 border-zinc-600 rounded-full",
      ),
    ],
    [],
  )
}

pub fn loading_spinner_large() -> Element(msg) {
  html.div(
    [
      attr.class(
        "loading-spinner w-8 h-8 border-4 border-zinc-600 rounded-full",
      ),
    ],
    [],
  )
}

pub fn loading_indicator_small() -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-8")], [
    html.div([attr.class("flex items-center text-zinc-400 text-sm")], [
      html.div(
        [
          attr.class(
            "loading-spinner inline-block w-4 h-4 border-2 border-zinc-600 rounded-full mr-3",
          ),
        ],
        [],
      ),
      html.span([], [html.text("Loading content...")]),
    ]),
  ])
}

pub fn loading_indicator_subtle() -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-12")], [
    html.div([attr.class("text-zinc-500 text-sm")], [html.text("Loading...")]),
  ])
}

pub fn loading_indicator_bar() -> Element(msg) {
  html.div(
    [attr.class("w-full bg-zinc-800 rounded-full h-2 mb-4 overflow-hidden")],
    [html.div([attr.class("loading-bar h-full rounded-full")], [])],
  )
}

pub fn loading_state(message: String) -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-12 md:py-16")], [
    html.div([attr.class("flex flex-col items-center space-y-6")], [
      loading_spinner_large(),
      html.p([attr.class("text-zinc-400 text-lg")], [html.text(message)]),
    ]),
  ])
}

// PAGE HEADERS ---------------------------------------------------------------

pub fn page_header(title: String, subtitle: Option(String)) -> Element(msg) {
  html.header([attr.class("py-12 md:py-16")], [
    html.h1(
      [
        attr.class(
          "page-title text-3xl sm:text-4xl md:text-5xl font-light leading-tight mb-4",
        ),
      ],
      [html.text(title)],
    ),
    case subtitle {
      Some(sub) ->
        html.p([attr.class("text-lg text-zinc-400 font-light italic mb-8")], [
          html.text(sub),
        ])
      None -> element.none()
    },
  ])
}

pub fn page_title(title: String) -> Element(msg) {
  html.h1(
    [
      attr.class(
        "page-title text-3xl sm:text-4xl md:text-5xl font-light leading-tight mb-4",
      ),
    ],
    [html.text(title)],
  )
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
  let icon = case error_type {
    ErrorNetwork -> "🌐"
    ErrorNotFound -> "🔍"
    ErrorPermission -> "🔒"
    ErrorGeneric -> "⚠️"
  }

  html.div([attr.class("py-12 md:py-16 text-center")], [
    html.div([attr.class("max-w-md mx-auto space-y-6")], [
      html.div([attr.class("text-6xl mb-6")], [html.text(icon)]),
      html.h3([attr.class("text-2xl font-light text-zinc-200 mb-4")], [
        html.text(title),
      ]),
      html.p([attr.class("text-zinc-400 text-lg mb-8")], [html.text(message)]),
      case retry_action {
        Some(action) -> button_secondary("Try Again", False, action)
        None -> element.none()
      },
    ]),
  ])
}

// BUTTONS --------------------------------------------------------------------

pub type ButtonVariant {
  ButtonTeal
  // Neutral/info actions
  ButtonOrange
  // Warning actions  
  ButtonRed
  // Destructive actions
  ButtonGreen
  // Positive actions
}

pub fn button_secondary(
  text: String,
  disabled: Bool,
  onclick: msg,
) -> Element(msg) {
  html.button(
    [
      attr.class(
        "btn-secondary px-6 py-3 text-zinc-200 rounded-lg font-medium transition-all duration-300 ease-out disabled:opacity-50 disabled:cursor-not-allowed",
      ),
      attr.disabled(disabled),
      event.on_click(onclick),
    ],
    [html.text(text)],
  )
}

/// Consistent button for actions with mouse_down events
pub fn button_action(
  text: String,
  variant: ButtonVariant,
  disabled: Bool,
  onmousedown: msg,
) -> Element(msg) {
  let tailwind_classes_active = case variant {
    ButtonTeal ->
      "text-teal-400 border-teal-600 bg-teal-500/10 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400"
    ButtonOrange ->
      "text-orange-400 border-orange-600 bg-orange-500/10 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400"
    ButtonRed ->
      "text-red-400 border-red-600 bg-red-500/10 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400"
    ButtonGreen ->
      "text-green-400 border-green-600 bg-green-500/10 hover:bg-green-950/50 hover:text-green-300 hover:border-green-400"
  }

  let tailwind_classes_inactive = case variant {
    ButtonOrange ->
      "text-orange-400 border-orange-600 bg-orange-500/10 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400"
    ButtonRed ->
      "text-red-400 border-red-600 bg-red-500/10 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400"
    ButtonGreen ->
      "text-green-400 border-green-600 bg-green-500/10 hover:bg-green-950/50 hover:text-green-300 hover:border-green-400"
    ButtonTeal ->
      "text-teal-400 border-teal-600 bg-teal-500/10 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400"
  }
  let tailwind_classes_common =
    "px-4 py-2 border-r border-l transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed"

  html.button(
    [
      attr.classes([
        #(tailwind_classes_common, True),
        #(tailwind_classes_active, !disabled),
        #(tailwind_classes_inactive, disabled),
      ]),
      attr.disabled(disabled),
      event.on_mouse_down(onmousedown),
    ],
    [html.text(text)],
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
  html.div([attr.class("mb-6")], [
    html.label([attr.class("block text-sm font-semibold text-zinc-300 mb-3")], [
      html.text(label),
      case required {
        True -> html.span([attr.class("text-red-400 ml-1")], [html.text("*")])
        False -> element.none()
      },
    ]),
    html.input([
      attr.class(case error {
        Some(_) ->
          "form-input w-full bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 pl-4 pr-4 py-3 text-zinc-100 placeholder-zinc-500 transition-all duration-300 ease-out outline-none border-l-red-500 focus:border-l-red-400 focus:bg-red-500/5"
        None ->
          "form-input w-full bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 pl-4 pr-4 py-3 text-zinc-100 placeholder-zinc-500 transition-all duration-300 ease-out outline-none border-l-teal-600 focus:border-l-teal-400 focus:bg-teal-500/5"
      }),
      attr.type_(input_type),
      attr.value(value),
      attr.placeholder(placeholder),
      attr.required(required),
      event.on_input(oninput),
    ]),
    case error {
      Some(error_msg) ->
        html.p(
          [attr.class("text-red-400 text-sm mt-2 flex items-center gap-1")],
          [
            html.span([attr.class("text-red-400")], [html.text("⚠ ")]),
            html.text(error_msg),
          ],
        )
      None -> element.none()
    },
  ])
}

// MODALS ---------------------------------------------------------------------

pub fn modal_backdrop(onclose: msg) -> Element(msg) {
  html.div(
    [attr.class("modal-backdrop fixed inset-0 z-40"), event.on_click(onclose)],
    [],
  )
}

pub fn modal(
  title: String,
  content: List(Element(msg)),
  actions: List(Element(msg)),
  onclose: msg,
) -> Element(msg) {
  html.div(
    [
      attr.class(
        "modal-content fixed inset-0 z-50 flex items-center justify-center p-4",
      ),
    ],
    [
      html.div(
        [
          attr.class(
            "glass border-l-2 border-teal-600 border-r border-r-zinc-700 border-t border-t-zinc-700 border-b border-b-zinc-700 max-w-md w-full mx-4 overflow-hidden",
          ),
        ],
        [
          // Header
          html.div(
            [
              attr.class(
                "flex items-center justify-between p-6 border-b border-zinc-700/50",
              ),
            ],
            [
              html.h2([attr.class("text-xl font-semibold text-zinc-100")], [
                html.text(title),
              ]),
              html.button(
                [
                  attr.class(
                    "text-zinc-400 hover:text-zinc-200 transition-colors text-2xl",
                  ),
                  event.on_click(onclose),
                  attr.attribute("aria-label", "Close modal"),
                ],
                [html.text("×")],
              ),
            ],
          ),
          // Content
          html.div([attr.class("p-6 space-y-6")], content),
          // Actions
          case actions {
            [] -> element.none()
            _ ->
              html.div(
                [
                  attr.class(
                    "flex justify-end space-x-3 p-6 border-t border-zinc-700/50",
                  ),
                ],
                actions,
              )
          },
        ],
      ),
    ],
  )
}

// EMPTY STATES ---------------------------------------------------------------

pub fn empty_state(
  title: String,
  message: String,
  action: Option(Element(msg)),
) -> Element(msg) {
  html.div([attr.class("py-12 md:py-16 text-center")], [
    html.div([attr.class("max-w-md mx-auto space-y-6")], [
      html.div([attr.class("text-6xl mb-6")], [html.text("📝")]),
      html.h3([attr.class("text-2xl font-light text-zinc-300 mb-4")], [
        html.text(title),
      ]),
      html.p([attr.class("text-zinc-400 text-lg mb-8")], [html.text(message)]),
      case action {
        Some(button) -> button
        None -> element.none()
      },
    ]),
  ])
}

// LINKS ----------------------------------------------------------------------

pub fn link_primary(text: String, onclick: msg) -> Element(msg) {
  html.button(
    [
      attr.class(
        "text-pink-500 hover:text-pink-400 transition-colors duration-200 underline decoration-pink-500/30 hover:decoration-pink-400 underline-offset-2",
      ),
      event.on_click(onclick),
    ],
    [html.text(text)],
  )
}

// LAYOUT HELPERS -------------------------------------------------------------

pub fn content_container(content: List(Element(msg))) -> Element(msg) {
  html.div([attr.class("space-y-6")], content)
}

pub fn flex_between(left: Element(msg), right: Element(msg)) -> Element(msg) {
  html.div([attr.class("flex items-center justify-between")], [left, right])
}

pub fn flex_center(content: List(Element(msg))) -> Element(msg) {
  html.div([attr.class("flex items-center justify-center")], content)
}

// MODERN UTILITIES -----------------------------------------------------------

pub fn gradient_text(text: String) -> Element(msg) {
  html.span([attr.class("gradient-text")], [html.text(text)])
}

pub fn glass_panel(content: List(Element(msg))) -> Element(msg) {
  html.div([attr.class("glass rounded-xl p-6")], content)
}
