import gleam/list
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event

// MODEL -----------------------------------------------------------------------
pub opaque type Model {
  Model(messages: List(ChatMsg), is_open: Bool, contacts: List(Contact))
}

type ChatMsg {
  ChatMsg(id: Int, sender: String, content: String, image: String)
}

type Contact {
  Contact(id: Int, name: String, status: Bool, image: String, username: String)
}

pub opaque type Msg {
  // SendMessage(content: String)
  // SendMessageResult(result: Result(Nil, Nil))
  // GotMessage(message: ChatMsg)
  CloseChat
  OpenChat
}

// INIT ------------------------------------------------------------------------

pub fn init() -> #(Model, Effect(Msg)) {
  let model =
    Model(
      messages: [
        ChatMsg(
          id: 1,
          sender: "User",
          content: "Hello, how are you?",
          image: "",
        ),
        ChatMsg(
          id: 2,
          sender: "Assistant",
          content: "I'm fine, thank you!",
          image: "",
        ),
      ],
      is_open: True,
      contacts: [
        Contact(
          id: 1,
          name: "John Doe",
          status: True,
          image: "https://images.unsplash.com/photo-1519244703995-f4e0f30006d5?ixlib=rb-1.2.1&ixid=eyJhcHBfaWQiOjEyMDd9&auto=format&fit=facearea&facepad=2&w=256&h=256&q=80",
          username: "@john_doe",
        ),
        Contact(
          id: 2,
          name: "Jane Smith",
          status: False,
          image: "https://images.unsplash.com/photo-1494790108377-be9c29b29330?ixlib=rb-1.2.1&ixid=eyJhcHBfaWQiOjEyMDd9&auto=format&fit=facearea&facepad=2&w=256&h=256&q=80",
          username: "@jane_smith",
        ),
      ],
    )
  #(model, effect.none())
}

// UPDATE ----------------------------------------------------------------------

pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg)) {
  echo msg
  echo model
  case msg {
    CloseChat -> {
      #(Model(..model, is_open: False), effect.none())
    }
    OpenChat -> {
      #(Model(..model, is_open: True), effect.none())
    }
    // _ -> {
    //   echo msg
    //   todo as "chat.Msg not implemented"
    // }
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(msg, model: Model) -> List(Element(msg)) {
  [view_open_button(msg), view_drawer(msg, model)]
}

fn view_tabs(_msg, _model: Model) -> Element(msg) {
  html.div([attribute.class("px-6")], [
    // <!-- Tab component -->
    html.nav([attribute.class("-mb-px flex space-x-6")], [
      // <!-- Current: "border-indigo-500 text-indigo-600", Default: "border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700" -->
      html.a(
        [
          attribute.class("border-pink-700 text-pink-700 font-normal"),
          attribute.attribute("href", "#"),
        ],
        [html.text("All")],
      ),
      html.a(
        [
          attribute.class(
            "border-transparent text-zinc-200 hover:border-zinc-400 hover:text-zinc-400",
          ),
          attribute.attribute("href", "#"),
        ],
        [html.text("Online")],
      ),
      html.a(
        [
          attribute.class(
            "border-transparent text-zinc-200 hover:border-zinc-400 hover:text-zinc-400",
          ),
          attribute.attribute("href", "#"),
        ],
        [html.text("Offline")],
      ),
    ]),
  ])
}

fn view_open_button(msg) -> Element(msg) {
  html.button(
    [
      attribute.class(
        "w-16 h-16 rounded-full fixed bottom-2 right-2 bg-zinc-800 grid grid-cols-1 place-content-center shadow-lg w-max-content mx-auto text-zinc-400 font-mono font-normal",
      ),
      event.on_click(msg(OpenChat)),
    ],
    [html.text("Talk")],
  )
}

fn view_svg_cross() -> Element(msg) {
  html.svg(
    [
      attribute.class("size-6"),
      attribute.attribute("fill", "none"),
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("stroke-width", "1.5"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("aria-hidden", "true"),
      attribute.attribute("data-slot", "icon"),
    ],
    [
      svg.path([
        attribute.attribute("stroke-linecap", "round"),
        attribute.attribute("stroke-linejoin", "round"),
        attribute.attribute("d", "M6 18 18 6M6 6l12 12"),
      ]),
    ],
  )
}

fn view_svg_dots() -> Element(msg) {
  html.svg(
    [
      attribute.class("size-5 text-zinc-400 group-hover:text-pink-700"),
      attribute.attribute("viewBox", "0 0 20 20"),
      attribute.attribute("fill", "currentColor"),
      attribute.attribute("aria-hidden", "true"),
      attribute.attribute("data-slot", "icon"),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M10 3a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3ZM10 8.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3ZM11.5 15.5a1.5 1.5 0 1 0-3 0 1.5 1.5 0 0 0 3 0Z",
        ),
      ]),
    ],
  )
}

