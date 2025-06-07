// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article, ArticleV1}
import article/content.{type Content}
import article/draft.{Draft}
import article/id.{type ArticleId} as article_id
import gleam/dict.{type Dict}
import gleam/http/response.{type Response}
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
import routes/routes.{type Route}
import utils/error_string
import utils/http.{type HttpError}
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}
import utils/session

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
    // session: Session,
    route: Route,
    articles: RemoteData(List(Article), HttpError),
    // user_messages: List(UserMessage),
    // chat: chat.Model,
    // saving_articles: List(String),
  )
}

// type UserMessage {
//   UserError(id: Int, text: String)
//   UserWarning(id: Int, text: String)
//   UserInfo(id: Int, text: String)
// }

fn href(route: Route) -> Attribute(msg) {
  attr.href(routes.to_string(route))
}

fn init(_) -> #(Model, Effect(Msg)) {
  // The server for a typical SPA will often serve the application to *any*
  // HTTP request, and let the app itself determine what to show. Modem stores
  // the first URL so we can parse it for the app's initial route.
  let route = case modem.initial_uri() {
    Ok(uri) -> routes.from_uri(uri, Pending)
    Error(_) -> routes.Index
  }
  // let #(chat_model, chat_effect) = chat.init()
  let model =
    Model(
      route:,
      articles: Pending,
      // user_messages: [],
    // chat: chat_model,
    // saving_articles: [],
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> UserNavigatedTo
    })
  let #(model_nav, effect_nav) = update_navigation(model, model.route)
  #(
    model_nav,
    effect.batch([
      effect_modem,
      effect_nav,
      // effect.map(chat_effect, ChatMsg),
      article.article_metadata_get(ArticleMetaGot),
      persist.localstorage_get(
        persist.model_localstorage_key,
        persist.decoder(),
        PersistGotModel,
      ),
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
  UserNavigatedTo(uri: Uri)
  // MESSAGES
  // UserMessageDismissed(msg: UserMessage)
  // LOCALSTORAGE
  PersistGotModel(opt: Option(PersistentModel))
  // ARTICLES
  ArticleHovered(article: Article)
  ArticleGot(id: ArticleId, result: Result(Article, HttpError))
  ArticleMetaGot(result: Result(List(Article), HttpError))
  // ARTICLE DRAFT
  ArticleDraftUpdatedSlug(article: Article, text: String)
  ArticleDraftUpdatedTitle(article: Article, text: String)
  ArticleDraftUpdatedLeading(article: Article, text: String)
  ArticleDraftAddContent(article: Article, content: Content)
  ArticleDraftUpdatedSubtitle(article: Article, text: String)
  ArticleDraftContentMoveUp(content_item: Content, index: Int)
  ArticleDraftContentMoveDown(content_item: Content, index: Int)
  ArticleDraftContentRemove(content_item: Content, index: Int)
  ArticleDraftContentUpdate(content_item: Content, index: Int, content: Content)
  // ARTICLE DRAFT SAVE & CREATE & DISCARD
  ArticleDraftSaveClicked(article: Article)
  ArticleDraftSaveResponse(id: ArticleId, result: Result(Article, HttpError))
  ArticleDraftDiscardClicked(article: Article)
  // AUTH
  AuthLoginClicked(username: String, password: String)
  AuthLoginResponse(result: Result(Response(String), HttpError))
  AuthLogoutClicked
  AuthLogoutResponse(result: Result(Response(String), HttpError))
  AuthCheckClicked
  AuthCheckResponse(result: Result(#(Bool, String, List(String)), HttpError))
  // CHAT
  // ChatMsg(msg: chat.Msg)
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
  echo msg
  echo model.route
  case msg {
    // NAVIGATION
    UserNavigatedTo(uri:) -> {
      update_navigation(model, routes.from_uri(uri, model.articles))
    }
    // Browser Persistance
    PersistGotModel(opt:) -> {
      case opt {
        Some(PersistentModelV1(_, articles)) -> {
          #(Model(..model, articles: Loaded(articles)), effect.none())
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
    ArticleGot(id, result) -> {
      case result {
        Ok(article) -> {
          let articles_model = case model.articles {
            Loaded(articles) -> {
              Loaded(
                list.map(articles, fn(article_current) {
                  case article.id == article_current.id {
                    True -> article
                    False -> article_current
                  }
                }),
              )
            }
            _ -> Loaded([article])
          }
          let route = case model.route {
            routes.ArticleNotFound(_, slug) -> {
              case slug == article.slug {
                True -> echo routes.Article(article)
                False -> echo model.route
              }
            }
            routes.Article(ArticleV1(_, _, _, _, _, _, _, _)) -> {
              echo routes.Article(article)
            }
            _ -> model.route
          }
          #(Model(route:, articles: articles_model), effect.none())
        }
        Error(err) -> update_got_article_error(model, err, id)
      }
    }
    ArticleHovered(article:) -> {
      case article {
        ArticleV1(_, _, _, _, _, _, NotInitialized, _) -> {
          #(
            model,
            article.article_get(
              fn(result) { ArticleGot(article.id, result) },
              article.id,
            ),
          )
        }
        _ -> #(model, effect.none())
      }
    }
    // ARTICLE DRAFT
    ArticleDraftUpdatedSlug(article, text) -> {
      case article {
        ArticleV1(
          _,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          _draft,
        ) -> {
          echo "updating draft"
          echo text
          let updated_article =
            article.draft_update(article, fn(draft) {
              echo "updating draft"
              echo draft
              echo "updating draft with slug: " <> text
              echo Draft(..draft, slug: text)
            })
          #(
            Model(
              ..model,
              articles: remote_data.try_update(
                model.articles,
                list.map(_, fn(article_current) {
                  case article.id == article_current.id {
                    True -> updated_article
                    False -> article_current
                  }
                }),
              ),
            ),
            effect.none(),
          )
        }
      }
    }
    ArticleDraftUpdatedTitle(article, text) -> {
      case article {
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, title: text)
            })
          let updated_articles =
            remote_data.try_update(
              model.articles,
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> updated_article
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          None,
        ) -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedLeading(article, text) -> {
      case article {
        ArticleV1(
          id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, leading: text)
            })
          let updated_articles =
            remote_data.try_update(
              model.articles,
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> updated_article
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          None,
        ) -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedSubtitle(article, text) -> {
      case article {
        ArticleV1(
          id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, subtitle: text)
            })
          let updated_articles =
            remote_data.try_update(
              model.articles,
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> updated_article
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          None,
        ) -> #(model, effect.none())
      }
    }

    ArticleDraftAddContent(article, content) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          Draft(..draft, content: list.append(draft.content, [content]))
        })
      #(
        Model(
          ..model,
          articles: remote_data.try_update(
            model.articles,
            list.map(_, fn(article_current) {
              case article.id == article_current.id {
                True -> updated_article
                False -> article_current
              }
            }),
          ),
        ),
        effect.none(),
      )
    }
    ArticleDraftContentMoveUp(content_item, index) -> {
      todo as "move up"
      #(model, effect.none())
    }
    ArticleDraftContentMoveDown(content_item, index) -> {
      todo as "move down"
      #(model, effect.none())
    }
    ArticleDraftContentRemove(content_item, index) -> {
      todo as "remove"
      #(model, effect.none())
    }
    ArticleDraftContentUpdate(content_item, index, text) -> {
      todo as "update"
      #(model, effect.none())
    }

    // ARTICLE DRAFT DISCARD
    ArticleDraftDiscardClicked(article) -> {
      echo "article draft discard clicked"
      case article {
        ArticleV1(id, slug, revision, title, leading, subtitle, content, _draft) -> {
          let updated_articles =
            remote_data.try_update(
              model.articles,
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True ->
                    ArticleV1(
                      id,
                      slug,
                      revision,
                      title,
                      leading,
                      subtitle,
                      content,
                      None,
                    )
                  False -> article_current
                }
              }),
            )
          #(
            Model(..model, articles: updated_articles),
            modem.push(routes.to_string(routes.Article(article)), None, None),
          )
        }
        _ -> #(model, effect.none())
      }
    }
    // ARTICLE DRAFT SAVE
    ArticleDraftSaveClicked(article) -> {
      todo as "article draft save clicked"
    }
    ArticleDraftSaveResponse(id, result) -> {
      todo as "article draft save response"
    }
    // AUTH
    AuthLoginClicked(username, password) -> {
      #(model, session.login(AuthLoginResponse, username, password))
    }
    AuthLoginResponse(result) -> {
      #(model, effect.none())
    }
    AuthLogoutClicked -> {
      #(model, session.auth_logout(AuthLogoutResponse))
    }
    AuthLogoutResponse(result) -> {
      #(model, effect.none())
    }
    AuthCheckClicked -> {
      #(model, session.auth_check(AuthCheckResponse))
    }
    AuthCheckResponse(result) -> {
      echo "session check response"
      echo result
      case result {
        Ok(response) -> {
          echo "session check response ok"
          #(model, effect.none())
        }
        Error(err) -> {
          echo "session check response error"
          #(model, effect.none())
        }
      }
    }
    // CHAT
    // ChatMsg(msg) -> {
    //   let #(chat_model, chat_effect) = chat.update(msg, model.chat)
    //   #(Model(..model, chat: chat_model), effect.map(chat_effect, ChatMsg))
    // }
  }
}

