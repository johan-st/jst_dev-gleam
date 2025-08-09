import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute as attr
import lustre/element.{type Element, none as element_none}
import lustre/element/html
import lustre/event
import utils/mouse

// TYPES ---------------------------------------------------------------------

pub type Color {
  ColorNeutral
  ColorPink
  ColorTeal
  ColorOrange
  ColorRed
  ColorGreen
}

pub type Style {
  Subtle(Color)
  Accent(Color, Color)
}

// LOADING STATES ------------------------------------------------------------

pub fn loading(text: String, color: Color) -> Element(msg) {
  let base_classes = case color {
    ColorNeutral -> "text-zinc-400 bg-zinc-500/10 sheen-neutral"
    ColorPink -> "text-pink-400 bg-pink-500/10 sheen-pink"
    ColorTeal -> "text-teal-400 bg-teal-500/10 sheen-teal"
    ColorOrange -> "text-orange-400 bg-orange-500/10 sheen-orange"
    ColorRed -> "text-red-400 bg-red-500/10 sheen-red"
    ColorGreen -> "text-green-400 bg-green-500/10 sheen-green"
  }

  html.div(
    [
      attr.class(
        "inline-flex items-center justify-center text-center  overflow-hidden relative px-4 py-2 text-sm "
        <> base_classes,
      ),
      attr.attribute("aria-label", text),
      attr.attribute("role", "status"),
    ],
    [html.text(text)],
  )
}

/// Loading indicator bar with sheen effect like pending buttons
pub fn loading_bar(color: Color) -> Element(msg) {
  let bar_classes = case color {
    ColorNeutral -> "bg-zinc-500/20 sheen-neutral"
    ColorPink -> "bg-pink-500/20 sheen-pink"
    ColorTeal -> "bg-teal-500/20 sheen-teal"
    ColorOrange -> "bg-orange-500/20 sheen-orange"
    ColorRed -> "bg-red-500/20 sheen-red"
    ColorGreen -> "bg-green-500/20 sheen-green"
  }

  html.div([attr.class("w-full bg-zinc-800 h-2 mb-4 overflow-hidden")], [
    html.div(
      [attr.class("h-full relative overflow-hidden " <> bar_classes)],
      [],
    ),
  ])
}

/// Full loading state with text, message, and optional subtitle
pub fn loading_state(
  message: String,
  subtitle: Option(String),
  color: Color,
) -> Element(msg) {
  html.div([attr.class("flex items-center justify-center py-12 md:py-16")], [
    html.div(
      [attr.class("flex flex-col items-center space-y-6 text-center max-w-md")],
      [
        loading(message, color),
        case subtitle {
          Some(sub) ->
            html.p([attr.class("text-zinc-500 text-sm")], [html.text(sub)])
          None -> element_none()
        },
      ],
    ),
  ])
}

// PAGE HEADERS ---------------------------------------------------------------

pub fn page_header(title: String, subtitle: Option(String)) -> Element(msg) {
  html.header([attr.class("py-12 md:py-16")], [
    html.h1(
      [
        attr.class(
          "bg-gradient-to-tr from-pink-800 via-pink-700 to-pink-500 bg-clip-text text-transparent text-3xl sm:text-4xl md:text-5xl font-light leading-tight mb-4",
        ),
      ],
      [html.text(title)],
    ),
    case subtitle {
      Some(sub) ->
        html.p([attr.class("text-lg text-zinc-400 font-light italic mb-8")], [
          html.text(sub),
        ])
      None -> element_none()
    },
  ])
}

pub fn page_title(title: String) -> Element(msg) {
  html.h1(
    [
      attr.class(
        "bg-gradient-to-tr from-pink-800 via-pink-700 to-pink-500 bg-clip-text text-transparent text-3xl sm:text-4xl md:text-5xl font-light leading-tight mb-4",
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
        Some(action) ->
          button("Try Again", ColorTeal, ButtonStateNormal, action)
        None -> element_none()
      },
    ]),
  ])
}

// BUTTONS --------------------------------------------------------------------

pub type ButtonState {
  ButtonStateNormal
  ButtonStatePending
  ButtonStateDisabled
}