fn view_contacts(msg, model: Model) -> Element(msg) {
  html.ul(
    [
      attribute.class("flex-1 divide-y divide-gray-200 overflow-y-auto"),
      attribute.attribute("role", "list"),
    ],
    model.contacts
      |> list.map(fn(contact) { view_contact(msg, contact) }),
  )
}

fn view_contact(_msg, contact: Contact) -> Element(msg) {
  html.li([], [
    html.div([attribute.class("group relative flex items-center px-5 py-6")], [
      html.a([attribute.class("-m-1 block flex-1 p-1")], [
        html.div(
          [attribute.class("absolute inset-0 group-hover:bg-zinc-700")],
          [],
        ),
        html.div(
          [attribute.class("relative flex min-w-0 flex-1 items-center")],
          [
            html.span([attribute.class("relative inline-block shrink-0")], [
              html.img([
                attribute.class("size-10 rounded-full"),
                attribute.attribute("src", contact.image),
                attribute.attribute("alt", "persona"),
              ]),
              // <!-- Online: "bg-green-400", Offline: "bg-gray-300" -->
              html.span(
                [
                  attribute.class(
                    "absolute right-0 top-0 block size-2.5 rounded-full ring-2 ring-white",
                  ),
                  attribute.classes([
                    #("bg-green-400", contact.status),
                    #("bg-zinc-300", !contact.status),
                  ]),
                  attribute.attribute("aria-hidden", "true"),
                ],
                [],
              ),
            ]),
            html.div([attribute.class("ml-4 truncate")], [
              html.p(
                [attribute.class("truncate text-sm font-medium text-zinc-200")],
                [html.text(contact.name)],
              ),
              html.p([attribute.class("truncate text-sm text-zinc-400")], [
                html.text(contact.username),
              ]),
            ]),
          ],
        ),
      ]),
      html.div(
        [attribute.class("relative ml-2 inline-block shrink-0 text-left")],
        [
          html.button(
            [
              attribute.class(
                "group relative inline-flex size-8 items-center justify-center rounded-full bg-white focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2",
              ),
              attribute.id("options-menu-0-button"),
              attribute.attribute("aria-expanded", "false"),
              attribute.attribute("aria-haspopup", "true"),
            ],
            [
              html.span([attribute.class("absolute -inset-1.5")], []),
              html.span([attribute.class("sr-only")], [
                html.text("Open options menu"),
              ]),
              html.span(
                [
                  attribute.class(
                    "flex size-full items-center justify-center rounded-full",
                  ),
                ],
                [view_svg_dots()],
              ),
            ],
          ),
          //                     <!--
          //                       Dropdown panel, show/hide based on dropdown state.

          //                       Entering: "transition ease-out duration-100"
          //                         From: "transform opacity-0 scale-95"
          //                         To: "transform opacity-100 scale-100"
          //                       Leaving: "transition ease-in duration-75"
          //                         From: "transform opacity-100 scale-100"
          //                         To: "transform opacity-0 scale-95"
          //                     -->
          html.div(
            [
              attribute.class(
                "absolute right-9 top-0 z-10 w-48 origin-top-right rounded-md bg-white shadow-lg ring-1 ring-black/5 focus:outline-none hidden",
              ),
              attribute.attribute("role", "menu"),
              attribute.attribute("aria-orientation", "vertical"),
              attribute.attribute("aria-labelledby", "options-menu-0-button"),
              attribute.attribute("tabindex", "-1"),
            ],
            [
              html.div(
                [attribute.class("py-1"), attribute.attribute("role", "none")],
                [
                  //  <!-- Active: "bg-gray-100 text-gray-900 outline-none", Not Active: "text-gray-700" -->

                  html.a(
                    [
                      attribute.class("block px-4 py-2 text-sm text-gray-700"),
                      attribute.attribute("role", "menuitem"),
                      attribute.attribute("tabindex", "-1"),
                      attribute.attribute("id", "options-menu-0-item-0"),
                    ],
                    [html.text("View profile")],
                  ),
                  html.a(
                    [
                      attribute.class("block px-4 py-2 text-sm text-gray-700"),
                      attribute.attribute("role", "menuitem"),
                      attribute.attribute("tabindex", "-1"),
                      attribute.attribute("id", "options-menu-0-item-1"),
                    ],
                    [html.text("Send message")],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]),
  ])
}

fn view_drawer(msg, model: Model) -> Element(msg) {
  html.div(
    [
      attribute.class("relative z-10"),
      attribute.classes([#("pointer-events-none", !model.is_open)]),
      attribute.role("dialog"),
      attribute.attribute("aria-labelledby", "slide-over-title"),
      attribute.attribute("aria-modal", "true"),
      event.on_click(msg(CloseChat)),
    ],
    [
      html.div(
        [
          attribute.class("fixed inset-0"),
          attribute.classes([#("hidden", !model.is_open)]),
        ],
        [],
      ),
      html.div([attribute.class("fixed inset-0 overflow-hidden")], [
        html.div([attribute.class("absolute inset-0 overflow-hidden")], [
          html.div(
            [
              attribute.class(
                "pointer-events-none fixed inset-y-0 right-0 flex max-w-full pl-10 sm:pl-16",
              ),
            ],
            [
              html.div(
                [
                  attribute.class(
                    "pointer-events-auto w-screen max-w-md transform transition ease-in-out duration-500 sm:duration-700",
                  ),
                  attribute.classes([
                    #("translate-x-full", !model.is_open),
                    #("translate-x-0", model.is_open),
                  ]),
                ],
                [
                  html.div(
                    [
                      attribute.class(
                        "flex h-full flex-col overflow-y-scroll border-l-8 border-zinc-700 bg-zinc-800 shadow-xl",
                      ),
                    ],
                    [
                      html.div([attribute.class("p-6")], [
                        html.div(
                          [attribute.class("flex items-start justify-between")],
                          [
                            html.h2(
                              [
                                attribute.class(
                                  "text-base font-semibold text-zinc-200",
                                ),
                              ],
                              [html.text("Who's online?")],
                            ),
                            html.div(
                              [attribute.class("ml-3 flex h-7 items-center")],
                              [
                                html.button(
                                  [
                                    attribute.class(
                                      "relative rounded-md bg-zinc-800 hover:bg-zinc-900 text-zinc-400 hover:text-zinc-300 focus:ring-2 focus:ring-pink-700",
                                    ),
                                    event.on_click(msg(CloseChat)),
                                  ],
                                  [
                                    html.span(
                                      [attribute.class("absolute -inset-2.5")],
                                      [],
                                    ),
                                    html.span([attribute.class("sr-only")], [
                                      html.text("Close panel"),
                                    ]),
                                    view_svg_cross(),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ]),
                      html.div([attribute.class("border-b border-zinc-400")], [
                        view_tabs(msg, model),
                      ]),
                      view_contacts(msg, model),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ]),
      ]),
    ],
  )
}
