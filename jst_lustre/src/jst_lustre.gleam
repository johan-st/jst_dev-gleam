// IMPORTS ---------------------------------------------------------------------

import article/article.{
  type Article, ArticleFull, ArticleFullWithDraft, ArticleSummary,
  ArticleWithError,
}
import article/content.{type Content}
import article/draft.{Draft}
import chat/chat
import gleam/dict.{type Dict}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
import utils/auth
import utils/error_string
import utils/http.{type HttpError}
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}

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
    articles: RemoteData(Dict(String, Article), HttpError),
    // user_messages: List(UserMessage),
    chat: chat.Model,
    saving_articles: List(String),
  )
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
      // user_messages: [],
      chat: chat_model,
      saving_articles: [],
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })
  let #(model_nav, effect_nav) = update_navigation(model, model.route)
  #(
    model_nav,
    effect.batch([
      effect_modem,
      effect_nav,
      effect.map(chat_effect, ChatMsg),
      article.article_metadata_get(ArticleMetaGot),
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
  ArticleDraftSaveResponse(slug: String, result: Result(Article, HttpError))
  ArticleDraftDiscardClicked(article: Article)
  // AUTH
  AuthLoginClicked(username: String, password: String)
  AuthLoginResponse(result: Result(Response(String), HttpError))
  AuthCheckClicked
  AuthCheckResponse(result: Result(#(Bool, String, List(String)), HttpError))
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
      echo "user navigated to"
      echo route
      update_navigation(model, route)
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
            article.article_get(fn(result) { ArticleGot(slug, result) }, slug),
          )
        }
        _ -> #(model, effect.none())
      }
    }
    // ARTICLE DRAFT
    ArticleDraftUpdatedSlug(article, text) -> {
      case article {
        ArticleFullWithDraft(
          slug,
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
              articles: remote_data.try_update(model.articles, dict.insert(
                _,
                slug,
                updated_article,
              )),
            ),
            effect.none(),
          )
        }
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedTitle(article, text) -> {
      case article {
        ArticleFullWithDraft(
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          draft,
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, title: text)
            })
          let updated_articles =
            remote_data.try_update(model.articles, dict.insert(
              _,
              draft.slug,
              updated_article,
            ))
          #(Model(..model, articles: updated_articles), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedLeading(article, text) -> {
      case article {
        ArticleFullWithDraft(
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          draft,
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, leading: text)
            })
          let updated_articles =
            remote_data.try_update(model.articles, dict.insert(
              _,
              draft.slug,
              updated_article,
            ))
          #(Model(..model, articles: updated_articles), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedSubtitle(article, text) -> {
      case article {
        ArticleFullWithDraft(
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          draft,
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              Draft(..draft, subtitle: text)
            })
          let updated_articles =
            remote_data.try_update(model.articles, dict.insert(
              _,
              draft.slug,
              updated_article,
            ))
          #(Model(..model, articles: updated_articles), effect.none())
        }
        _ -> #(model, effect.none())
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
          articles: remote_data.try_update(model.articles, dict.insert(
            _,
            updated_article.slug,
            updated_article,
          )),
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
        ArticleFullWithDraft(
          slug,
          revision,
          title,
          leading,
          subtitle,
          content,
          _draft,
        ) -> {
          let updated_articles =
            remote_data.try_update(model.articles, dict.insert(
              _,
              slug,
              ArticleFull(slug, revision, title, leading, subtitle, content),
            ))
          #(
            Model(..model, articles: updated_articles),
            modem.push(route_url(ArticleBySlug(slug)), None, None),
          )
        }
        _ -> #(model, effect.none())
      }
    }
    // ARTICLE DRAFT SAVE
    ArticleDraftSaveClicked(article) -> {
      echo "article draft save clicked"
      let assert ArticleFullWithDraft(
        slug: slug,
        revision: revision,
        title: title,
        leading: leading,
        subtitle: subtitle,
        content: content,
        draft: draft,
      ) = article
      echo "asserted article"
      let updated_article =
        article.draft_update(article, fn(draft) { Draft(..draft, saving: True) })
      remote_data.try_update(model.articles, dict.insert(
        _,
        draft.slug,
        ArticleFullWithDraft(
          slug,
          revision,
          title,
          leading,
          subtitle,
          content,
          draft,
        ),
      ))

      let article_draft =
        ArticleFull(
          draft.slug,
          0,
          draft.title,
          draft.leading,
          draft.subtitle,
          draft.content,
        )
      #(
        model,
        article.article_create(ArticleDraftSaveResponse(slug, _), article_draft),
      )
      // #(model, article.article_update(ArticleDraftSaveResponse(slug, _), article))
    }
    ArticleDraftSaveResponse(slug, result) -> {
      echo "article draft save response"
      let article = case model.articles {
        Loaded(articles) -> articles |> dict.get(slug)
        _ -> Error(Nil)
      }
      let articles_updated = case article {
        Ok(article) -> {
          model.articles
          |> remote_data.try_update(dict.insert(
            _,
            article.slug,
            article.draft_update(article, fn(draft) {
              Draft(..draft, saving: False)
            }),
          ))
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          model.articles
        }
      }
      case result {
        Ok(saved_article) -> {
          let updated_articles =
            remote_data.try_update(articles_updated, dict.insert(
              _,
              saved_article.slug,
              saved_article,
            ))
          #(
            Model(..model, articles: updated_articles),
            modem.push(route_url(ArticleBySlug(saved_article.slug)), None, None),
            // effect_navigation(model, ArticleBySlug(saved_article.slug)),
          )
        }

        Error(err) -> {
          todo as "what is the saving articles for?"
        }
      }
    }
    // AUTH
    AuthLoginClicked(username, password) -> {
      #(model, auth.login(AuthLoginResponse, username, password))
    }
    AuthLoginResponse(result) -> {
      #(model, effect.none())
    }
    AuthCheckClicked -> {
      #(model, auth.auth_check(AuthCheckResponse))
    }
    AuthCheckResponse(result) -> {
      echo "auth check response"
      echo result
      case result {
        Ok(response) -> {
          echo "auth check response ok"
          #(model, effect.none())
        }
        Error(err) -> {
          echo "auth check response error"
          #(model, effect.none())
        }
      }
    }

    // CHAT
    ChatMsg(msg) -> {
      let #(chat_model, chat_effect) = chat.update(msg, model.chat)
      #(Model(..model, chat: chat_model), effect.map(chat_effect, ChatMsg))
    }
  }
}