/// Menu-style button for dropdowns and navigation
pub fn button_menu(
  text: String,
  variant: Color,
  state: ButtonState,
  onclick: msg,
) -> Element(msg) {
  let tailwind_classes = case variant, state {
    ColorNeutral, ButtonStateNormal ->
      "text-zinc-400 border-zinc-600 hover:bg-zinc-950/50 hover:text-zinc-300 hover:border-zinc-400 cursor-pointer"
    ColorNeutral, ButtonStatePending ->
      "text-zinc-400 border-zinc-600 opacity-70 cursor-wait sheen-neutral overflow-hidden relative"
    ColorNeutral, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorPink, ButtonStateNormal ->
      "text-pink-400 border-pink-600 hover:bg-pink-950/50 hover:text-pink-300 hover:border-pink-400 cursor-pointer"
    ColorPink, ButtonStatePending ->
      "text-pink-400 border-pink-600 opacity-70 cursor-wait sheen-pink overflow-hidden relative"
    ColorPink, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorTeal, ButtonStateNormal ->
      "text-teal-400 border-teal-600 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400 cursor-pointer"
    ColorTeal, ButtonStatePending ->
      "text-teal-400 border-teal-600 opacity-70 cursor-wait sheen-teal overflow-hidden relative"
    ColorTeal, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorOrange, ButtonStateNormal ->
      "text-orange-400 border-orange-600 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400 cursor-pointer"
    ColorOrange, ButtonStatePending ->
      "text-orange-400 border-orange-600  opacity-70 cursor-wait sheen-orange overflow-hidden relative"
    ColorOrange, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorRed, ButtonStateNormal ->
      "text-red-400 border-red-600 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400 cursor-pointer"
    ColorRed, ButtonStatePending ->
      "text-red-400 border-red-600 opacity-70 cursor-wait sheen-red overflow-hidden relative"
    ColorRed, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorGreen, ButtonStateNormal ->
      "text-green-400 border-green-600 hover:bg-green-950/50 hover:text-green-300 hover:border-green-400"
    ColorGreen, ButtonStatePending ->
      "text-green-400 border-green-600 opacity-70 cursor-wait sheen-green overflow-hidden relative"
    ColorGreen, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"
  }

  html.button(
    [
      attr.class(
        "block w-full text-left px-4 py-3 sm:py-2 text-sm transition-colors duration-200 border-l-2 -left-[1px] relative min-h-[44px] "
        <> tailwind_classes,
      ),
      attr.disabled(case state {
        ButtonStateNormal -> False
        _ -> True
      }),
      mouse.on_mouse_down_no_right(onclick),
    ],
    [html.text(text)],
  )
}

/// Menu button with custom content (e.g., icons)
pub fn button_menu_custom(
  content: List(Element(msg)),
  variant: Color,
  state: ButtonState,
  onclick: msg,
) -> Element(msg) {
  let tailwind_classes = case variant, state {
    ColorNeutral, ButtonStateNormal ->
      "text-zinc-400 border-zinc-600 hover:bg-zinc-950/50 hover:text-zinc-300 hover:border-zinc-400 cursor-pointer"
    ColorNeutral, ButtonStatePending ->
      "text-zinc-400 border-zinc-600 opacity-70 cursor-wait sheen-neutral overflow-hidden relative"
    ColorNeutral, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorPink, ButtonStateNormal ->
      "text-pink-400 border-pink-600 hover:bg-pink-950/50 hover:text-pink-300 hover:border-pink-400 cursor-pointer"
    ColorPink, ButtonStatePending ->
      "text-pink-400 border-pink-600 opacity-70 cursor-wait sheen-pink overflow-hidden relative"
    ColorPink, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorTeal, ButtonStateNormal ->
      "text-teal-400 border-teal-600 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400 cursor-pointer"
    ColorTeal, ButtonStatePending ->
      "text-teal-400 border-teal-600 opacity-70 cursor-wait sheen-teal overflow-hidden relative"
    ColorTeal, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorOrange, ButtonStateNormal ->
      "text-orange-400 border-orange-600 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400 cursor-pointer"
    ColorOrange, ButtonStatePending ->
      "text-orange-400 border-orange-600  opacity-70 cursor-wait sheen-orange overflow-hidden relative"
    ColorOrange, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorRed, ButtonStateNormal ->
      "text-red-400 border-red-600 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400 cursor-pointer"
    ColorRed, ButtonStatePending ->
      "text-red-400 border-red-600 opacity-70 cursor-wait sheen-red overflow-hidden relative"
    ColorRed, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"

    ColorGreen, ButtonStateNormal ->
      "text-green-400 border-green-600 hover:bg-green-950/50 hover:text-green-300 hover:border-green-400 cursor-pointer"
    ColorGreen, ButtonStatePending ->
      "text-green-400 border-green-600 opacity-70 cursor-wait sheen-green overflow-hidden relative"
    ColorGreen, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 opacity-50 cursor-not-allowed"
  }

  html.button(
    [
      attr.class(
        "block w-full text-left px-4 py-3 sm:py-2 text-sm transition-colors duration-200 border-l-2 -left-[1px] relative min-h-[44px] "
        <> tailwind_classes,
      ),
      attr.disabled(case state {
        ButtonStateNormal -> False
        _ -> True
      }),
      mouse.on_mouse_down_no_right(onclick),
    ],
    content,
  )
}

