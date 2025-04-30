// IMPORTS ---------------------------------------------------------------------

import article/article.{
  type Article, ArticleFull, ArticleSummary, ArticleWithError,
}
import chat/chat
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/javascript/array
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
    articles: Dict(Int, Article),
    route: Route,
    user_messages: List(UserMessage),
    chat: chat.Model,
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

  let #(chat_model, chat_effect) = chat.init()
  let model = Model(route:, articles:, user_messages: [], chat: chat_model)
  let effect_articles = article.get_metadata_all(GotArticleSummaries)
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })
  let effect_route = effect_navigation(model)
  #(
    model,
    effect.batch([
      effect_modem,
      effect_articles,
      effect_route,
      effect.map(chat_effect, fn(msg) { ChatMsg(msg) }),
    ]),
  )
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
  GotArticle(id: Int, result: Result(Article, HttpError))
  GotArticleSummaries(result: Result(List(Article), http.HttpError))
  ArticleHovered(article: Article)
  UserMessageDismissed(msg: UserMessage)
  // CHAT
  ChatMsg(msg: chat.Msg)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserNavigatedTo(route:) -> {
      update_user_navigated_to(model, route)
    }
    InjectMarkdownResult(_) -> {
      #(model, effect.none())
    }
    ClickedConnectButton -> {
      #(model, article.get_metadata_all(GotArticleSummaries))
    }
    WebsocketConnetionResult(result:) -> {
      let user_message = case result {
        Ok(_) -> {
          UserInfo(user_message_id_next(model.user_messages), "connected")
        }
        Error(_) -> {
          UserError(
            user_message_id_next(model.user_messages),
            "failed to connect",
          )
        }
      }
      let user_messages = list.append(model.user_messages, [user_message])
      #(Model(..model, user_messages:), effect.none())
    }
    WebsocketOnMessage(data:) -> {
      update_websocket_on_message(model, data)
    }
    WebsocketOnClose(data:) -> {
      update_websocket_on_close(model, data)
    }
    WebsocketOnError(data:) -> {
      update_websocket_on_error(model, data)
    }
    WebsocketOnOpen(data:) -> {
      update_websocket_on_open(model, data)
    }
    GotArticleSummaries(result:) -> {
      update_got_article_summaries(model, result)
    }
    GotArticle(id, result) -> {
      case result {
        Ok(article) -> {
          let articles = dict.insert(model.articles, article.id, article)
          #(Model(..model, articles:), effect.none())
        }
        Error(err) -> update_got_article_error(model, err, id)
      }
    }
    ArticleHovered(article:) -> {
      case article {
        ArticleSummary(id, _, _, _) -> {
          #(
            model,
            article.get_article(fn(result) { GotArticle(id, result) }, id),
          )
        }
        ArticleFull(_, _, _, _, _) -> {
          #(model, effect.none())
        }
        ArticleWithError(_, _, _, _, _) -> {
          #(model, effect.none())
        }
      }
    }
    UserMessageDismissed(msg) -> {
      let user_messages = list.filter(model.user_messages, fn(m) { m != msg })
      #(Model(..model, user_messages:), effect.none())
    }
    ChatMsg(msg:) -> {
      let #(chat_model, chat_effect) = chat.update(msg, model.chat)
      #(
        Model(..model, chat: chat_model),
        effect.map(chat_effect, fn(msg) { ChatMsg(msg) }),
      )
    }
  }
}

fn update_user_navigated_to(model: Model, route: Route) -> #(Model, Effect(Msg)) {
  #(Model(..model, route:), effect_navigation(model))
}

