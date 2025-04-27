// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article}
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import utils/error_string
import utils/http.{type HttpError}

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    articles: Dict(Int, article.Article),
    route: Route,
    user_messages: List(UserMessage),
  )
}

type UserMessage {
  UserError(id: Int, text: String)
  UserWarning(id: Int, text: String)
  UserInfo(id: Int, text: String)
}

type Route {
  Index
  Articles
  ArticleById(id: Int)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

fn parse_route(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", article_id] ->
      case int.parse(article_id) {
        Ok(article_id) -> ArticleById(id: article_id)
        Error(_) -> NotFound(uri:)
      }
    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

/// We also need a way to turn a Route back into a an `href` attribute that we
/// can then use on `html.a` elements. It is important to keep this function in
/// sync with the parsing, but once you do, all links are guaranteed to work!
///
fn href(route: Route) -> Attribute(msg) {
  attribute.href(route_url(route))
}

fn route_url(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about"
    Articles -> "/articles"
    ArticleById(post_id) -> "/article/" <> int.to_string(post_id)
    NotFound(_) -> "/404"
  }
}

fn init(_) -> #(Model, Effect(Msg)) {
  // The server for a typical SPA will often serve the application to *any*
  // HTTP request, and let the app itself determine what to show. Modem stores
  // the first URL so we can parse it for the app's initial route.
  let route = case modem.initial_uri() {
    Ok(uri) -> parse_route(uri)
    Error(_) -> Index
  }

  let articles =
    []
    |> dict.from_list

  let model = Model(route:, articles:, user_messages: [])
  let effect_articles = article.get_metadata_all(GotArticleSummaries)
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })
  let effect_route = effect_navigation(model.route)
  #(model, effect.batch([effect_modem, effect_articles, effect_route]))
}

// UPDATE ----------------------------------------------------------------------

