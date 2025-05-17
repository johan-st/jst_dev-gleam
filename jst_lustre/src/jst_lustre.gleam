// IMPORTS ---------------------------------------------------------------------

import article/article.{
  type Article, type Content, ArticleFull, ArticleSummary, ArticleWithError,
}
import chat/chat
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{type Attribute}
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import utils/error_string
import utils/http.{type HttpError}
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  // let app = lustre.application(init, update_with_localstorage, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    route: Route,
    articles: RemoteData(Dict(String, Article), HttpError),
    articles_drafts: Dict(String, Article),
    // user_messages: List(UserMessage),
    chat: chat.Model,
  )
}

type RemoteData(a, err) {
  NotInitialized
  Pending
  Loaded(a)
  Errored(err)
}

// type UserMessage {
//   UserError(id: Int, text: String)
//   UserWarning(id: Int, text: String)
//   UserInfo(id: Int, text: String)
// }

type Route {
  Index
  Articles
  ArticleBySlug(slug: String)
  ArticleBySlugEdit(slug: String)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

fn parse_route(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", slug] -> ArticleBySlug(slug)
    ["article", slug, "edit"] -> ArticleBySlugEdit(slug)
    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

fn route_url(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about"
    Articles -> "/articles"
    ArticleBySlug(slug) -> "/article/" <> slug
    ArticleBySlugEdit(slug) -> "/article/" <> slug <> "/edit"
    NotFound(_) -> "/404"
  }
}

fn href(route: Route) -> Attribute(msg) {
  attr.href(route_url(route))
}

fn init(_) -> #(Model, Effect(Msg)) {
  // The server for a typical SPA will often serve the application to *any*
  // HTTP request, and let the app itself determine what to show. Modem stores
  // the first URL so we can parse it for the app's initial route.
  let route = case modem.initial_uri() {
    Ok(uri) -> parse_route(uri)
    Error(_) -> Index
  }
  let #(chat_model, chat_effect) = chat.init()
  let model =
    Model(
      route:,
      articles: Pending,
      articles_drafts: dict.new(),
      // user_messages: [],
      chat: chat_model,
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })
  #(
    model,
    effect.batch([
      effect_modem,
      effect_navigation(model, route),
      effect.map(chat_effect, ChatMsg),
      article.get_metadata_all(ArticleMetaGot),
      persist.localstorage_get(
        persist.model_localstorage_key,
        persist.decoder(),
        PersistGotModel,
      ),
      // flags_get(GotFlags),
    ]),
  )
}

// pub fn flags_get(msg) -> Effect(Msg) {
//   let url = "http://127.0.0.1:1234/priv/static/flags.json"
//   http.get(url, http.expect_json(article_decoder(), msg))
// }

// UPDATE ----------------------------------------------------------------------

type Msg {
  // NAVIGATION
  UserNavigatedTo(route: Route)
  // MESSAGES
  // UserMessageDismissed(msg: UserMessage)
  // LOCALSTORAGE
  PersistGotModel(opt: Option(PersistentModel))
  // ARTICLES
  ArticleHovered(article: Article)
  ArticleGot(slug: String, result: Result(Article, HttpError))
  ArticleMetaGot(result: Result(List(Article), HttpError))
  // ARTICLE EDIT
  ArticleEditCancelled(article: Article)
  ArticleEditSaved(article: Article)
  // CHAT
  ChatMsg(msg: chat.Msg)
}