fn effect_navigation(model: Model) -> Effect(Msg) {
  case model.route {
    ArticleById(id) -> {
      let article = dict.get(model.articles, id)
      case article {
        Ok(article) -> {
          case article {
            ArticleSummary(id, _, _, _) -> {
              echo "loading article content"
              article.get_article(fn(result) { GotArticle(id, result) }, id)
            }
            ArticleFull(_, _, _, _, _) -> {
              echo "article content already loaded"
              effect.none()
            }
            ArticleWithError(_, _, _, _, _) -> {
              echo "article errored"
              effect.none()
            }
          }
        }
        Error(_) -> {
          echo "no article found for id: " <> int.to_string(id)
          effect.none()
        }
      }
    }
    _ -> {
      echo "no effect for route: " <> route_url(model.route)
      effect.none()
    }
  }
}

fn update_websocket_on_message(
  model: Model,
  data: String,
) -> #(Model, Effect(Msg)) {
  echo "message: " <> data
  #(model, effect.none())
}

fn update_websocket_on_close(
  model: Model,
  data: String,
) -> #(Model, Effect(Msg)) {
  echo "close: " <> data
  #(model, effect.none())
}

fn update_websocket_on_error(
  model: Model,
  data: String,
) -> #(Model, Effect(Msg)) {
  echo "error: " <> data
  #(model, effect.none())
}

fn update_websocket_on_open(model: Model, data: String) -> #(Model, Effect(Msg)) {
  echo "open: " <> data
  #(model, effect.none())
}