fn update_navigation(model: Model, route_new: Route) -> #(Model, Effect(Msg)) {
  case route_new {
    routes.Article(article) -> {
      echo "article"
      let effect_nav = case article {
        ArticleV1(id, _, _, _, _, _, NotInitialized, _)
        | ArticleV1(id, _, _, _, _, _, Errored(_), _) -> {
          article.article_get(fn(result) { ArticleGot(id, result) }, id)
        }
        _ -> effect.none()
      }
      #(Model(..model, route: route_new), effect_nav)
    }
    routes.ArticleEdit(article) -> {
      echo "article edit"
      case article {
        ArticleV1(_, _, _, _, _, _, _, draft: Some(_)) -> {
          echo "article edit full with draft"
          #(Model(..model, route: route_new), effect.none())
        }
        ArticleV1(
          id,
          slug,
          revision,
          title,
          leading,
          subtitle,
          Loaded(content),
          _draft,
        ) -> {
          echo "article edit full"
          let updated_article =
            ArticleV1(
              id,
              slug,
              revision,
              title,
              leading,
              subtitle,
              Loaded(content),
              Some(Draft(False, slug, title, leading, subtitle, content)),
            )
          let articles_updated =
            model.articles
            |> remote_data.try_update(
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> updated_article
                  False -> article_current
                }
              }),
            )
          #(Model(route_new, articles: articles_updated), effect.none())
        }
        ArticleV1(id, _, _, _, _, _, NotInitialized, _)
        | ArticleV1(id, _, _, _, _, _, Errored(_), _) -> {
          #(
            Model(..model, route: route_new),
            article.article_get(ArticleGot(id, _), id),
          )
        }
        _ -> #(Model(..model, route: route_new), effect.none())
      }
    }
    routes.Articles(articles) -> {
      echo "articles"
      case articles {
        Errored(err) -> {
          echo "articles errored"
          echo err
          #(
            Model(..model, route: route_new),
            article.article_metadata_get(ArticleMetaGot),
          )
        }
        NotInitialized -> {
          echo "articles not initialized"
          #(
            Model(..model, route: route_new),
            article.article_metadata_get(ArticleMetaGot),
          )
        }
        _ -> #(Model(..model, route: route_new), effect.none())
      }
    }
    _ -> #(Model(..model, route: route_new), effect.none())
  }
}