// fn update_with_localstorage(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
//   let #(new_model, effect) = update(model, msg)
//   let persistent_model = fn(model: Model) -> PersistentModel {
//     PersistentModelV1(
//       version: 1,
//       articles: case model.articles {
//         NotInitialized -> []
//         Pending -> []
//         Loaded(articles) -> articles |> dict.to_list
//         Errored(_) -> []
//       }
//         |> list.map(fn(tuple) {
//           let #(_id, article) = tuple
//           article
//         }),
//     )
//   }
//   case msg {
//     ArticleMetaGot(_) -> {
//       persist.localstorage_set(
//         persist.model_localstorage_key,
//         persist.encode(persistent_model(new_model)),
//       )
//     }
//     ArticleGot(_, _) -> {
//       persist.localstorage_set(
//         persist.model_localstorage_key,
//         persist.encode(persistent_model(new_model)),
//       )
//     }
//     _ -> Nil
//   }
//   #(new_model, effect)
// }

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // NAVIGATION
    UserNavigatedTo(route:) -> {
      case route {
        ArticleBySlugEdit(slug) -> {
          let article = dict.get(model.articles_drafts, slug)
          case article {
            Ok(_) -> {
              #(Model(..model, route:), effect_navigation(model, route))
            }
            Error(_) -> {
              let articles_drafts =
                dict.insert(
                  model.articles_drafts,
                  slug,
                  ArticleSummary(slug, 0, "", "", ""),
                )
              #(Model(..model, route:, articles_drafts:), effect.none())
            }
          }
        }
        _ -> {
          #(Model(..model, route:), effect_navigation(model, route))
        }
      }
    }
    // Browser Persistance
    PersistGotModel(opt:) -> {
      case opt {
        Some(PersistentModelV1(_, articles)) -> {
          #(
            Model(..model, articles: articles |> article.list_to_dict |> Loaded),
            effect.none(),
          )
        }
        Some(PersistentModelV0(_)) -> {
          #(model, effect.none())
        }
        None -> {
          #(model, effect.none())
        }
      }
    }
    ArticleMetaGot(result:) -> {
      update_got_articles_metadata(model, result)
    }
    ArticleGot(slug, result) -> {
      case result {
        Ok(article) -> {
          case model.articles {
            Loaded(articles) -> {
              #(
                Model(
                  ..model,
                  articles: Loaded(dict.insert(articles, article.slug, article)),
                ),
                effect.none(),
              )
            }
            _ -> {
              #(
                Model(
                  ..model,
                  articles: Loaded(dict.insert(
                    dict.new(),
                    article.slug,
                    article,
                  )),
                ),
                effect.none(),
              )
            }
          }
        }
        Error(err) -> update_got_article_error(model, err, slug)
      }
    }
    ArticleHovered(article:) -> {
      case article {
        ArticleSummary(slug, _, _, _, _) -> {
          #(
            model,
            article.get_article(fn(result) { ArticleGot(slug, result) }, slug),
          )
        }
        ArticleFull(_, _, _, _, _, _) -> {
          #(model, effect.none())
        }
        ArticleWithError(_, _, _, _, _, _) -> {
          #(model, effect.none())
        }
      }
    }
    // ARTICLE EDIT
    ArticleEditCancelled(article:) -> {
      echo "article edit cancelled"
      #(
        Model(
          ..model,
          articles_drafts: dict.delete(model.articles_drafts, article.slug),
        ),
        effect.none(),
      )
    }
    ArticleEditSaved(article:) -> {
      echo "article edit saved"
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      #(
        Model(
          ..model,
          articles_drafts: dict.delete(model.articles_drafts, article.slug),
          articles: Loaded(dict.insert(articles, article.slug, article)),
        ),
        effect.none(),
      )
    }
    // MESSAGES
    // UserMessageDismissed(msg) -> {
    //   let user_messages = list.filter(model.user_messages, fn(m) { m != msg })
    //   #(Model(..model, user_messages:), effect.none())
    // }
    // CHAT
    ChatMsg(msg:) -> {
      let #(chat_model, chat_effect) = chat.update(msg, model.chat)
      #(Model(..model, chat: chat_model), effect.map(chat_effect, ChatMsg))
    }
  }
}

fn effect_navigation(model: Model, route: Route) -> Effect(Msg) {
  case route {
    ArticleBySlug(slug) -> {
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      let article = dict.get(articles, slug)
      case article {
        Ok(article) -> {
          case article {
            ArticleSummary(slug, _, _, _, _) -> {
              article.get_article(fn(result) { ArticleGot(slug, result) }, slug)
            }
            ArticleFull(_, _, _, _, _, _) -> {
              effect.none()
            }
            ArticleWithError(_, _, _, _, _, _) -> {
              article.get_article(fn(result) { ArticleGot(slug, result) }, slug)
            }
          }
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          effect.none()
        }
      }
    }
    _ -> {
      effect.none()
    }
  }
}