fn update_got_article_summaries(
  model: Model,
  result: Result(List(Article), http.HttpError),
) {
  case result {
    Ok(articles) -> {
      let articles = articles_update(model.articles, articles)
      let effect = case model.route {
        ArticleById(id) -> {
          echo "loading article content"
          effect_navigation(Model(..model, articles:))
        }
        _ -> {
          echo "no effect for route: " <> route_url(model.route)
          effect.none()
        }
      }
      #(Model(..model, articles:), effect)
    }
    Error(err) -> {
      let error_string = error_string.http_error(err)
      let user_messages =
        list.append(model.user_messages, [
          UserError(user_message_id_next(model.user_messages), error_string),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
  }
}

fn update_got_article_error(
  model: Model,
  err: HttpError,
  id: Int,
) -> #(Model, Effect(Msg)) {
  let error_string =
    "failed to load article (id: "
    <> int.to_string(id)
    <> "): "
    <> error_string.http_error(err)
  case err {
    http.JsonError(json.UnexpectedByte(_)) -> {
      let user_messages =
        list.append(model.user_messages, [
          UserError(user_message_id_next(model.user_messages), error_string),
        ])
      let articles =
        dict.map_values(model.articles, fn(_, article) {
          case article {
            ArticleFull(article_id, _, _, _, _)
            | ArticleSummary(article_id, _, _, _) -> {
              case article_id == id {
                True -> {
                  ArticleWithError(
                    id,
                    article.title,
                    article.leading,
                    article.subtitle,
                    error_string,
                  )
                }
                False -> article
              }
            }
            _ -> article
          }
        })
      #(Model(..model, user_messages:, articles:), effect.none())
    }
    _ -> {
      echo err
      let user_messages =
        list.append(model.user_messages, [
          UserError(
            user_message_id_next(model.user_messages),
            "UNHANDLED ERROR while loading article (id:"
              <> int.to_string(id)
              <> "): "
              <> error_string,
          ),
        ])
      #(Model(..model, user_messages:), effect.none())
    }
  }
}

fn articles_update(
  old_articles: Dict(Int, Article),
  new_articles: List(Article),
) -> Dict(Int, Article) {
  new_articles
  |> list.map(fn(article) { #(article.id, article) })
  |> dict.from_list
  |> dict.merge(old_articles)
}

fn user_message_id_next(user_messages: List(UserMessage)) -> Int {
  case list.last(user_messages) {
    Ok(msg) -> msg.id + 1
    Error(_) -> 0
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("text-zinc-400 h-full w-full text-lg font-thin mx-auto"),
      attribute.class(
        "focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
      ),
    ],
    [
      view_header(model),
      html.div(
        [attribute.class("fixed top-18 left-0 right-0")],
        view_user_messages(model.user_messages),
      ),
      html.main([attribute.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          Index -> view_index()
          Articles -> {
            case dict.is_empty(model.articles) {
              True ->
                view_article_listing(
                  dict.from_list([#(0, article.loading_article())]),
                )
              False -> view_article_listing(model.articles)
            }
          }
          ArticleById(id) -> {
            case dict.is_empty(model.articles) {
              True -> {
                echo "no articles loaded"
                view_article(article.loading_article())
              }
              False -> {
                let article = dict.get(model.articles, id)
                case article {
                  Ok(article) -> view_article(article)
                  Error(_) -> view_not_found()
                }
              }
            }
          }
          About -> view_about()
          NotFound(_) -> view_not_found()
        }
      }),
      // ..chat.view(ChatMsg, model.chat)
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------påökjölmnnm,öoigbo9ybnpuhbp.,kb iuu
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

fn view_user_messages(msgs) {
  case msgs {
    [] -> []
    [msg, ..msgs] -> [view_user_message(msg), ..view_user_messages(msgs)]
  }
}

fn view_user_message(msg: UserMessage) -> Element(Msg) {
  case msg {
    UserError(id, msg_text) -> {
      html.div(
        [
          attribute.class(
            "rounded-md bg-red-50 p-4 absolute top-0 left-0 right-0",
          ),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [html.text("ERROR")]),
            html.div([attribute.class("ml-3")], [
              html.p([attribute.class("text-sm font-medium text-red-800")], [
                html.text(msg_text),
              ]),
            ]),
            html.div([attribute.class("ml-auto pl-3")], [
              html.div([attribute.class("-mx-1.5 -my-1.5")], [
                html.button(
                  [
                    attribute.class(
                      "inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100 focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
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
          attribute.class(
            "rounded-md bg-green-50 p-4 relative top-0 left-0 right-0",
          ),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [html.text("WARNING")]),
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
          attribute.class("border-l-4 border-yellow-400 bg-yellow-50 p-4"),
          attribute.id("user-message-" <> int.to_string(id)),
        ],
        [
          html.div([attribute.class("flex")], [
            html.div([attribute.class("shrink-0")], [html.text("INFO")]),
            html.div([attribute.class("ml-3")], [
              html.p([attribute.class("font-medium text-yellow-800")], [
                html.text(msg_text),
              ]),
            ]),
            html.div([attribute.class("ml-auto pl-3")], [
              html.div([attribute.class("-mx-1.5 -my-1.5")], [
                html.button(
                  [
                    attribute.class(
                      "inline-flex rounded-md bg-yellow-50 p-1.5 text-yellow-500 hover:bg-yellow-100 focus:outline-none focus:ring-2 focus:ring-yellow-600 focus:ring-offset-2 focus:ring-offset-yellow-50",
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
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  [
    view_title("Welcome to jst.dev!", 0),
    view_subtitle(
      "...or, A lession on overengineering for fun and.. 
      well just for fun.",
      0,
    ),
    view_leading(
      "This site and it's underlying IT-infrastructure is the primary 
      place for me to experiment with technologies and topologies. I 
      also share some of my thoughts and learnings here.",
      0,
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

fn view_article_listing(articles: Dict(Int, Article)) -> List(Element(Msg)) {
  let articles =
    articles
    |> dict.values
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.map(fn(article) {
      case article {
        ArticleFull(id, title, leading, subtitle, _)
        | ArticleSummary(id, title, leading, subtitle) -> {
          html.article([attribute.class("mt-14")], [
            html.a(
              [
                attribute.class(
                  "group block  border-l border-zinc-700  pl-4 hover:border-pink-700",
                ),
                href(ArticleById(article.id)),
                event.on_mouse_enter(ArticleHovered(article)),
              ],
              [
                html.h3(
                  [
                    attribute.id("article-title-" <> int.to_string(id)),
                    attribute.class("article-title"),
                    attribute.class("text-xl text-pink-700 font-light"),
                  ],
                  [html.text(title)],
                ),
                view_subtitle(subtitle, id),
                view_paragraph(leading),
              ],
            ),
          ])
        }
        ArticleWithError(id, title, leading, subtitle, error) -> {
          html.article([attribute.class("mt-14")], [
            html.a(
              [
                attribute.class(
                  "group block  border-l border-zinc-700  pl-4 hover:border-pink-700",
                ),
              ],
              [
                html.h3(
                  [
                    attribute.id("article-title-" <> int.to_string(id)),
                    attribute.class("article-title"),
                    attribute.class("text-xl text-pink-700 font-light"),
                  ],
                  [html.text(title)],
                ),
                view_subtitle(subtitle, id),
                view_error(error),
              ],
            ),
          ])
        }
      }
    })

  [view_title("Articles", 0), ..articles]
}

fn view_article(article: Article) -> List(Element(msg)) {
  let content = case article {
    ArticleSummary(id, title, leading, subtitle) -> [
      view_title(title, id),
      view_subtitle(subtitle, id),
      view_leading(leading, id),
      view_paragraph("loading content.."),
    ]
    ArticleFull(id, title, leading, subtitle, content) -> [
      view_title(title, id),
      view_subtitle(subtitle, id),
      view_leading(leading, id),
      ..article.view_article_content(
        view_h2,
        view_h2,
        view_h2,
        view_paragraph,
        view_error,
        content,
      )
    ]
    ArticleWithError(id, title, leading, subtitle, error) -> [
      view_title(title, id),
      view_subtitle(subtitle, id),
      view_leading(leading, id),
      view_error(error),
    ]
  }

  [
    html.article([attribute.class("with-transition")], content),
    html.p([attribute.class("mt-14")], [view_link(Articles, "<- Go back?")]),
  ]
}

fn view_about() -> List(Element(msg)) {
  [
    view_title("About", 0),
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
    view_title("Not found", 0),
    view_paragraph(
      "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
    ),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_title(title: String, id: Int) -> Element(msg) {
  html.h1(
    [
      attribute.id("article-title-" <> int.to_string(id)),
      attribute.class("text-3xl pt-8 text-pink-700 font-light"),
      attribute.class("article-title"),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, id: Int) -> Element(msg) {
  html.div(
    [
      attribute.id("article-subtitle-" <> int.to_string(id)),
      attribute.class("text-md text-zinc-500 font-light"),
      attribute.class("article-subtitle"),
    ],
    [html.text(title)],
  )
}

fn view_leading(text: String, id: Int) -> Element(msg) {
  html.p(
    [
      attribute.id("article-lead-" <> int.to_string(id)),
      attribute.class("font-bold pt-8"),
      attribute.class("article-leading"),
    ],
    [html.text(text)],
  )
}

fn view_h2(title: String) -> Element(msg) {
  html.h2(
    [
      attribute.class("text-2xl text-pink-600 font-light pt-16"),
      attribute.class("article-h2"),
    ],
    [html.text(title)],
  )
}

fn view_h3(title: String) -> Element(msg) {
  html.h3(
    [
      attribute.class("text-xl text-pink-600 font-light"),
      attribute.class("article-h3"),
    ],
    [html.text(title)],
  )
}

fn view_h4(title: String) -> Element(msg) {
  html.h4(
    [
      attribute.class("text-lg text-pink-600 font-light"),
      attribute.class("article-h4"),
    ],
    [html.text(title)],
  )
}

fn view_paragraph(text: String) -> Element(msg) {
  html.p([attribute.class("pt-8")], [html.text(text)])
}

fn view_error(error_string: String) -> Element(msg) {
  html.p([attribute.class("pt-8 text-orange-500")], [html.text(error_string)])
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