fn update_got_articles_metadata(
  model: Model,
  result: Result(List(Article), HttpError),
) {
  case result {
    Ok(articles) -> {
      case model.route {
        routes.ArticleNotFound(available_articles, slug) -> {
          case list.find(articles, fn(article) { article.slug == slug }) {
            Ok(article) -> {
              case article {
                ArticleV1(id, _, _, _, _, _, Loaded(_), _draft_option) -> {
                  #(
                    Model(
                      route: routes.Article(article),
                      articles: Loaded(articles),
                    ),
                    article.article_get(ArticleGot(id, _), id),
                  )
                }
                _ -> #(
                  Model(..model, articles: Loaded(articles)),
                  effect.none(),
                )
              }
            }
            Error(Nil) -> {
              #(Model(..model, articles: Loaded(articles)), effect.none())
            }
          }
        }
        routes.ArticleEditNotFound(available_articles, id) -> {
          echo "article edit not found"
          echo id
          echo available_articles
          echo articles |> list.map(fn(article) { article.id })
          #(Model(..model, articles: Loaded(articles)), effect.none())
        }
        _ -> {
          #(Model(..model, articles: Loaded(articles)), effect.none())
        }
      }
    }
    Error(err) -> {
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

fn update_got_article_error(
  model: Model,
  err: HttpError,
  id: ArticleId,
) -> #(Model, Effect(Msg)) {
  let error_string =
    "failed to load article (id: "
    <> article_id.to_string(id)
    <> "): "
    <> error_string.http_error(err)
  let articles = case model.articles {
    Loaded(articles) -> articles
    _ -> []
  }
  case err {
    http.JsonError(json.UnexpectedByte(_)) -> {
      case list.find(articles, fn(article) { article.id == id }) {
        Ok(article) -> {
          let articles_updated =
            list.map(articles, fn(article_current) {
              case article_current.id == id {
                True ->
                  ArticleV1(
                    article_current.id,
                    article_current.slug,
                    article_current.revision,
                    article_current.title,
                    article_current.leading,
                    article_current.subtitle,
                    Errored(err),
                    None,
                  )
                False -> article_current
              }
            })
          #(Model(..model, articles: Loaded(articles_updated)), effect.none())
        }
        Error(_) -> {
          echo error_string.http_error(err)
          #(model, effect.none())
        }
      }
    }

    http.NotFound -> {
      case list.find(articles, fn(article) { article.id == id }) {
        Ok(article) -> {
          let article =
            ArticleV1(
              article.id,
              article.slug,
              article.revision,
              article.title,
              article.leading,
              article.subtitle,
              Errored(err),
              None,
            )
          #(
            Model(..model, articles: Loaded(list.append(articles, [article]))),
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
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attr.class("text-zinc-400 min-h-screen w-full text-base md:text-lg font-thin mx-auto"),
      attr.class(
        "focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
      ),
    ],
    [
      view_header(model),
      html.main([attr.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          routes.Index -> {
            case model.articles {
              Loaded(articles) -> {
                case
                  list.find(articles, fn(article) {
                    article.slug == "nats-all-the-way-down"
                  })
                {
                  Ok(article) -> view_index()
                  Error(_) -> view_not_found()
                }
              }
              _ -> view_not_found()
            }
          }
          routes.Articles(articles) -> {
            case model.articles {
              Loaded(articles) -> {
                case list.is_empty(articles) {
                  True -> [view_error("got no articles from server")]
                  False -> view_article_listing(articles)
                }
              }
              Errored(err) -> [
                html.div([
                  attr.class("bg-orange-900/20 border border-orange-800/30 rounded-lg p-6 mt-8"),
                ], [
                  html.div([attr.class("flex items-center gap-3 mb-4")], [
                    html.span([attr.class("text-3xl text-orange-500")], [html.text("⚠")]),
                    view_h2(error_string.http_error(err)),
                  ]),
                  view_paragraph([
                    content.Text(
                      "We encountered an error while loading the articles. Try reloading the page.",
                    ),
                  ]),
                  html.button([
                    attr.class("mt-4 px-4 py-2 bg-orange-800/50 text-orange-200 rounded-md hover:bg-orange-700/50 transition-colors"),
                    event.on_click(ArticleMetaGot(Error(err))),
                  ], [
                    html.text("Try Again")
                  ]),
                ]),
              ]
              Pending -> [
                html.div([
                  attr.class("mt-8 space-y-6 animate-pulse"),
                ], [
                  html.div([attr.class("h-8 bg-zinc-800 rounded-md w-3/4")], []),
                  html.div([attr.class("space-y-3")], [
                    html.div([attr.class("h-24 bg-zinc-800 rounded-md")], []),
                    html.div([attr.class("h-24 bg-zinc-800 rounded-md")], []),
                    html.div([attr.class("h-24 bg-zinc-800 rounded-md")], []),
                  ]),
                ]),
              ]
              NotInitialized -> [
                html.div([
                  attr.class("bg-red-900/20 border border-red-800/30 rounded-lg p-6 mt-8"),
                ], [
                  html.div([attr.class("flex items-center gap-3 mb-4")], [
                    html.span([attr.class("text-3xl text-red-500")], [html.text("⚠")]),
                    view_h2("Application Error"),
                  ]),
                  view_paragraph([
                    content.Text("No attempt to load articles was made. This is a bug in the application."),
                  ]),
                  html.button([
                    attr.class("mt-4 px-4 py-2 bg-red-800/50 text-red-200 rounded-md hover:bg-red-700/50 transition-colors"),
                    event.on_click(ArticleMetaGot(Error(http.NetworkError))),
                  ], [
                    html.text("Retry Loading Articles")
                  ]),
                ]),
              ]
            }
          }
          routes.Article(article) -> {
            view_article(article)
          }
          routes.ArticleNotFound(available_articles, slug) -> {
            view_article_not_found(available_articles, slug)
          }
          routes.ArticleEdit(article) -> {
            case article {
              ArticleV1(_, _, _, _, _, _, _, draft: Some(_)) -> {
                view_article_edit(model, article)
              }
              _ -> view_article(article)
            }
          }
          routes.ArticleEditNotFound(available_articles, id) -> {
            view_article_edit_not_found(available_articles, id)
          }
          routes.About -> view_about()
          routes.NotFound(_) -> view_not_found()
        }
      }),
      // ..chat.view(ChatMsg, model.chat)
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(Msg) {
  html.nav(
    [attr.class("py-3 border-b bg-zinc-800 border-pink-700 font-mono sticky top-0 z-10 shadow-md")],
    [
      html.div(
        [
          attr.class(
            "flex justify-between px-4 sm:px-6 md:px-10 items-center max-w-screen-md mx-auto",
          ),
        ],
        [
          html.div([], [
            html.a([attr.class("font-light"), href(routes.Index)], [
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
            html.li([], [
              html.button(
                [
                  event.on_click(AuthLoginClicked("johan-st", "password")),
                  attr.class("bg-pink-700 text-white px-2 rounded-md"),
                ],
                [html.text("Login")],
              ),
            ]),
            html.li([], [
              html.button(
                [
                  event.on_click(AuthLogoutClicked),
                  attr.class("bg-pink-700 text-white px-2 rounded-md"),
                ],
                [html.text("Logout")],
              ),
            ]),
            html.li([], [
              html.button(
                [
                  event.on_click(AuthCheckClicked),
                  attr.class("bg-teal-700 text-white px-2 rounded-md"),
                ],
                [html.text("Check")],
              ),
            ]),
            view_header_link(
              current: model.route,
              to: routes.Articles(model.articles),
              label: "Articles",
            ),
            view_header_link(
              current: model.route,
              to: routes.About,
              label: "About",
            ),
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
    routes.Article(_), routes.Articles(_) -> True
    routes.ArticleEdit(_), routes.Articles(_) -> True
    _, _ -> current == target
  }

  html.li(
    [
      attr.classes([
        #("relative py-1", True),
        #("after:absolute after:bottom-0 after:left-0 after:h-0.5 after:bg-pink-700 after:transition-all after:duration-300", True),
        #("after:w-0 hover:after:w-full", !is_active),
        #("after:w-full text-pink-600", is_active),
      ]),
    ],
    [html.a(
      [
        href(target), 
        attr.class("px-1 py-2 block transition-colors hover:text-pink-500")
      ], 
      [html.text(text)]
    )],
  )
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  let assert Ok(nats_uri) = uri.parse("/article/nats-all-the-way-down")
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
      view_link(nats_uri, "NATS all the way down ->"),
    ]),
    view_paragraph([
      content.Text(
        "It to is a work in progress and I mostly keep it here for my own reference.",
      ),
    ]),
    view_paragraph([
      content.Text(
        "I'm also a software developer and a writer. I'm also a father and a 
        husband. I'm also a software developer and a writer. I'm also a father 
        and a husband. I'm also a software developer and a writer. I'm also a 
        father and a husband. I'm also a software developer and a writer.",
      ),
    ]),
  ]
}

fn view_article_listing(articles: List(Article)) -> List(Element(Msg)) {
  let articles =
    articles
    |> list.sort(fn(a, b) { string.compare(a.slug, b.slug) })
    |> list.index_map(fn(article, _index) {
      case article {
        ArticleV1(
          _,
          slug,
          _,
          title,
          leading,
          subtitle,
          Loaded(_content),
          _draft_option,
        ) -> {
          html.article([attr.class("mt-14")], [
            html.a(
              [
                attr.class(
                  "group block border-l-2 border-zinc-700 pl-4 hover:border-pink-600 transition-all duration-300",
                ),
                href(routes.Article(article)),
                event.on_mouse_enter(ArticleHovered(article)),
              ],
              [
                html.div([attr.class("flex flex-col sm:flex-row sm:justify-between sm:items-start gap-2 sm:gap-4")], [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl text-pink-600 font-light group-hover:text-pink-500 transition-colors"),
                    ],
                    [html.text(title)],
                  ),
                  view_edit_link(article, "Edit"),
                ]),
                view_subtitle(subtitle, slug),
                html.p([
                  attr.class("mt-3 line-clamp-3 text-zinc-400"),
                ], [html.text(leading)]),
              ],
            ),
          ])
        }
        ArticleV1(
          _id,
          slug,
          _revision,
          title,
          _leading,
          _subtitle,
          Errored(err),
          _,
        ) -> {
          html.article(
            [
              attr.class("mt-8 md:mt-14 group"),
              attr.class("animate-break bg-zinc-800/30 rounded-lg"),
            ],
            [
              html.a(
                [
                  href(routes.Article(article)),
                  attr.class(
                    "group block border-l-2 border-orange-700 pl-4 p-3 hover:border-orange-500 transition-colors",
                  ),
                ],
                [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl font-light text-orange-600"),
                      attr.class("animate-break--mirror hover:animate-break"),
                    ],
                    [html.text(title)],
                  ),
                  view_subtitle(error_string.http_error(err), slug),
                  view_error(
                    "there was an error loading this article. Click to try again.",
                  ),
                ],
              ),
            ],
          )
        }
        ArticleV1(_, _, _, _, _, _, NotInitialized, _) -> {
          html.article([attr.class("mt-14")], [html.text("not initialized")])
        }
        ArticleV1(_, _, _, _, _, _, Pending, _) -> {
          html.article([attr.class("mt-14")], [html.text("pending")])
        }
      }
    })

  [
    view_title("Articles", "articles"),
    html.div([attr.class("grid grid-cols-1 gap-4")], articles),
  ]
}

fn view_article_edit(model: Model, article: Article) -> List(Element(Msg)) {
  let assert Ok(index_uri) = uri.parse("/")
  echo "asserting ArticleFullWithDraft"
  let assert ArticleV1(
    _id,
    _slug,
    _revision,
    _title,
    _leading,
    _subtitle,
    _content,
    draft: Some(draft),
  ) = article
  echo "asserts succeded"
  [
    html.article([attr.class("with-transition")], [
      view_article_edit_input(
        "Slug",
        ArticleEditInputTypeSlug,
        draft.slug,
        ArticleDraftUpdatedSlug(article, _),
        article.slug,
      ),
      view_article_edit_input(
        "Title",
        ArticleEditInputTypeTitle,
        draft.title,
        ArticleDraftUpdatedTitle(article, _),
        article.slug,
      ),
      view_article_edit_input(
        "Subtitle",
        ArticleEditInputTypeSubtitle,
        draft.subtitle,
        ArticleDraftUpdatedSubtitle(article, _),
        article.slug,
      ),
      view_article_edit_input(
        "Leading",
        ArticleEditInputTypeLeading,
        draft.leading,
        ArticleDraftUpdatedLeading(article, _),
        article.slug,
      ),
      // Content editor with support for different content types
      html.div([attr.class("mb-4")], [
        html.label(
          [attr.class("block text-sm font-medium text-zinc-400 mb-1")],
          [html.text("Content")],
        ),
        // Content blocks container
        html.div(
          [attr.class("space-y-4 mb-4")],
          list.index_map(draft.content, fn(content_item, index) {
            view_content_editor_block(content_item, index)
          }),
        ),
        // Add content buttons
        html.div([attr.class("flex flex-wrap gap-2 mt-4")], [
          view_add_content_button(
            "Text",
            ArticleDraftAddContent(article, content.Text("")),
          ),
          html.input([
            attr.class(
              "w-full bg-zinc-800 border border-zinc-700 rounded-md p-3 text-md text-zinc-500 font-light",
            ),
            attr.class("focus:border-pink-600 focus:ring-1 focus:ring-pink-600 focus:outline-none transition-colors"),
            attr.value(draft.subtitle),
            attr.id("edit-subtitle-" <> article.slug),
            event.on_input(ArticleDraftUpdatedSubtitle(article, _)),
          ]),
        ]),
        
        // Leading Text field
        html.div([attr.class("mb-4")], [
          html.label(
            [
              attr.class("block text-sm font-medium text-zinc-400 mb-2"),
              attr.for("edit-leading-" <> article.slug),
            ],
            [html.text("Leading Text")],
          ),
          html.textarea(
            [
              attr.class(
                "w-full bg-zinc-800 border border-zinc-700 rounded-md p-3 font-medium text-zinc-300",
              ),
              attr.class("focus:border-pink-600 focus:ring-1 focus:ring-pink-600 focus:outline-none transition-colors"),
              attr.value(draft.leading),
              attr.id("edit-leading-" <> article.slug),
              attr.rows(3),
              event.on_input(ArticleDraftUpdatedLeading(article, _)),
            ],
            draft.leading,
          ),
        ]),
        
        // Content editor with support for different content types
        html.div([attr.class("mb-4")], [
          html.div([
            attr.class("flex justify-between items-center mb-3"),
          ], [
            html.label(
              [attr.class("text-sm font-medium text-zinc-400")],
              [html.text("Content Blocks")],
            ),
            html.span([
              attr.class("text-xs text-zinc-500 bg-zinc-800 px-2 py-1 rounded-md"),
            ], [
              html.text("Drag blocks to reorder")
            ]),
          ]),
          
          // Content blocks container
          case list.length(draft.content) {
            0 -> 
              html.div(
                [attr.class("bg-zinc-800/50 border border-dashed border-zinc-700 rounded-lg p-8 text-center text-zinc-500")],
                [html.text("No content blocks yet. Add some below.")]
              )
            _ ->
              html.div(
                [attr.class("space-y-4 mb-4")],
                list.index_map(draft.content, fn(content_item, index) {
                  view_content_editor_block(content_item, index)
                }),
              )
          },
          
          // Add content buttons
          html.div([
            attr.class("flex flex-wrap gap-2 mt-6 bg-zinc-800/30 p-3 rounded-lg border border-zinc-800"),
          ], [
            html.p([attr.class("w-full text-xs text-zinc-500 mb-2")], [
              html.text("Add Content Block:")
            ]),
            view_add_content_button(
              "Text",
              ArticleDraftAddContent(article, content.Text("")),
            ),
            view_add_content_button(
              "Heading",
              ArticleDraftAddContent(article, content.Heading("")),
            ),
            view_add_content_button(
              "List",
              ArticleDraftAddContent(article, content.List([])),
            ),
            view_add_content_button(
              "Block",
              ArticleDraftAddContent(article, content.Block([])),
            ),
            view_add_content_button(
              "Link",
              ArticleDraftAddContent(
                article,
                content.Link(index_uri, "link_title"),
              ),
            ),
            view_add_content_button(
              "External Link",
              ArticleDraftAddContent(
                article,
                content.LinkExternal(index_uri, "link_title"),
              ),
            ),
            view_add_content_button(
              "Image",
              ArticleDraftAddContent(
                article,
                content.Image(index_uri, "image_title"),
              ),
            ),
          ]),
        ]),
      ]),
      
      // Action buttons
      html.div([
        attr.class("flex flex-col-reverse sm:flex-row sm:justify-between gap-4 mt-8 pt-4 border-t border-zinc-800"),
      ], [
        html.div([attr.class("flex gap-3")], [
          view_link(ArticleBySlug(article.slug), "← Cancel"),
        ]),
        html.div([attr.class("flex gap-3")], [
          html.button(
            [
              attr.class(
                "px-4 py-2 bg-zinc-800 text-zinc-400 rounded-md hover:bg-zinc-700 transition-colors",
              ),
              event.on_click(ArticleDraftDiscardClicked(article)),
              attr.disabled(draft.saving),
            ],
            [html.text("Discard Changes")],
          ),
          html.button(
            [
              attr.class(
                "px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600 transition-colors",
              ),
              attr.class("flex items-center gap-2"),
              event.on_click(ArticleDraftSaveClicked(article)),
              attr.disabled(draft.saving),
            ],
            case draft.saving {
              True -> [
                html.span([attr.class("animate-spin")], [html.text("⟳")]),
                html.text("Saving..."),
              ]
              False -> [
                html.text("Save Article"),
              ]
            },
          ),
        ]),
      ]),
    ]),
  ]
}

fn view_article_edit_not_found(
  available_articles: RemoteData(List(Article), HttpError),
  id: ArticleId,
) -> List(Element(msg)) {
  [
    view_title("Article not found", article_id.to_string(id)),
    view_paragraph([
      content.Text("The article you are looking for does not exist."),
    ]),
  ]
}

type ArticleEditInputType {
  ArticleEditInputTypeSlug
  ArticleEditInputTypeTitle
  ArticleEditInputTypeSubtitle
  ArticleEditInputTypeLeading
}

fn view_article_edit_input(
  label: String,
  input_type: ArticleEditInputType,
  value: String,
  on_input: fn(String) -> Msg,
  article_slug: String,
) -> Element(Msg) {
  let label_classes = attr.class("block text-sm font-medium text-zinc-400 mb-1")
  let input_classes = case input_type {
    ArticleEditInputTypeSlug ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 font-light",
      )
    ArticleEditInputTypeTitle ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 text-3xl text-pink-700 font-light",
      )
    ArticleEditInputTypeSubtitle ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 text-md text-zinc-500 font-light",
      )
    ArticleEditInputTypeLeading ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 font-bold",
      )
  }
  html.div([attr.class("mb-4")], [
    html.label([label_classes], [html.text(label)]),
    html.input([
      input_classes,
      attr.value(value),
      attr.id("edit-" <> article_slug <> "-" <> label),
      event.on_input(on_input),
    ]),
  ])
}