fn update_navigation(model: Model, route: Route) -> #(Model, Effect(Msg)) {
  case route {
    ArticleBySlug(slug) -> {
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      let article = dict.get(articles, slug)
      let effect_nav = case article {
        Ok(article) -> {
          case article {
            ArticleSummary(slug, _, _, _, _) -> {
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            ArticleWithError(_, _, _, _, _, _) -> {
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            _ -> effect.none()
          }
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          effect.none()
        }
      }
      #(Model(..model, route:), effect_nav)
    }
    ArticleBySlugEdit(slug) -> {
      let article = case model.articles {
        Loaded(articles) -> articles |> dict.get(slug)
        _ -> Error(Nil)
      }

      case article {
        Ok(ArticleFullWithDraft(_, _, _, _, _, _, _)) -> {
          #(Model(..model, route:), effect.none())
        }
        Ok(ArticleFull(slug, revision, title, leading, subtitle, content)) -> {
          let updated_article =
            ArticleFullWithDraft(
              slug,
              revision,
              title,
              leading,
              subtitle,
              content,
              Draft(False, slug, title, leading, subtitle, content),
            )
          let articles_updated =
            model.articles
            |> remote_data.try_update(dict.insert(_, slug, updated_article))
          #(Model(..model, route:, articles: articles_updated), effect.none())
        }
        Ok(ArticleSummary(_, _, _, _, _)) -> {
          #(
            Model(..model, route:),
            article.article_get(ArticleGot(slug, _), slug),
          )
        }
        Ok(ArticleWithError(_, _, _, _, _, _)) -> {
          #(
            Model(..model, route:),
            article.article_get(ArticleGot(slug, _), slug),
          )
        }
        Error(_) -> {
          echo "no article found for slug: " <> slug
          #(model, modem.push(route_url(Articles), None, None))
        }
      }
    }
    _ -> #(Model(..model, route:), effect.none())
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
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            ArticleWithError(_, _, _, _, _, _) -> {
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            _ -> effect.none()
          }
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          echo "set up article not found route"
          effect.none()
        }
      }
    }
    ArticleBySlugEdit(slug) -> {
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      let article = dict.get(articles, slug)
      case article {
        Ok(article) -> {
          case article {
            ArticleSummary(slug, _, _, _, _) -> {
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            ArticleWithError(_, _, _, _, _, _) -> {
              article.article_get(fn(result) { ArticleGot(slug, result) }, slug)
            }
            _ -> effect.none()
          }
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          echo "set up article not found route"
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
  case result {
    Ok(articles) -> {
      let articles = article.list_to_dict(articles)
      let effect = case model.route {
        ArticleBySlug(slug) -> {
          echo "loading article content for slug: " <> slug
          article.article_get(ArticleGot(slug, _), slug)
        }
        ArticleBySlugEdit(_) -> {
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
                  content.Text(
                    "We encountered an error while loading the articles. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  content.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  content.Text("no atempt to load articles made. This is a bug"),
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
                  content.Text(
                    "We encountered an error while loading the articles and that includes this one. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  content.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  content.Text("no atempt to load articles made. This is a bug"),
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
                      Ok(article) -> {
                        case article {
                          ArticleFullWithDraft(_, _, _, _, _, _, _) -> {
                            view_article_edit(model, article)
                          }
                          _ -> view_article(article)
                        }
                      }
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

// VIEW HEADER ----------------------------------------------------------------
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
            html.li([], [
              html.button(
                [
                  event.on_click(AuthLoginClicked("jst_dev", "jst_dev")),
                  attr.class("bg-pink-700 text-white px-2 rounded-md"),
                ],
                [html.text("Login")],
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

fn view_article_listing(articles: Dict(String, Article)) -> List(Element(Msg)) {
  let articles =
    articles
    |> dict.values
    |> list.sort(fn(a, b) { string.compare(a.slug, b.slug) })
    |> list.index_map(fn(article, _index) {
      case article {
        ArticleFull(slug, _, title, leading, subtitle, _)
        | ArticleSummary(slug, _, title, leading, subtitle)
        | ArticleFullWithDraft(slug, _, title, leading, subtitle, _, _) -> {
          html.article([attr.class("mt-14")], [
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
                  view_edit_link(article, "edit"),
                ]),
                view_subtitle(subtitle, slug),
                view_paragraph([content.Text(leading)]),
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

fn view_article_edit(model: Model, article: Article) -> List(Element(Msg)) {
  let assert Ok(index_uri) = uri.parse("/")
  echo "asserting ArticleFullWithDraft"
  let assert ArticleFullWithDraft(
    _slug,
    _revision,
    _title,
    _leading,
    _subtitle,
    _content,
    draft,
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
      html.div([attr.class("flex justify-end gap-4 mt-6")], [
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-pink-700 text-white rounded-md hover:bg-pink-600",
            ),
            event.on_click(ArticleDraftDiscardClicked(article)),
            attr.disabled(draft.saving),
          ],
          [html.text("Discard")],
        ),
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600",
            ),
            event.on_click(ArticleDraftSaveClicked(article)),
            attr.disabled(draft.saving),
          ],
          [
            case draft.saving {
              True -> html.text("Saving...")
              False -> html.text("Save")
            },
          ],
        ),
      ]),
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
  let content = case article {
    ArticleFull(slug, _revision, title, leading, subtitle, content) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleFullWithDraft(slug, _revision, title, leading, subtitle, content, _) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleSummary(slug, _revision, title, leading, subtitle) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_paragraph([content.Text("loading content..")]),
    ]
    ArticleWithError(slug, _revision, title, leading, subtitle, error) -> [
      html.div([attr.class("flex justify-between mb-4 mt-8")], [
        view_title(title, slug),
        view_edit_link(article, "edit"),
      ]),
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
        "text-gray-500 border-e pe-4 text-underline pt-2 hover:text-teal-300 hover:border-teal-300 border-t border-gray-500",
      ),
      href(ArticleBySlugEdit(article.slug)),
    ],
    [html.text(text)],
  )
}

fn view_title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class("text-3xl text-pink-700 font-light"),
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
      content.Text(text) -> html.text(text)
      content.Block(contents) -> view_block(contents)
      content.Heading(text) -> view_h2(text)
      content.Paragraph(contents) -> view_paragraph(contents)
      content.Link(url, title) -> {
        echo "url"
        echo url
        let route = parse_route(url)
        case route {
          NotFound(_) -> view_link_missing(url, title)
          _ -> view_link(route, title)
        }
      }
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
        "px-3 py-1 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600 text-sm",
      ),
      event.on_click(click_message),
    ],
    [html.text("+ " <> label)],
  )
}

// Helper function to render content editor blocks based on content type
fn view_content_editor_block(content_item: Content, index: Int) -> Element(Msg) {
  html.div([attr.class("border border-zinc-700 rounded-md p-3 bg-zinc-800")], [
    // Content type label and controls
    html.div([attr.class("flex justify-between items-center mb-2")], [
      html.span([attr.class("text-xs text-zinc-500")], [
        html.text(content_type_label(content_item)),
      ]),
      html.div([attr.class("flex gap-2")], [
        // Move up button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600",
            ),
            event.on_click(ArticleDraftContentMoveUp(content_item, index)),
            attr.disabled(index == 0),
          ],
          [html.text("↑")],
        ),
        // Move down button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600",
            ),
            event.on_click(ArticleDraftContentMoveDown(content_item, index)),
          ],
          [html.text("↓")],
        ),
        // Delete button
        html.button(
          [
            attr.class("text-xs px-2 py-1 bg-red-900 rounded hover:bg-red-800"),
            event.on_click(ArticleDraftContentRemove(content_item, index)),
          ],
          [html.text("×")],
        ),
      ]),
    ]),
    // Content editor based on type
    case content_item {
      content.Text(text) ->
        html.textarea(
          [
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.rows(3),
            attr.value(text),
            event.on_input(fn(new_text) {
              ArticleDraftContentUpdate(
                content_item,
                index,
                content.Text(new_text),
              )
            }),
          ],
          text,
        )

      content.Heading(text) ->
        html.input([
          attr.class(
            "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2 text-xl text-pink-600",
          ),
          attr.value(text),
          event.on_input(fn(new_text) {
            ArticleDraftContentUpdate(
              content_item,
              index,
              content.Heading(new_text),
            )
          }),
        ])

      content.Link(url, title) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Link text"),
            attr.value(title),
            event.on_input(fn(new_title) {
              ArticleDraftContentUpdate(
                content_item,
                index,
                content.Link(url, new_title),
              )
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("URL (e.g., /articles)"),
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
        ])

      content.LinkExternal(url, title) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Link text"),
            attr.value(title),
            event.on_input(fn(new_title) {
              ArticleDraftContentUpdate(
                content_item,
                index,
                content.LinkExternal(url, new_title),
              )
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("URL (e.g., https://example.com)"),
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
        ])

      content.Image(url, alt) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Alt text"),
            attr.value(alt),
            event.on_input(fn(new_alt) {
              ArticleDraftContentUpdate(
                content_item,
                index,
                content.Image(url, new_alt),
              )
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Image URL"),
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

// Helper function to update article content blocks
fn update_article_content_blocks(
  article: Article,
  content: List(Content),
) -> Article {
  case article {
    ArticleFull(slug, revision, title, leading, subtitle, _) ->
      ArticleFull(slug, revision, title, leading, subtitle, content)
    _ -> {
      // Convert other article types to ArticleFull with the new content
      let slug = article.slug
      let revision = article.revision
      let title = article.title
      let leading = article.leading
      let subtitle = article.subtitle
      ArticleFull(slug, revision, title, leading, subtitle, content)
    }
  }
}

// Add this helper function near your other helpers
fn list_set(list: List(a), index: Int, value: a) -> List(a) {
  list
  |> list.index_map(fn(item, i) {
    case i == index {
      True -> value
      False -> item
    }
  })
}

fn list_at(list: List(a), index: Int) -> Result(a, Nil) {
  list
  |> list.index_map(fn(item, i) { #(item, i) })
  |> list.find(fn(pair) { pair.1 == index })
  |> result.map(fn(pair) { pair.0 })
}