/// Consistent button for actions with mouse_down events
pub fn button(
  text: String,
  variant: Color,
  state: ButtonState,
  onmousedown: msg,
) -> Element(msg) {
  let tailwind_classes = case variant, state {
    ColorNeutral, ButtonStateNormal ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 hover:bg-zinc-950/50 hover:text-zinc-300 hover:border-zinc-400 cursor-pointer"
    ColorNeutral, ButtonStatePending ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-70 cursor-wait sheen-neutral overflow-hidden relative"
    ColorNeutral, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"

    ColorPink, ButtonStateNormal ->
      "text-pink-400 border-pink-600 bg-pink-500/10 hover:bg-pink-950/50 hover:text-pink-300 hover:border-pink-400 cursor-pointer"
    ColorPink, ButtonStatePending ->
      "text-pink-400 border-pink-600 bg-pink-500/10 opacity-70 cursor-wait sheen-pink overflow-hidden relative"
    ColorPink, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"

    ColorTeal, ButtonStateNormal ->
      "text-teal-400 border-teal-600 bg-teal-500/10 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400 cursor-pointer"
    ColorTeal, ButtonStatePending ->
      "text-teal-400 border-teal-600 bg-teal-500/10 opacity-70 cursor-wait sheen-teal overflow-hidden relative"
    ColorTeal, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"

    ColorOrange, ButtonStateNormal ->
      "text-orange-400 border-orange-600 bg-orange-500/10 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400 cursor-pointer"
    ColorOrange, ButtonStatePending ->
      "text-orange-400 border-orange-600 bg-orange-500/10 opacity-70 cursor-wait sheen-orange overflow-hidden relative"
    ColorOrange, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"

    ColorRed, ButtonStateNormal ->
      "text-red-400 border-red-600 bg-red-500/10 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400 cursor-pointer"
    ColorRed, ButtonStatePending ->
      "text-red-400 border-red-600 bg-red-500/10 opacity-70 cursor-wait sheen-red overflow-hidden relative"
    ColorRed, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"

    ColorGreen, ButtonStateNormal ->
      "text-green-400 border-green-600 bg-green-500/10 hover:bg-green-950/50 hover:text-green-300 hover:border-green-400 cursor-pointer"
    ColorGreen, ButtonStatePending ->
      "text-green-400 border-green-600 bg-green-500/10 opacity-70 cursor-wait sheen-green overflow-hidden relative"
    ColorGreen, ButtonStateDisabled ->
      "text-zinc-400 border-zinc-600 bg-zinc-500/10 opacity-50 cursor-not-allowed"
  }

  html.button(
    [
      attr.class(
        "px-4 py-3 sm:py-2 border-l-4 transition-colors duration-200 min-w-24 min-h-[44px] "
        <> tailwind_classes,
      ),
      attr.disabled(case state {
        ButtonStateNormal -> False
        _ -> True
      }),
      mouse.on_mouse_down_no_right(onmousedown),
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
  form_input_with_focus(
    label,
    value,
    placeholder,
    input_type,
    required,
    error,
    oninput,
    None,
  )
}

pub fn form_input_with_focus(
  label: String,
  value: String,
  placeholder: String,
  input_type: String,
  required: Bool,
  error: Option(String),
  oninput: fn(String) -> msg,
  focus_id: Option(String),
) -> Element(msg) {
  html.div([attr.class("mb-6")], [
    html.label([attr.class("block text-sm font-semibold text-zinc-300 mb-3")], [
      html.text(label),
      case required {
        True -> html.span([attr.class("text-red-400 ml-1")], [html.text("*")])
        False -> element_none()
      },
    ]),
    html.input(
      list.append(
        [
          attr.class(case error {
            Some(_) ->
              "w-full bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 pl-4 pr-4 py-4 sm:py-3 text-zinc-100 placeholder-zinc-500 transition-all duration-300 ease-out outline-none border-l-red-500 focus:border-l-red-400 focus:bg-red-500/5 focus:ring-2 focus:ring-red-400/30"
            None ->
              "w-full bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 pl-4 pr-4 py-4 sm:py-3 text-zinc-100 placeholder-zinc-500 transition-all duration-300 ease-out outline-none border-l-teal-600 focus:border-l-teal-400 focus:bg-teal-500/5 focus:ring-2 focus:ring-teal-400/30"
          }),
          attr.type_(input_type),
          attr.value(value),
          attr.placeholder(placeholder),
          attr.required(required),
          event.on_input(oninput),
        ],
        case focus_id {
          Some(id) -> [attr.id(id)]
          None -> []
        },
      ),
    ),
    case error {
      Some(error_msg) ->
        html.p(
          [attr.class("text-red-400 text-sm mt-2 flex items-center gap-1")],
          [
            html.span([attr.class("text-red-400")], [html.text("⚠ ")]),
            html.text(error_msg),
          ],
        )
      None -> element_none()
    },
  ])
}

/// Form textarea component with consistent styling
pub fn form_textarea(
  label: String,
  value: String,
  placeholder: String,
  height_class: String,
  required: Bool,
  error: Option(String),
  oninput: fn(String) -> msg,
) -> Element(msg) {
  html.div([attr.class("mb-6")], [
    html.label([attr.class("block text-sm font-semibold text-zinc-300 mb-3")], [
      html.text(label),
      case required {
        True -> html.span([attr.class("text-red-400 ml-1")], [html.text("*")])
        False -> element_none()
      },
    ]),
    html.textarea(
      [
        attr.class(case error {
          Some(_) ->
            "w-full "
            <> height_class
            <> " bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 p-4 sm:p-3 text-zinc-100 placeholder-zinc-500 resize-none transition-all duration-300 ease-out outline-none border-l-red-500 focus:border-l-red-400 focus:bg-red-500/5 focus:ring-2 focus:ring-red-400/30"
          None ->
            "w-full "
            <> height_class
            <> " bg-zinc-800 border-l-2 border-r border-t border-b border-zinc-600 p-4 sm:p-3 text-zinc-100 placeholder-zinc-500 resize-none transition-all duration-300 ease-out outline-none border-l-teal-600 focus:border-l-teal-400 focus:bg-teal-500/5 focus:ring-2 focus:ring-teal-400/30"
        }),
        attr.value(value),
        attr.placeholder(placeholder),
        attr.required(required),
        event.on_input(oninput),
      ],
      value,
    ),
    case error {
      Some(error_msg) ->
        html.p(
          [attr.class("text-red-400 text-sm mt-2 flex items-center gap-1")],
          [
            html.span([attr.class("text-red-400")], [html.text("⚠ ")]),
            html.text(error_msg),
          ],
        )
      None -> element_none()
    },
  ])
}

// MODALS ---------------------------------------------------------------------

pub fn modal_backdrop(onclose: msg) -> Element(msg) {
  html.div(
    [
      attr.class("fixed inset-0 z-40 bg-black/60 backdrop-blur-sm"),
      event.on_click(onclose),
    ],
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
    [attr.class("fixed inset-0 z-50 flex items-center justify-center p-4")],
    [
      html.div(
        [
          attr.class(
            "bg-zinc-800/80 backdrop-blur-md border-l-2 border-teal-600 border-r border-r-zinc-700 border-t border-t-zinc-700 border-b border-b-zinc-700 max-w-md w-full mx-4 overflow-hidden",
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
            [] -> element_none()
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
        None -> element_none()
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

// MODERN UTILITIES -----------------------------------------------------------

pub fn glass_panel(content: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      attr.class(
        "bg-zinc-800/80 backdrop-blur-md px-4 py-6 border border-white/10",
      ),
    ],
    content,
  )
}

/// Status badge component for displaying state (active/inactive, etc.)
pub fn status_badge(text: String, variant: Color) -> Element(msg) {
  let color_classes = case variant {
    ColorNeutral -> "bg-zinc-600/20 text-zinc-400 ring-zinc-600/30"
    ColorPink -> "bg-pink-600/20 text-pink-400 ring-pink-600/30"
    ColorTeal -> "bg-teal-600/20 text-teal-400 ring-teal-600/30"
    ColorOrange -> "bg-orange-600/20 text-orange-400 ring-orange-600/30"
    ColorRed -> "bg-red-600/20 text-red-400 ring-red-600/30"
    ColorGreen -> "bg-green-600/20 text-green-400 ring-green-600/30"
  }

  html.span(
    [
      attr.class(
        "inline-flex shrink-0 items-center  px-2 py-1 text-xs font-medium ring-1 ring-inset "
        <> color_classes,
      ),
    ],
    [html.text(text)],
  )
}

/// Card component with consistent styling
pub fn card(key: String, content: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      attr.class(
        "card group/"
        <> key
        <> " relative hover:bg-zinc-700/10  block border-l-8 border-zinc-700 px-4 py-6 my-4 hover:border-pink-700 transition-colors duration-150",
      ),
    ],
    [
      // static corner accents
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute top-0 right-0 w-6 h-6 border-t-2 border-r-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute top-0 left-0 w-6 h-6 border-t-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute bottom-0 right-0 w-6 h-6 border-b-2 border-r-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute bottom-0 left-0 w-6 h-6 border-b-2 border-zinc-700",
          ),
        ],
        [],
      ),  
      ..content
    ],
  )
}

/// Card with custom title
pub fn card_with_title(
  _key: String,
  title: String,
  content: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      attr.class(
        "card relative transition-colors duration-150 hover:bg-zinc-700/10 block border-l-8 border-zinc-700 px-4 py-6 my-4 hover:border-pink-700",
      ),
    ],
    [
      // static corner accents
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute top-0 right-0 w-6 h-6 border-t-2 border-r-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute top-0 left-0 w-6 h-6 border-t-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute bottom-0 right-0 w-6 h-6 border-b-2 border-r-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.span(
        [
          attr.class(
            "card-corner pointer-events-none absolute bottom-0 left-0 w-6 h-6 border-b-2 border-zinc-700",
          ),
        ],
        [],
      ),
      html.div([attr.class("mb-2")], [
        html.h3([attr.class("text-lg font-semibold text-zinc-100")], [
          html.text(title),
        ]),
      ]),
      html.div([], content),
    ],
  )
}