fn view_article(article: Article) -> List(Element(msg)) {
  let assert Ok(nats_uri) = uri.parse("/nats-all-the-way-down")
  let content = case article {
    ArticleV1(
      _id,
      slug,
      _revision,
      title,
      leading,
      subtitle,
      Loaded(content),
      _draft_option,
    ) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleV1(
      _id,
      slug,
      _revision,
      title,
      leading,
      subtitle,
      Errored(err),
      _draft_option,
    ) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_error(error_string.http_error(err)),
    ]

    ArticleV1(_, _, _, _, _, _, NotInitialized, _) -> [
      html.text("not initialized"),
    ]
    ArticleV1(_, _, _, _, _, _, Pending, _) -> [html.text("pending")]
  }

  [
    html.article([attr.class("with-transition")], content),
    html.p([attr.class("mt-14")], [view_link(nats_uri, "<- Go back?")]),
  ]
}

fn view_article_not_found(
  available_articles: RemoteData(List(Article), HttpError),
  slug: String,
) -> List(Element(msg)) {
  case available_articles {
    Loaded(articles) -> {
      [
        view_title("Article not found", slug),
        view_paragraph([
          content.Text("The article you are looking for does not exist."),
        ]),
      ]
    }
    Errored(error) -> {
      [
        view_title("There was an error loading the article", slug),
        view_paragraph([content.Text(error_string.http_error(error))]),
      ]
    }
    Pending -> {
      [
        view_title("Loading article", slug),
        view_paragraph([content.Text("Loading article...")]),
      ]
    }
    NotInitialized -> {
      todo as "NotInitialized should not happen as we look for articles on init"
    }
  }
}