// fn update_websocket_on_message(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "message: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_close(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "close: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_error(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "error: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_open(model: Model, data: String) -> #(Model, Effect(Msg)) {
//   echo "open: " <> data
//   #(model, effect.none())
// }

fn update_got_articles_metadata(
  model: Model,
  result: Result(List(Article), HttpError),
) {
  case echo result {
    Ok(articles) -> {
      let articles = article.list_to_dict(articles)
      let effect = case model.route {
        ArticleBySlug(_) -> {
          echo "loading article content"
          effect_navigation(
            Model(..model, articles: Loaded(articles)),
            model.route,
          )
        }
        _ -> {
          echo "no effect for route: " <> route_url(model.route)
          effect.none()
        }
      }
      #(Model(..model, articles: Loaded(articles)), effect)
    }
    Error(err) -> {
      // let error_string = error_string.http_error(err)
      // let user_messages =
      //   list.append(model.user_messages, [
      //     UserError(user_message_id_next(model.user_messages), error_string),
      //   ])
      // #(Model(..model, user_messages:, articles: Errored(err)), effect.none())
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

fn update_got_article_error(
  model: Model,
  err: HttpError,
  slug: String,
) -> #(Model, Effect(Msg)) {
  let error_string =
    "failed to load article (slug: "
    <> slug
    <> "): "
    <> error_string.http_error(err)
  let articles = case model.articles {
    Loaded(articles) -> articles
    _ -> dict.new()
  }
  case err {
    http.JsonError(json.UnexpectedByte(_)) -> {
      case dict.get(articles, slug) {
        Ok(article) -> {
          let art =
            articles_update(
              [
                ArticleWithError(
                  slug,
                  article.revision,
                  article.title,
                  article.leading,
                  article.subtitle,
                  error_string,
                ),
              ],
              articles,
            )
          #(Model(..model, articles: Loaded(art)), effect.none())
        }
        Error(_) -> {
          echo error_string.http_error(err)
          #(model, effect.none())
        }
      }
    }

    http.NotFound -> {
      case dict.get(articles, slug) {
        Ok(article) -> {
          let article =
            ArticleWithError(
              slug,
              article.revision,
              article.title,
              article.leading,
              article.subtitle,
              error_string,
            )
          #(
            Model(
              ..model,
              articles: Loaded(dict.insert(articles, slug, article)),
            ),
            effect.none(),
          )
        }
        Error(_) -> {
          echo "not found: " <> error_string.http_error(err)
          #(model, effect.none())
        }
      }
    }
    _ -> {
      echo err
      // let user_messages =
      //   list.append(model.user_messages, [
      //     UserError(
      //       user_message_id_next(model.user_messages),
      //       "UNHANDLED ERROR while loading article (slug:"
      //         <> slug
      //         <> "): "
      //         <> error_string,
      //     ),
      //   ])
      // #(Model(..model, user_messages:), effect.none())
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

fn articles_update(
  new_articles: List(Article),
  old_articles: Dict(String, Article),
) -> Dict(String, Article) {
  new_articles
  |> list.map(fn(article) { #(article.slug, article) })
  |> dict.from_list
  |> dict.merge(old_articles, _)
}

// fn user_message_id_next(user_messages: List(UserMessage)) -> Int {
//   case list.last(user_messages) {
//     Ok(msg) -> msg.id + 1
//     Error(_) -> 0
//   }
// }

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attr.class("text-zinc-400 h-full w-full text-lg font-thin mx-auto "),
      attr.class(
        "focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
      ),
    ],
    [
      view_header(model),
      // html.div(
      //   [attr.class("fixed top-18 left-0 right-0")],
      //   view_user_messages(model.user_messages),
      // ),
      html.main([attr.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          Index -> view_index()
          Articles -> {
            case model.articles {
              Loaded(articles) -> {
                case dict.is_empty(articles) {
                  True -> [view_error("got no articles from server")]
                  False -> view_article_listing(articles)
                }
              }
              Errored(err) -> [
                view_h2(error_string.http_error(err)),
                view_paragraph([
                  article.Text(
                    "We encountered an error while loading the articles. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  article.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  article.Text("no atempt to load articles made. This is a bug"),
                ]),
              ]
            }
          }
          ArticleBySlug(slug) -> {
            case model.articles {
              Loaded(articles) -> {
                let article = dict.get(articles, slug)
                case article {
                  Ok(article) -> view_article(article)
                  Error(_) -> view_not_found()
                }
              }
              Errored(err) -> [
                view_h2(error_string.http_error(err)),
                view_paragraph([
                  article.Text(
                    "We encountered an error while loading the articles and that includes this one. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  article.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  article.Text("no atempt to load articles made. This is a bug"),
                ]),
              ]
            }
          }
          ArticleBySlugEdit(slug) -> {
            case model.articles {
              Loaded(articles) -> {
                case dict.is_empty(articles) {
                  True -> {
                    echo "article by slug: no articles loaded"
                    view_article(article.loading_article())
                  }
                  False -> {
                    let article = dict.get(articles, slug)
                    case article {
                      Ok(article) -> view_article_edit(article)
                      Error(_) -> view_not_found()
                    }
                  }
                }
              }
              Errored(err) -> [view_error(error_string.http_error(err))]
              Pending -> [view_error("loading...")]
              NotInitialized -> [view_error("no atempt to load articles made")]
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
    [attr.class("py-2 border-b bg-zinc-800 border-pink-700 font-mono ")],
    [
      html.div(
        [
          attr.class(
            "flex justify-between px-10 items-center max-w-screen-md mx-auto",
          ),
        ],
        [
          html.div([], [
            html.a([attr.class("font-light"), href(Index)], [
              html.text("jst.dev"),
            ]),
          ]),
          // html.div([], [
          //   html.text(case model.user_messages {
          //     [] -> ""
          //     _ -> {
          //       let num = list.length(model.user_messages)
          //       "got " <> int.to_string(num) <> " messages"
          //     }
          //   }),
          // ]),
          html.ul([attr.class("flex space-x-8 pr-2")], [
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
    ArticleBySlug(_), Articles -> True
    _, _ -> current == target
  }

  html.li(
    [
      attr.classes([
        #("border-transparent border-b-2 hover:border-pink-700", True),
        #("text-pink-700", is_active),
      ]),
    ],
    [html.a([href(target)], [html.text(text)])],
  )
}

// VIEW MESSAGES ---------------------------------------------------------------

// fn view_user_messages(msgs) {
//   case msgs {
//     [] -> []
//     [msg, ..msgs] -> [view_user_message(msg), ..view_user_messages(msgs)]
//   }
// }

// fn view_user_message(msg: UserMessage) -> Element(Msg) {
//   case msg {
//     UserError(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("rounded-md bg-red-50 p-4 absolute top-0 left-0 right-0"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("ERROR")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("text-sm font-medium text-red-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100 focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }

//     UserWarning(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("rounded-md bg-green-50 p-4 relative top-0 left-0 right-0"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("WARNING")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("text-sm font-medium text-green-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }

//     UserInfo(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("border-l-4 border-yellow-400 bg-yellow-50 p-4"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("INFO")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("font-medium text-yellow-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-yellow-50 p-1.5 text-yellow-500 hover:bg-yellow-100 focus:outline-none focus:ring-2 focus:ring-yellow-600 focus:ring-offset-2 focus:ring-offset-yellow-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }
//   }
// }

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  [
    view_title("Welcome to jst.dev!", "welcome"),
    view_subtitle(
      "...or, A lession on overengineering for fun and.. 
      well just for fun.",
      "welcome",
    ),
    view_leading(
      "This site and it's underlying IT-infrastructure is the primary 
      place for me to experiment with technologies and topologies. I 
      also share some of my thoughts and learnings here.",
      "welcome",
    ),
    html.p([attr.class("mt-14")], [
      html.text(
        "This site and it's underlying IT-infrastructure is the primary 
        place for me to experiment with technologies and topologies. I 
        also share some of my thoughts and learnings here. Feel free to 
        check out my overview, ",
      ),
      view_link(
        ArticleBySlug("nats-all-the-way-down"),
        "NATS all the way down ->",
      ),
    ]),
    view_paragraph([
      article.Text(
        "It to is a work in progress and I mostly keep it here for my own reference.",
      ),
    ]),
    view_paragraph([
      article.Text(
        "I'm also a software developer and a writer. I'm also a father and a 
        husband. I'm also a software developer and a writer. I'm also a father 
        and a husband. I'm also a software developer and a writer. I'm also a 
        father and a husband. I'm also a software developer and a writer.",
      ),
    ]),
  ]
}

fn view_article_listing(articles: Dict(String, Article)) -> List(Element(Msg)) {
  let articles =
    articles
    |> dict.values
    |> list.sort(fn(a, b) { string.compare(a.slug, b.slug) })
    |> list.index_map(fn(article, _index) {
      case article {
        ArticleFull(slug, _, title, leading, subtitle, _)
        | ArticleSummary(slug, _, title, leading, subtitle) -> {
          html.article([attr.class("mt-14 hover:bg-blur-sm")], [
            html.a(
              [
                attr.class(
                  "group block  border-l border-zinc-700  pl-4  hover:border-pink-700 transition-colors duration-25",
                ),
                href(ArticleBySlug(slug)),
                event.on_mouse_enter(ArticleHovered(article)),
              ],
              [
                html.div([attr.class("flex justify-between gap-4")], [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl text-pink-700 font-light"),
                    ],
                    [html.text(title)],
                  ),
                  view_edit_link(article),
                ]),
                view_subtitle(subtitle, slug),
                view_paragraph([article.Text(leading)]),
              ],
            ),
          ])
        }
        ArticleWithError(slug, _revision, title, _leading, _subtitle, error) -> {
          html.article(
            [attr.class("mt-14 group group-hover"), attr.class("animate-break")],
            [
              html.a(
                [
                  href(ArticleBySlug(slug)),
                  attr.class(
                    "group block  border-l border-zinc-700 pl-4 hover:border-zinc-500 transition-colors duration-25",
                  ),
                ],
                [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl font-light w-max-content"),
                      attr.class("animate-break--mirror hover:animate-break"),
                    ],
                    [html.text(title)],
                  ),
                  view_subtitle(error, slug),
                  view_error(
                    "there was an error loading this article. Click to try again.",
                  ),
                ],
              ),
            ],
          )
        }
      }
    })

  [view_title("Articles", "articles"), ..articles]
}

fn view_article_edit(article: Article) -> List(Element(msg)) {
  let content = case article {
    ArticleSummary(slug, _revision, title, leading, subtitle) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_paragraph([article.Text("loading content..")]),
    ]
    ArticleFull(slug, _revision, title, leading, subtitle, content) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleWithError(slug, _revision, title, leading, subtitle, error) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_error(error),
    ]
  }
  [
    html.article([attr.class("with-transition")], content),
    html.p([attr.class("mt-14")], [view_link(Articles, "<- Go back?")]),
  ]
}

fn view_article(article: Article) -> List(Element(msg)) {
  let content = case article {
    ArticleSummary(slug, _revision, title, leading, subtitle) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_paragraph([article.Text("loading content..")]),
    ]
    ArticleFull(slug, _revision, title, leading, subtitle, content) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleWithError(slug, _revision, title, leading, subtitle, error) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_error(error),
    ]
  }

  [
    html.article([attr.class("with-transition")], content),
    html.p([attr.class("mt-14")], [view_link(Articles, "<- Go back?")]),
  ]
}

fn view_about() -> List(Element(msg)) {
  [
    view_title("About", "about"),
    view_paragraph([
      article.Text(
        "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
      ),
    ]),
    view_paragraph([
      article.Text(
        "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
      ),
    ]),
  ]
}

fn view_not_found() -> List(Element(msg)) {
  [
    view_title("Not found", "not-found"),
    view_paragraph([
      article.Text(
        "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
      ),
    ]),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_edit_link(article: Article) -> Element(Msg) {
  html.a(
    [
      attr.class(
        "text-gray-500 border-e pe-4 text-underline pt-2 hover:text-teal-300 hover:border-teal-300 border-t border-gray-500",
      ),
      href(ArticleBySlugEdit(article.slug)),
    ],
    [html.text("edit")],
  )
}

fn view_title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class("text-3xl pt-8 text-pink-700 font-light"),
      attr.class("article-title"),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.div(
    [
      attr.id("article-subtitle-" <> slug),
      attr.class("text-md text-zinc-500 font-light"),
      attr.class("article-subtitle"),
    ],
    [html.text(title)],
  )
}

fn view_leading(text: String, slug: String) -> Element(msg) {
  html.p(
    [
      attr.id("article-lead-" <> slug),
      attr.class("font-bold pt-8"),
      attr.class("article-leading"),
    ],
    [html.text(text)],
  )
}

fn view_h2(title: String) -> Element(msg) {
  html.h2(
    [
      attr.class("text-2xl text-pink-600 font-light pt-16"),
      attr.class("article-h2"),
    ],
    [html.text(title)],
  )
}

// fn view_h3(title: String) -> Element(msg) {
//   html.h3(
//     [attr.class("text-xl text-pink-600 font-light"), attr.class("article-h3")],
//     [html.text(title)],
//   )
// }

// fn view_h4(title: String) -> Element(msg) {
//   html.h4(
//     [attr.class("text-lg text-pink-600 font-light"), attr.class("article-h4")],
//     [html.text(title)],
//   )
// }

fn view_paragraph(contents: List(Content)) -> Element(msg) {
  html.p([attr.class("pt-8")], view_article_content(contents))
}

fn view_error(error_string: String) -> Element(msg) {
  html.p([attr.class("pt-8 text-orange-500")], [html.text(error_string)])
}

fn view_link(target: Route, title: String) -> Element(msg) {
  html.a(
    [href(target), attr.class("text-pink-700 hover:underline cursor-pointer")],
    [html.text(title)],
  )
}

fn view_link_external(url: Uri, title: String) -> Element(msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("text-pink-700 hover:underline cursor-pointer"),
      attr.target("_blank"),
    ],
    [html.text(title)],
  )
}

fn view_link_missing(url: Uri, title: String) -> Element(msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("hover:underline cursor-pointer"),
    ],
    [
      html.span([attr.class("text-orange-500")], [html.text("broken link: ")]),
      html.text(title),
    ],
  )
}

fn view_block(contents: List(Content)) -> Element(msg) {
  html.div([attr.class("pt-8")], view_article_content(contents))
}

fn view_list(items: List(Content)) -> Element(msg) {
  html.ul(
    [attr.class("pt-8 list-disc list-inside")],
    items
      |> list.map(fn(item) {
        html.li([attr.class("pt-1")], view_article_content([item]))
      }),
  )
}

fn view_unknown(content_type: String) -> Element(msg) {
  html.span([attr.class("text-orange-500")], [
    html.text("<unknown: " <> content_type <> ">"),
  ])
}

// VIEW ARTICLE CONTENT --------------------------------------------------------

fn view_article_content(contents: List(Content)) -> List(Element(msg)) {
  let view_content = fn(content: Content) -> Element(msg) {
    case content {
      article.Text(text) -> html.text(text)
      article.Block(contents) -> view_block(contents)
      article.Heading(text) -> view_h2(text)
      article.Paragraph(contents) -> view_paragraph(contents)
      article.Link(url, title) -> {
        echo "url"
        echo url
        let route = parse_route(url)
        case route {
          NotFound(_) -> view_link_missing(url, title)
          _ -> view_link(route, title)
        }
      }
      article.LinkExternal(url, title) -> view_link_external(url, title)
      article.Image(_, _) -> todo as "view content image"
      article.List(items) -> view_list(items)
      article.Unknown(content_type) -> view_unknown(content_type)
    }
  }
  list.map(contents, view_content)
}