/// Notice/toast component for inline notifications
pub fn notice(
  message: String,
  variant: Color,
  dismissible: Bool,
  onclose: Option(msg),
) -> Element(msg) {
  let color_classes = case variant {
    ColorNeutral -> "bg-zinc-600/20 text-zinc-300 border-zinc-600/50"
    ColorPink -> "bg-pink-600/20 text-pink-300 border-pink-600/50"
    ColorTeal -> "bg-teal-600/20 text-teal-300 border-teal-600/50"
    ColorOrange -> "bg-orange-600/20 text-orange-300 border-orange-600/50"
    ColorRed -> "bg-red-600/20 text-red-300 border-red-600/50"
    ColorGreen -> "bg-green-600/20 text-green-300 border-green-600/50"
  }

  html.div(
    [
      attr.class(
        "flex items-center justify-between  border p-4 " <> color_classes,
      ),
    ],
    [
      html.p([attr.class("text-sm font-medium")], [html.text(message)]),
      case dismissible, onclose {
        True, Some(close_msg) ->
          html.button(
            [
              attr.class("text-sm hover:opacity-75 transition-opacity"),
              event.on_click(close_msg),
            ],
            [html.text("×")],
          )
        _, _ -> element_none()
      },
    ],
  )
}

/// Skeleton loader for content placeholders
pub fn skeleton_text(lines: Int) -> Element(msg) {
  let line_elements =
    list.range(1, lines)
    |> list.map(fn(_) {
      html.div([attr.class("h-4 bg-zinc-700  animate-pulse mb-2")], [])
    })

  html.div([attr.class("space-y-2")], line_elements)
}

/// Skeleton loader for article cards
pub fn skeleton_card() -> Element(msg) {
  html.div(
    [attr.class("bg-zinc-800  border border-zinc-700 p-6 animate-pulse")],
    [
      html.div([attr.class("h-6 bg-zinc-700  mb-4 w-3/4")], []),
      html.div([attr.class("h-4 bg-zinc-700  mb-2")], []),
      html.div([attr.class("h-4 bg-zinc-700  mb-2 w-5/6")], []),
      html.div([attr.class("h-4 bg-zinc-700  w-2/3")], []),
    ],
  )
}