type Msg {
  UserNavigatedTo(route: Route)
  InjectMarkdownResult(result: Result(Nil, Nil))
  ClickedConnectButton
  WebsocketConnetionResult(result: Result(Nil, Nil))
  WebsocketOnMessage(data: String)
  WebsocketOnClose(data: String)
  WebsocketOnError(data: String)
  WebsocketOnOpen(data: String)
  // ArticleMsg(msg: article.Msg)
  GotArticle(result: Result(Article, HttpError))
  GotArticleSummaries(result: Result(List(Article), http.HttpError))
  UserMessageDismissed(msg: UserMessage)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserNavigatedTo(route:) -> {
      let effect = effect_navigation(route)
      #(Model(..model, route:), effect)
    }
    InjectMarkdownResult(_) -> {
      #(model, effect.none())
    }
    ClickedConnectButton -> {
      #(model, article.get_metadata_all(GotArticleSummaries))
    }
    WebsocketConnetionResult(result:) -> {
      case result {
        Ok(_) -> {
          let user_messages =
            list.append(model.user_messages, [
              UserInfo(next_user_message_id(model.user_messages), "connected"),
            ])
          #(Model(..model, user_messages:), effect.none())
        }
        Error(_) -> {
          let user_messages =
            list.append(model.user_messages, [
              UserError(
                next_user_message_id(model.user_messages),
                "failed to connect",
              ),
            ])
          #(Model(..model, user_messages:), effect.none())
        }
      }
    }
    WebsocketOnMessage(data:) -> {
      let user_messages =
        list.append(model.user_messages, [
          UserInfo(
            next_user_message_id(model.user_messages),
            "ws msg: " <> data,
          ),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
    WebsocketOnClose(data:) -> {
      let user_messages =
        list.append(model.user_messages, [
          UserWarning(
            next_user_message_id(model.user_messages),
            "ws closed: " <> data,
          ),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
    WebsocketOnError(data:) -> {
      let user_messages =
        list.append(model.user_messages, [
          UserError(
            next_user_message_id(model.user_messages),
            "ws error: " <> data,
          ),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
    WebsocketOnOpen(data:) -> {
      let user_messages =
        list.append(model.user_messages, [
          UserInfo(
            next_user_message_id(model.user_messages),
            "ws open: " <> data,
          ),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
    GotArticleSummaries(result:) -> {
      case result {
        Ok(articles) -> {
          let articles = articles_update(model.articles, articles)
          #(Model(..model, articles:), effect.none())
        }
        Error(err) -> {
          let error_string = error_string.http_error(err)
          let user_messages =
            list.append(model.user_messages, [
              UserError(next_user_message_id(model.user_messages), error_string),
            ])
          #(Model(..model, user_messages:), effect.none())
        }
      }
    }
    GotArticle(result:) -> {
      case result {
        Ok(article) -> {
          let articles = dict.insert(model.articles, article.id, article)
          echo articles
          #(Model(..model, articles:), effect.none())
        }
        Error(err) -> {
          let error_string = error_string.http_error(err)
          echo err
          case err {
            http.JsonError(json.UnexpectedByte("")) -> {
              let user_messages =
                list.append(model.user_messages, [
                  UserError(
                    next_user_message_id(model.user_messages),
                    "Article content was not available",
                  ),
                ])
              #(
                Model(..model, user_messages:),
                modem.replace("/articles", None, None),
              )
            }
            _ -> {
              let user_messages =
                list.append(model.user_messages, [
                  UserError(
                    next_user_message_id(model.user_messages),
                    "unhandled error\n" <> error_string,
                  ),
                ])
              #(Model(..model, user_messages:), effect.none())
            }
          }
        }
      }
    }
    UserMessageDismissed(msg) -> {
      echo "msg dismissed"
      echo msg

      let user_messages = list.filter(model.user_messages, fn(m) { m != msg })
      #(Model(..model, user_messages:), effect.none())
    }
  }
}

fn effect_navigation(route: Route) -> Effect(Msg) {
  case route {
    ArticleById(id) -> article.get_article(GotArticle, id)
    _ -> effect.none()
  }
}

fn articles_update(
  old_articles: Dict(Int, article.Article),
  new_articles: List(article.Article),
) -> Dict(Int, article.Article) {
  new_articles
  |> list.map(fn(article) { #(article.id, article) })
  |> dict.from_list
  |> dict.merge(old_articles)
}

fn next_user_message_id(user_messages: List(UserMessage)) -> Int {
  case list.last(user_messages) {
    Ok(msg) -> msg.id + 1
    Error(_) -> 0
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.class("text-zinc-400 h-full w-full text-lg font-thin mx-auto")],
    [
      view_header(model),
      html.div([], view_messages(model.user_messages)),
      html.main([attribute.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          Index -> view_index()
          Articles -> view_article_listing(model.articles)
          ArticleById(id) -> {
            let article = dict.get(model.articles, id)
            case article {
              Ok(article) -> view_article(article)
              Error(_) -> view_not_found()
            }
          }
          About -> view_about()
          NotFound(_) -> view_not_found()
        }
      }),
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(Msg) {
  html.nav(
    [attribute.class("py-2 border-b bg-zinc-800 border-pink-700 font-mono ")],
    [
      html.div(
        [
          attribute.class(
            "flex justify-between px-10 items-center max-w-screen-md mx-auto",
          ),
        ],
        [
          html.div([], [
            html.a([attribute.class("font-light"), href(Index)], [
              html.text("jst.dev"),
            ]),
          ]),
          html.div([], [
            html.text(case model.user_messages {
              [] -> ""
              _ -> {
                let num = list.length(model.user_messages)
                "got " <> int.to_string(num) <> " messages"
              }
            }),
          ]),
          html.ul([attribute.class("flex space-x-8 pr-2")], [
            html.button(
              [
                attribute.class("font-light"),
                event.on_click(ClickedConnectButton),
              ],
              [html.text("Connect")],
            ),
            view_header_link(
              current: model.route,
              to: Articles,
              label: "Articles",
            ),
            view_header_link(current: model.route, to: About, label: "About"),
          ]),
        ],
      ),
    ],
  )
}

fn view_header_link(
  to target: Route,
  current current: Route,
  label text: String,
) -> Element(msg) {
  let is_active = case current, target {
    ArticleById(_), Articles -> True
    _, _ -> current == target
  }

  html.li(
    [
      attribute.classes([
        #("border-transparent border-b-2 hover:border-pink-700", True),
        #("text-pink-700", is_active),
      ]),
    ],
    [html.a([href(target)], [html.text(text)])],
  )
}

// VIEW MESSAGES ---------------------------------------------------------------

fn view_messages(msgs) {
  case msgs {
    [] -> []
    [msg, ..msgs] -> [view_message(msg), ..view_messages(msgs)]
  }
}

fn view_message(msg: UserMessage) -> Element(Msg) {
  case msg {
    UserError(id, msg_text) -> {
      html.div(
        [
          attribute.class("rounded-md bg-green-50 p-4"),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [
              // <svg class="size-5 text-green-400" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" data-slot="icon">
              //   <path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd" />
              // </svg>
              html.text("👍"),
            ]),
            html.div([attribute.class("ml-3")], [
              html.p([attribute.class("text-sm font-medium text-green-800")], [
                html.text(msg_text),
              ]),
            ]),
            html.div([attribute.class("ml-auto pl-3")], [
              html.div([attribute.class("-mx-1.5 -my-1.5")], [
                html.button(
                  [
                    attribute.class(
                      "inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50",
                    ),
                    event.on_click(UserMessageDismissed(msg)),
                  ],
                  [html.text("Dismiss")],
                ),
              ]),
            ]),
          ]),
        ],
      )
    }

    UserWarning(id, msg_text) -> {
      html.div(
        [
          attribute.class("rounded-md bg-green-50 p-4"),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [
              // <svg class="size-5 text-green-400" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" data-slot="icon">
              //   <path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd" />
              // </svg>
              html.text("👍"),
            ]),
            html.div([attribute.class("ml-3")], [
              html.p([attribute.class("text-sm font-medium text-green-800")], [
                html.text(msg_text),
              ]),
            ]),
            html.div([attribute.class("ml-auto pl-3")], [
              html.div([attribute.class("-mx-1.5 -my-1.5")], [
                html.button(
                  [
                    attribute.class(
                      "inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50",
                    ),
                    event.on_click(UserMessageDismissed(msg)),
                  ],
                  [html.text("Dismiss")],
                ),
              ]),
            ]),
          ]),
        ],
      )
    }

    UserInfo(id, msg_text) -> {
      html.div(
        [
          attribute.class("rounded-md bg-green-50 p-4"),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [
              // <svg class="size-5 text-green-400" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" data-slot="icon">
              //   <path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd" />
              // </svg>
              html.text("👍"),
            ]),
            html.div([attribute.class("ml-3")], [
              html.p([attribute.class("text-sm font-medium text-green-800")], [
                html.text(msg_text),
              ]),
            ]),
            html.div([attribute.class("ml-auto pl-3")], [
              html.div([attribute.class("-mx-1.5 -my-1.5")], [
                html.button(
                  [
                    attribute.class(
                      "inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50",
                    ),
                    event.on_click(UserMessageDismissed(msg)),
                  ],
                  [html.text("Dismiss")],
                ),
              ]),
            ]),
          ]),
        ],
      )
    }
  }
  // <div class="rounded-md bg-green-50 p-4">
  //   <div class="flex">
  //     <div class="shrink-0">
  //       <svg class="size-5 text-green-400" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" data-slot="icon">
  //         <path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd" />
  //       </svg>
  //     </div>
  //     <div class="ml-3">
  //       <p class="text-sm font-medium text-green-800">Successfully uploaded</p>
  //     </div>
  //     <div class="ml-auto pl-3">
  //       <div class="-mx-1.5 -my-1.5">
  //         <button type="button" class="inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50">
  //           <span class="sr-only">Dismiss</span>
  //           <svg class="size-5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" data-slot="icon">
  //             <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
  //           </svg>
  //         </button>
  //       </div>
  //     </div>
  //   </div>
  // </div>
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  [
    view_title("Welcome to jst.dev!"),
    view_subtitle(
      "...or, A lession on overengineering for fun and.. 
      well just for fun.",
    ),
    view_leading(
      "This site and it's underlying IT-infrastructure is the primary 
      place for me to experiment with technologies and topologies. I 
      also share some of my thoughts and learnings here.",
    ),
    html.p([attribute.class("mt-14")], [
      html.text(
        "This site and it's underlying IT-infrastructure is the primary 
        place for me to experiment with technologies and topologies. I 
        also share some of my thoughts and learnings here. Feel free to 
        check out my overview, ",
      ),
      view_link(ArticleById(1), "NATS all the way down ->"),
    ]),
    view_paragraph(
      "It to is a work in progress and I mostly keep it here for my own reference.",
    ),
    view_paragraph(
      "I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband. I'm also a software developer and a writer.",
    ),
  ]
}

fn view_article_listing(
  articles: Dict(Int, article.Article),
) -> List(Element(msg)) {
  let articles =
    articles
    |> dict.values
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.map(fn(article) {
      html.article([attribute.class("mt-14")], [
        html.h3([attribute.class("text-xl text-pink-700 font-light")], [
          html.a(
            [attribute.class("hover:underline"), href(ArticleById(article.id))],
            [html.text(article.title)],
          ),
        ]),
        html.p([attribute.class("mt-1")], [html.text(article.summary)]),
      ])
    })

  [view_title("Articles"), ..articles]
}

fn view_article(article: article.Article) -> List(Element(msg)) {
  let content = case article.content {
    None -> [
      view_title(article.title),
      view_subtitle(article.summary),
      view_leading(article.summary),
      view_paragraph("failed to fetch article.."),
    ]
    Some(content) -> [
      view_title(article.title),
      view_subtitle(article.summary),
      view_leading(article.summary),
      ..article.view_article_content(
        view_h2,
        view_h3,
        view_h4,
        view_subtitle,
        view_leading,
        view_paragraph,
        view_unknown,
        content,
      )
    ]
  }

  [
    html.article([], content),
    html.p([attribute.class("mt-14")], [view_link(Articles, "<- Go back?")]),
  ]
}

fn view_about() -> List(Element(msg)) {
  [
    view_title("About"),
    view_paragraph(
      "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
    ),
    view_paragraph(
      "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
    ),
  ]
}

fn view_not_found() -> List(Element(msg)) {
  [
    view_title("Not found"),
    view_paragraph(
      "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
    ),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_title(title: String) -> Element(msg) {
  html.h1([attribute.class("text-3xl pt-8 text-pink-700 font-light")], [
    html.text(title),
  ])
}

fn view_h2(title: String) -> Element(msg) {
  html.h2([attribute.class("text-2xl text-zinc-600 font-light")], [
    html.text(title),
  ])
}

fn view_h3(title: String) -> Element(msg) {
  html.h3([attribute.class("text-xl text-zinc-600 font-light")], [
    html.text(title),
  ])
}

fn view_h4(title: String) -> Element(msg) {
  html.h4([attribute.class("text-lg text-zinc-600 font-light")], [
    html.text(title),
  ])
}

fn view_subtitle(title: String) -> Element(msg) {
  html.h2([attribute.class("text-md text-zinc-600 font-light")], [
    html.text(title),
  ])
}

fn view_leading(text: String) -> Element(msg) {
  html.p([attribute.class("font-bold pt-12")], [html.text(text)])
}

fn view_paragraph(text: String) -> Element(msg) {
  html.p([attribute.class("pt-8")], [html.text(text)])
}

fn view_unknown(unknown_type: String) -> Element(msg) {
  html.p([attribute.class("pt-8 text-orange-500")], [
    html.text(
      "Some content is missing. (Unknown content type: " <> unknown_type <> ")",
    ),
  ])
}

fn view_link(target: Route, title: String) -> Element(msg) {
  html.a(
    [
      href(target),
      attribute.class("text-pink-700 hover:underline cursor-pointer"),
    ],
    [html.text(title)],
  )
}