fn view_about() -> List(Element(msg)) {
  [
    view_title("About", "about"),
    view_paragraph([
      content.Text(
        "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
      ),
    ]),
    view_paragraph([
      content.Text(
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
      content.Text(
        "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
      ),
    ]),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_edit_link(article: Article, text: String) -> Element(msg) {
  html.a(
    [
      attr.class(
        "text-zinc-500 px-3 py-1 rounded-md text-sm hover:text-teal-400 hover:bg-teal-900/30",
      ),
      href(routes.ArticleEdit(article)),
    ],
    [
      html.span([attr.class("hidden sm:inline")], [html.text("✏")]),
      html.text(text),
    ],
  )
}

fn view_title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class("text-2xl sm:text-3xl md:text-4xl text-pink-600 font-light"),
      attr.class("article-title leading-tight"),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.div(
    [
      attr.id("article-subtitle-" <> slug),
      attr.class("text-sm md:text-md text-zinc-500 font-light mt-2"),
      attr.class("article-subtitle"),
    ],
    [html.text(title)],
  )
}

fn view_leading(text: String, slug: String) -> Element(msg) {
  html.p(
    [
      attr.id("article-lead-" <> slug),
      attr.class("font-medium text-zinc-300 pt-6 md:pt-8 border-b border-zinc-800 pb-4"),
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
  html.p([
    attr.class("pt-4 md:pt-6 leading-relaxed"),
  ], view_article_content(contents))
}

fn view_error(error_string: String) -> Element(msg) {
  html.div([
    attr.class("flex items-center gap-3 text-orange-500"),
  ], [
    html.span([attr.class("text-xl")], [html.text("⚠")]),
    html.p([attr.class("leading-relaxed")], [html.text(error_string)]),
  ])
}

fn view_link(url: Uri, title: String) -> Element(msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("text-pink-700 hover:underline cursor-pointer"),
    ],
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
      content.Text(text) -> html.text(text)
      content.Block(contents) -> view_block(contents)
      content.Heading(text) -> view_h2(text)
      content.Paragraph(contents) -> view_paragraph(contents)
      content.Link(url, title) -> view_link(url, title)
      content.LinkExternal(url, title) -> view_link_external(url, title)
      content.Image(_, _) -> todo as "view content image"
      content.List(items) -> view_list(items)
      content.Unknown(type_) -> view_unknown(type_)
    }
  }
  list.map(contents, view_content)
}

// Helper function to create add content buttons
fn view_add_content_button(label: String, click_message: Msg) -> Element(Msg) {
  html.button(
    [
      attr.class(
        "px-3 py-2 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600 text-sm transition-colors",
      ),
      attr.class("flex items-center gap-1"),
      event.on_click(click_message),
    ],
    [
      html.span([attr.class("text-teal-400")], [html.text("+")]),
      html.text(label),
    ],
  )
}

// Helper function to render content editor blocks based on content type
fn view_content_editor_block(content_item: Content, index: Int) -> Element(Msg) {
  html.div([
    attr.class("border border-zinc-700 rounded-md p-4 bg-zinc-800/80"),
    attr.class("transition-all duration-200 hover:border-zinc-600 hover:shadow-lg"),
    attr.id("content-block-" <> int.to_string(index)),
  ], [
    // Content type label and controls
    html.div([attr.class("flex justify-between items-center mb-3")], [
      html.div([attr.class("flex items-center gap-2")], [
        html.span([
          attr.class("text-xs font-medium px-2 py-1 rounded-full bg-zinc-700 text-zinc-300"),
        ], [
          html.text(content_type_label(content_item)),
        ]),
        html.span([attr.class("text-xs text-zinc-500")], [
          html.text("Block #" <> int.to_string(index + 1)),
        ]),
      ]),
      html.div([attr.class("flex gap-1")], [
        // Move up button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600 transition-colors",
            ),
            attr.title("Move Up"),
            event.on_click(ArticleDraftContentMoveUp(content_item, index)),
            attr.disabled(index == 0),
          ],
          [html.text("↑")],
        ),
        // Move down button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600 transition-colors",
            ),
            attr.title("Move Down"),
            event.on_click(ArticleDraftContentMoveDown(content_item, index)),
          ],
          [html.text("↓")],
        ),
        // Delete button
        html.button(
          [
            attr.class("text-xs px-2 py-1 bg-red-900/70 rounded hover:bg-red-800 transition-colors"),
            attr.title("Delete Block"),
            event.on_click(ArticleDraftContentRemove(content_item, index)),
          ],
          [html.text("×")],
        ),
      ]),
    ]),
    // Content editor based on type
    case content_item {
      content.Text(text) ->
        html.div([attr.class("relative")], [
          html.textarea(
            [
              attr.class(
                "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3",
              ),
              attr.class("focus:border-teal-600 focus:ring-1 focus:ring-teal-600 focus:outline-none transition-colors"),
              attr.class("text-zinc-300 leading-relaxed"),
              attr.rows(4),
              attr.value(text),
              attr.placeholder("Enter your text here..."),
              event.on_input(fn(new_text) {
                ArticleDraftContentUpdate(
                  content_item,
                  index,
                  content.Text(new_text),
                )
              }),
            ],
            text,
          ),
          html.div([
            attr.class("absolute bottom-2 right-2 text-xs text-zinc-500"),
          ], [
            html.text(int.to_string(string.length(text)) <> " characters"),
          ]),
        ])

      content.Heading(text) ->
        html.div([attr.class("relative")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3 text-xl text-pink-600",
            ),
            attr.class("focus:border-pink-600 focus:ring-1 focus:ring-pink-600 focus:outline-none transition-colors"),
            attr.value(text),
            attr.placeholder("Enter heading text..."),
            event.on_input(fn(new_text) {
              ArticleDraftContentUpdate(
                content_item,
                index,
                content.Heading(new_text),
              )
            }),
          ]),
        ])

      content.Link(url, title) ->
        html.div([attr.class("space-y-3")], [
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("Link Text")],
            ),
            html.input([
              attr.class(
                "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3",
              ),
              attr.class("focus:border-teal-600 focus:ring-1 focus:ring-teal-600 focus:outline-none transition-colors"),
              attr.placeholder("Link display text"),
              attr.value(title),
              event.on_input(fn(new_title) {
                ArticleDraftContentUpdate(
                  content_item,
                  index,
                  content.Link(url, new_title),
                )
              }),
            ]),
          ]),
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("Internal URL Path")],
            ),
            html.div([attr.class("flex")], [
              html.input([
                attr.class(
                  "w-full bg-zinc-900 border border-zinc-700 rounded-l-md p-3 text-teal-500",
                ),
                attr.class("focus:border-teal-600 focus:ring-1 focus:ring-teal-600 focus:outline-none transition-colors"),
                attr.placeholder("URL path (e.g., /articles)"),
                attr.value(uri.to_string(url)),
                event.on_input(fn(new_url) {
                  case uri.parse(new_url) {
                    Ok(parsed_url) ->
                      ArticleDraftContentUpdate(
                        content_item,
                        index,
                        content.Link(parsed_url, title),
                      )
                    Error(_) ->
                      ArticleDraftContentUpdate(
                        content_item,
                        index,
                        content.Link(url, title),
                      )
                  }
                }),
              ]),
              html.button([
                attr.class("bg-teal-900/50 text-teal-400 px-3 rounded-r-md border-y border-r border-zinc-700"),
                attr.class("hover:bg-teal-900 transition-colors"),
                attr.title("Test Link"),
              ], [
                html.text("Test")
              ]),
            ]),
          ]),
        ])

      content.LinkExternal(url, title) ->
        html.div([attr.class("space-y-3")], [
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("Link Text")],
            ),
            html.input([
              attr.class(
                "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3",
              ),
              attr.class("focus:border-blue-600 focus:ring-1 focus:ring-blue-600 focus:outline-none transition-colors"),
              attr.placeholder("Link display text"),
              attr.value(title),
              event.on_input(fn(new_title) {
                ArticleDraftContentUpdate(
                  content_item,
                  index,
                  content.LinkExternal(url, new_title),
                )
              }),
            ]),
          ]),
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("External URL")],
            ),
            html.div([attr.class("flex")], [
              html.input([
                attr.class(
                  "w-full bg-zinc-900 border border-zinc-700 rounded-l-md p-3 text-blue-500",
                ),
                attr.class("focus:border-blue-600 focus:ring-1 focus:ring-blue-600 focus:outline-none transition-colors"),
                attr.placeholder("Full URL (e.g., https://example.com)"),
                attr.value(uri.to_string(url)),
                event.on_input(fn(new_url) {
                  case uri.parse(new_url) {
                    Ok(parsed_url) ->
                      ArticleDraftContentUpdate(
                        content_item,
                        index,
                        content.LinkExternal(parsed_url, title),
                      )
                    Error(_) ->
                      ArticleDraftContentUpdate(
                        content_item,
                        index,
                        content.LinkExternal(url, title),
                      )
                  }
                }),
              ]),
              html.button([
                attr.class("bg-blue-900/50 text-blue-400 px-3 rounded-r-md border-y border-r border-zinc-700"),
                attr.class("hover:bg-blue-900 transition-colors"),
                attr.title("Open Link"),
              ], [
                html.text("Open")
              ]),
            ]),
          ]),
        ])

      content.Image(url, alt) ->
        html.div([attr.class("space-y-3")], [
          // Preview of the image
          html.div([
            attr.class("bg-zinc-900/50 rounded-md p-2 border border-zinc-800 mb-2"),
          ], [
            html.div([
              attr.class("aspect-video bg-zinc-950 rounded flex items-center justify-center overflow-hidden"),
            ], [
              case uri.to_string(url) {
                "" -> 
                  html.div([attr.class("text-zinc-600 text-center p-4")], [
                    html.text("Enter an image URL below")
                  ])
                _ -> 
                  html.img([
                    attr.src(uri.to_string(url)),
                    attr.alt(alt),
                    attr.class("max-h-full object-contain"),
                    attr.attribute("loading", "lazy"),
                  ])
              }
            ]),
          ]),
          
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("Alt Text (for accessibility)")],
            ),
            html.input([
              attr.class(
                "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3",
              ),
              attr.class("focus:border-purple-600 focus:ring-1 focus:ring-purple-600 focus:outline-none transition-colors"),
              attr.placeholder("Describe the image for screen readers"),
              attr.value(alt),
              event.on_input(fn(new_alt) {
                ArticleDraftContentUpdate(
                  content_item,
                  index,
                  content.Image(url, new_alt),
                )
              }),
            ]),
          ]),
          html.div([attr.class("relative")], [
            html.label(
              [attr.class("block text-xs font-medium text-zinc-500 mb-1")],
              [html.text("Image URL")],
            ),
            html.input([
              attr.class(
                "w-full bg-zinc-900 border border-zinc-700 rounded-md p-3 text-purple-400",
              ),
              attr.class("focus:border-purple-600 focus:ring-1 focus:ring-purple-600 focus:outline-none transition-colors"),
              attr.placeholder("URL to the image"),
              attr.value(uri.to_string(url)),
              event.on_input(fn(new_url) {
                case uri.parse(new_url) {
                  Ok(parsed_url) ->
                    ArticleDraftContentUpdate(
                      content_item,
                      index,
                      content.Image(parsed_url, alt),
                    )
                  Error(_) ->
                    ArticleDraftContentUpdate(
                      content_item,
                      index,
                      content.Image(url, alt),
                    )
                }
              }),
            ]),
          ]),
        ])

      // content.List(items) ->
      //   html.div(
      //     [attr.class("space-y-2")],
      //     list.append(
      //       list.index_map(items, fn(item, item_index) {
      //         html.div([attr.class("flex gap-2")], [
      //           html.input([
      //             attr.class(
      //               "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
      //             ),
      //             attr.value(content_to_string([item])),
      //             event.on_input(fn(new_text) {
      //               let updated_items =
      //                 list_set(items, item_index, content.Text(new_text))
      //               ArticleDraftContentUpdate(
      //                 content_item,
      //                 index,
      //                 content.List(updated_items),
      //               )
      //             }),
      //           ]),
      //           html.button(
      //             [
      //               attr.class("px-2 bg-zinc-700 rounded hover:bg-zinc-600"),
      //               event.on_click(ArticleDraftContentListItemRemove(
      //                 content_item,
      //                 index,
      //                 item_index,
      //               )),
      //             ],
      //             [html.text("×")],
      //           ),
      //         ])
      //       }),
      //       [
      //         html.button(
      //           [
      //             attr.class(
      //               "w-full mt-2 px-2 py-1 bg-zinc-700 text-zinc-300 rounded hover:bg-zinc-600 text-sm",
      //             ),
      //             event.on_click(ArticleDraftContentListItemAdd(
      //               content_item,
      //               index,
      //             )),
      //           ],
      //           [html.text("+ Add Item")],
      //         ),
      //       ],
      //     ),
      //   )
      // content.Block(contents) ->
      //   html.div([attr.class("space-y-2")], [
      //     html.div(
      //       [attr.class("bg-zinc-900 border border-zinc-700 rounded-md p-3")],
      //       [
      //         html.div([attr.class("mb-2 text-xs text-zinc-500")], [
      //           html.text("Block Contents"),
      //         ]),
      //         // Nested content blocks
      //         html.div(
      //           [attr.class("space-y-3")],
      //           list.index_map(contents, fn(nested_content, nested_index) {
      //             html.div([attr.class("flex gap-2")], [
      //               html.textarea(
      //                 [
      //                   attr.class(
      //                     "w-full bg-zinc-950 border border-zinc-700 rounded-md p-2",
      //                   ),
      //                   attr.rows(2),
      //                   attr.value(content_to_string([nested_content])),
      //                   event.on_input(fn(new_text) {
      //                     let updated_contents =
      //                       list_set(
      //                         contents,
      //                         nested_index,
      //                         content.Text(new_text),
      //                       )
      //                     ArticleDraftContentUpdate(
      //                       content_item,
      //                       index,
      //                       content.Block(updated_contents),
      //                     )
      //                   }),
      //                 ],
      //                 content_to_string([nested_content]),
      //               ),
      //               html.button(
      //                 [
      //                   attr.class("px-2 bg-zinc-700 rounded hover:bg-zinc-600"),
      //                   event.on_click(ArticleDraftContentListItemRemove(
      //                     index,
      //                     nested_index,
      //                   )),
      //                 ],
      //                 [html.text("×")],
      //               ),
      //             ])
      //           }),
      //         ),
      //         html.button(
      //           [
      //             attr.class(
      //               "w-full mt-2 px-2 py-1 bg-zinc-700 text-zinc-300 rounded hover:bg-zinc-600 text-sm",
      //             ),
      //             event.on_click(ArticleDraftContentListItemAdd(index)),
      //           ],
      //           [html.text("+ Add Block Item")],
      //         ),
      //       ],
      //     ),
      //   ])
      _ ->
        html.div([], [
          html.text(
            "Unsupported content type: " <> content_type_label(content_item),
          ),
        ])
    },
  ])
}

// Helper function to get a label for content type
fn content_type_label(content: Content) -> String {
  case content {
    content.Text(_) -> "Text"
    content.Heading(_) -> "Heading"
    content.Link(_, _) -> "Link"
    content.LinkExternal(_, _) -> "External Link"
    content.Image(_, _) -> "Image"
    content.List(_) -> "List"
    content.Block(_) -> "Block"
    content.Paragraph(_) -> "Paragraph"
    content.Unknown(type_) -> "Unknown: " <> type_
  }
}
