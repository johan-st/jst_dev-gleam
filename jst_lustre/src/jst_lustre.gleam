// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article, ArticleV1}
import article/content.{type Content}
import article/draft
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import pages/pages
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
    route: Route,
    session: session.Session,
    articles: RemoteData(List(Article), HttpError),
    base_uri: Uri,
  )
}

fn init(_) -> #(Model, Effect(Msg)) {
  // if this failes we have no app to run..
  let assert Ok(uri) = modem.initial_uri()

  let model =
    Model(
      route: routes.from_uri(uri),
      session: session.Unauthenticated,
      articles: NotInitialized,
      base_uri: uri,
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> UserNavigatedTo
    })
  let #(model_nav, effect_nav) = update_navigation(model, uri)
  #(
    model_nav,
    effect.batch([
      effect_modem,
      effect_nav,
      session.auth_check(AuthCheckResponse, model.base_uri),
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
  UserMouseDownNavigation(uri: Uri)
  // MESSAGES
  // UserMessageDismissed(msg: UserMessage)
  // LOCALSTORAGE
  PersistGotModel(opt: Option(PersistentModel))
  // ARTICLES
  ArticleHovered(article: Article)
  ArticleGot(id: String, result: Result(Article, HttpError))
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
  ArticleDraftSaveResponse(id: String, result: Result(Article, HttpError))
  ArticleDraftDiscardClicked(article: Article)
  // AUTH
  AuthLoginClicked(username: String, password: String)
  AuthLoginResponse(result: Result(session.Session, HttpError))
  AuthLogoutClicked
  AuthLogoutResponse(result: Result(String, HttpError))
  AuthCheckClicked
  AuthCheckResponse(result: Result(session.Session, HttpError))
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
  case msg {
    // NAVIGATION
    UserNavigatedTo(uri) -> {
      update_navigation(model, uri)
    }
    UserMouseDownNavigation(uri) -> {
      echo "user mouse down navigation"
      echo uri
      #(model, modem.push(uri.to_string(uri), None, None))
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
      // case ok, update articles, if on article page, load content
      case result, model.route {
        Ok(articles), routes.Article(slug) -> {
          case list.find(articles, fn(article) { article.slug == slug }) {
            Ok(ArticleV1(id, _, _, _, _, _, NotInitialized, _))
            | Ok(ArticleV1(id, _, _, _, _, _, Errored(_), _)) -> {
              let articles_with_pending_content =
                list.map(articles, fn(article) {
                  case article.slug == slug {
                    True -> ArticleV1(..article, content: Pending)
                    False -> article
                  }
                })
              #(
                Model(..model, articles: Loaded(articles_with_pending_content)),
                article.article_get(ArticleGot(id, _), id, model.base_uri),
              )
            }
            Ok(_) -> todo as "article exists. content is pending or loading."
            Error(Nil) -> #(
              model,
              modem.push(
                model.route
                  |> routes.to_uri
                  |> routes.NotFound
                  |> routes.to_string,
                None,
                None,
              ),
            )
          }
        }
        Ok(articles), routes.ArticleEdit(id) -> #(
          Model(..model, articles: Loaded(articles)),
          article.article_get(ArticleGot(id, _), id, model.base_uri),
        )

        Ok(articles), _ -> #(
          Model(..model, articles: Loaded(articles)),
          effect.none(),
        )
        Error(err), _ -> #(
          Model(..model, articles: Errored(err)),
          effect.none(),
        )
      }
    }
    ArticleGot(id, result) -> {
      case result {
        Ok(article) -> {
          let assert True = id == article.id
          let updated_articles =
            model.articles
            |> remote_data.map_loaded(with: fn(article_current) {
              case id == article_current.id {
                True -> article
                False -> article_current
              }
            })
          #(Model(..model, articles: updated_articles), effect.none())
        }
        Error(err) -> {
          let updated_articles =
            model.articles
            |> remote_data.map_loaded(with: fn(article_current) {
              case id == article_current.id {
                True -> ArticleV1(..article_current, content: Errored(err))
                False -> article_current
              }
            })
          #(Model(..model, articles: updated_articles), effect.none())
        }
      }
    }
    ArticleHovered(article:) -> {
      case article.content {
        NotInitialized -> {
          let updated_articles =
            model.articles
            |> remote_data.map_loaded(with: fn(article_current) {
              case article.id == article_current.id {
                True -> ArticleV1(..article_current, content: Pending)
                False -> article_current
              }
            })
          #(
            Model(..model, articles: updated_articles),
            article.article_get(ArticleGot(article.id, _), article.id, model.base_uri),
          )
        }
        Errored(_) -> #(
          model,
          article.article_get(ArticleGot(article.id, _), article.id, model.base_uri),
        )
        Pending | Loaded(_) -> {
          #(model, effect.none())
        }
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
          Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_slug(draft, text)
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
        _ -> #(model, effect.none())
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
          Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_title(draft, text)
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
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedLeading(article, text) -> {
      case article {
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_leading(draft, text)
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
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftUpdatedSubtitle(article, text) -> {
      case article {
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_subtitle(draft, text)
            })
          let updated_articles =
            remote_data.map_loaded(model.articles, fn(article_current) {
              case article.id == article_current.id {
                True -> updated_article
                False -> article_current
              }
            })
          #(Model(..model, articles: updated_articles), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftAddContent(article, content) -> {
      case article {
        ArticleV1(
          _id,
          _slug,
          _revision,
          _title,
          _leading,
          _subtitle,
          _content,
          Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_content(
                draft,
                list.append(draft.content(draft), [content]),
              )
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
        _ -> #(model, effect.none())
      }
    }
    ArticleDraftContentMoveUp(_content_item, _index) -> {
      todo as "move up"
      #(model, effect.none())
    }
    ArticleDraftContentMoveDown(_content_item, _index) -> {
      todo as "move down"
      #(model, effect.none())
    }
    ArticleDraftContentRemove(_content_item, _index) -> {
      todo as "remove"
      #(model, effect.none())
    }
    ArticleDraftContentUpdate(_content_item, _index, _text) -> {
      todo as "update"
      #(model, effect.none())
    }

    // ARTICLE DRAFT DISCARD
    ArticleDraftDiscardClicked(article) -> {
      echo "article draft discard clicked"
      let updated_articles =
        remote_data.try_update(
          model.articles,
          list.map(_, fn(article_current) {
            case article.id == article_current.id {
              True -> ArticleV1(..article, draft: None)
              False -> article_current
            }
          }),
        )
      #(
        Model(..model, articles: updated_articles),
        modem.push(
          pages.to_uri(pages.PageArticle(article, model.session))
            |> uri.to_string,
          None,
          None,
        ),
      )
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
      #(model, session.login(AuthLoginResponse, username, password, model.base_uri))
    }
    AuthLoginResponse(session_result) -> {
      case session_result {
        Ok(session) -> #(Model(..model, session: session), effect.none())
        Error(err) -> {
          echo err
          #(Model(..model, session: session.Unauthenticated), effect.none())
        }
      }
    }
    AuthLogoutClicked -> {
      #(
        Model(..model, session: session.Unauthenticated),
        session.auth_logout(AuthLogoutResponse, model.base_uri),
      )
    }
    AuthLogoutResponse(_result) -> {
      #(Model(..model, session: session.Unauthenticated), effect.none())
    }
    AuthCheckClicked -> {
      #(model, session.auth_check(AuthCheckResponse, model.base_uri))
    }
    AuthCheckResponse(result) -> {
      case result {
        Ok(session) -> {
          #(Model(..model, session:), effect.none())
        }
        Error(err) -> {
          echo "session check response error"
          echo err
          #(Model(..model, session: session.Unauthenticated), effect.none())
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

fn update_navigation(model: Model, uri: Uri) -> #(Model, Effect(Msg)) {
  let route = routes.from_uri(uri)
  case route {
    routes.About -> #(Model(..model, route:), effect.none())
    routes.Article(slug) -> {
      case model.articles {
        NotInitialized -> #(
          Model(..model, route:, articles: Pending),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        Loaded(articles) -> {
          let #(effect, articles_updated) =
            list.map_fold(
              over: articles,
              from: effect.none(),
              with: fn(eff, art) {
                case art.slug == slug, art.content {
                  True, NotInitialized -> #(
                    effect.batch([
                      eff,
                      article.article_get(ArticleGot(art.id, _), art.id, model.base_uri),
                    ]),
                    ArticleV1(..art, content: Pending),
                  )
                  _, _ -> #(eff, art)
                }
              },
            )
          #(Model(..model, route:, articles: Loaded(articles_updated)), effect)
        }
        _ -> #(Model(..model, route:), effect.none())
      }
    }
    routes.ArticleEdit(id) ->
      case model.articles {
        NotInitialized -> #(
          Model(..model, route:, articles: Pending),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        Loaded(articles) -> {
          let #(effect, articles_updated) =
            list.map_fold(
              over: articles,
              from: effect.none(),
              with: fn(eff, art) {
                let art = case art.draft {
                  Some(_) -> art
                  None -> ArticleV1(..art, draft: article.to_draft(art))
                }
                case art.id == id, art.content {
                  True, NotInitialized -> #(
                    effect.batch([
                      eff,
                      article.article_get(ArticleGot(art.id, _), art.id, model.base_uri),
                    ]),
                    ArticleV1(
                      ..art,
                      draft: article.to_draft(art),
                      content: Pending,
                    ),
                  )
                  _, _ -> #(eff, art)
                }
              },
            )
          echo routes.to_string(route)
          #(Model(..model, route:, articles: Loaded(articles_updated)), effect)
        }
        _ -> #(Model(..model, route:), effect.none())
      }
    routes.Articles -> {
      case model.articles {
        NotInitialized -> #(
          Model(..model, route:, articles: Pending),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        _ -> #(Model(..model, route:), effect.none())
      }
    }
    routes.Index -> #(Model(..model, route:), effect.none())
    routes.NotFound(uri) -> #(Model(..model, route:), effect.none())
  }
}

// fn update_navigation_2(model: Model, new_uri: Uri) -> #(Model, Effect(Msg)) {
//   case uri.path_segments(new_uri.path) {
//     ["article", slug] -> {
//       echo "article"
//       case model.articles {
//         NotInitialized | Errored(_) -> {
//           echo "update_navigation, article: articles not initialized"
//           #(
//             Model(
//               ..model,
//               page: pages.from_uri(new_uri, model.session, Pending),
//               articles: Pending,
//             ),
//             article.article_metadata_get(ArticleMetaGot),
//           )
//         }
//         Loaded(articles) -> {
//           case list.find(articles, fn(article) { article.slug == slug }) {
//             Ok(ArticleV1(id, _, _, _, _, _, NotInitialized, _))
//             | Ok(ArticleV1(id, _, _, _, _, _, Errored(_), _)) -> {
//               echo "update_navigation, article: content not initialized or errored"
//               let articles_updated =
//                 list.map(articles, fn(art) {
//                   case art.slug == slug {
//                     True -> ArticleV1(..art, content: Pending)
//                     False -> art
//                   }
//                 })
//                 |> Loaded
//               #(
//                 Model(
//                   ..model,
//                   uri: new_uri,
//                   articles: articles_updated,
//                   page: pages.from_uri(new_uri, model.session, articles_updated),
//                 ),
//                 article.article_get(fn(result) { ArticleGot(id, result) }, id),
//               )
//             }
//             _ -> #(
//               Model(
//                 ..model,
//                 uri: new_uri,
//                 page: pages.from_uri(new_uri, model.session, model.articles),
//               ),
//               effect.none(),
//             )
//           }
//         }
//         _ -> #(
//           Model(
//             ..model,
//             uri: new_uri,
//             page: pages.from_uri(new_uri, model.session, model.articles),
//           ),
//           effect.none(),
//         )
//       }
//     }
//     ["article", id, "edit"] -> {
//       echo "article edit"
//       case model.articles {
//         Loaded(articles) -> {
//           case
//             list.find(articles, fn(article) {
//               article_id.to_string(article.id) == id
//             })
//           {
//             Error(_) -> {
//               #(
//                 Model(
//                   ..model,
//                   uri: new_uri,
//                   page: pages.from_uri(new_uri, model.session, model.articles),
//                 ),
//                 effect.none(),
//               )
//             }
//             Ok(article) -> {
//               case article {
//                 ArticleV1(_, _, _, _, _, _, _, draft: Some(_)) -> #(
//                   Model(
//                     ..model,
//                     uri: new_uri,
//                     page: pages.from_uri(new_uri, model.session, model.articles),
//                   ),
//                   effect.none(),
//                 )
//                 ArticleV1(_, _, _, _, _, _, content: Loaded(_), draft: None) -> {
//                   echo "article edit full, no draft"
//                   let articles_updated =
//                     remote_data.try_update(
//                       model.articles,
//                       list.map(_, fn(article_current) {
//                         case article.id == article_current.id {
//                           True ->
//                             ArticleV1(
//                               ..article,
//                               draft: Some(article.to_draft(article)),
//                             )
//                           False -> article_current
//                         }
//                       }),
//                     )
//                   #(
//                     Model(
//                       ..model,
//                       uri: new_uri,
//                       articles: articles_updated,
//                       page: pages.from_uri(
//                         new_uri,
//                         model.session,
//                         articles_updated,
//                       ),
//                     ),
//                     effect.none(),
//                   )
//                 }
//                 ArticleV1(id, _, _, _, _, _, NotInitialized, _) -> {
//                   let articles_updated =
//                     remote_data.try_update(
//                       model.articles,
//                       list.map(_, fn(article_current) {
//                         case article.id == article_current.id {
//                           True -> ArticleV1(..article, content: Pending)
//                           False -> article_current
//                         }
//                       }),
//                     )
//                   #(
//                     Model(
//                       ..model,
//                       uri: new_uri,
//                       articles: articles_updated,
//                       page: pages.from_uri(
//                         new_uri,
//                         model.session,
//                         articles_updated,
//                       ),
//                     ),
//                     article.article_get(ArticleGot(id, _), id),
//                   )
//                 }
//                 ArticleV1(id, _, _, _, _, _, Errored(_), _) -> {
//                   let articles_updated =
//                     remote_data.try_update(
//                       model.articles,
//                       list.map(_, fn(article_current) {
//                         case article.id == article_current.id {
//                           True -> ArticleV1(..article, content: Pending)
//                           False -> article_current
//                         }
//                       }),
//                     )
//                   #(
//                     Model(
//                       ..model,
//                       uri: new_uri,
//                       articles: articles_updated,
//                       page: pages.from_uri(
//                         new_uri,
//                         model.session,
//                         articles_updated,
//                       ),
//                     ),
//                     article.article_get(ArticleGot(id, _), id),
//                   )
//                 }
//                 ArticleV1(_, _, _, _, _, _, Pending, _) -> #(
//                   Model(
//                     ..model,
//                     uri: new_uri,
//                     page: pages.from_uri(new_uri, model.session, model.articles),
//                   ),
//                   effect.none(),
//                 )
//               }
//             }
//           }
//         }
//         _ -> {
//           #(
//             Model(
//               ..model,
//               uri: new_uri,
//               page: pages.from_uri(new_uri, model.session, model.articles),
//             ),
//             effect.none(),
//           )
//         }
//       }
//     }
//     ["articles"] -> {
//       echo "articles"
//       case model.articles {
//         Errored(err) -> {
//           echo "articles errored"
//           echo err
//           #(
//             Model(
//               ..model,
//               uri: new_uri,
//               articles: Pending,
//               page: pages.from_uri(new_uri, model.session, model.articles),
//             ),
//             article.article_metadata_get(ArticleMetaGot),
//           )
//         }
//         NotInitialized -> {
//           echo "articles not initialized"
//           #(
//             Model(
//               ..model,
//               uri: new_uri,
//               articles: Pending,
//               page: pages.from_uri(new_uri, model.session, model.articles),
//             ),
//             article.article_metadata_get(ArticleMetaGot),
//           )
//         }
//         _ -> #(
//           Model(
//             ..model,
//             uri: new_uri,
//             page: pages.from_uri(new_uri, model.session, model.articles),
//           ),
//           effect.none(),
//         )
//       }
//     }
//     _ -> #(
//       Model(
//         ..model,
//         uri: new_uri,
//         page: pages.from_uri(new_uri, model.session, model.articles),
//       ),
//       effect.none(),
//     )
//   }
// }

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div([attr.class("min-h-screen bg-zinc-900 text-zinc-100")], [
    view_header(model),
    html.main(
      [attr.class("max-w-screen-md mx-auto px-10 py-10")],
      case page_from_model(model) {
        pages.PageIndex -> view_index()
        pages.PageArticleList(articles, session) ->
          view_article_listing(articles, session)
        pages.PageArticleListLoading -> view_article_listing_loading()
        pages.PageArticle(article, session) ->
          view_article(article, article.can_edit(article, session))
        pages.PageArticleEdit(article) -> view_article_edit(model, article)
        pages.PageError(error) -> {
          case error {
            pages.ArticleNotFound(slug, _) ->
              view_article_not_found(model.articles, slug)
            pages.ArticleEditNotFound(id) ->
              view_article_edit_not_found(model.articles, id)
            pages.HttpError(error, _) -> [
              view_error(error_string.http_error(error)),
            ]
            pages.AuthenticationRequired(action) -> [
              view_error("Authentication required: " <> action),
            ]
            pages.Other(msg) -> [view_error(msg)]
          }
        }
        pages.PageAbout -> view_about()
        pages.PageNotFound(uri) -> view_not_found(uri)
      },
    ),
  ])
}

fn page_from_model(model: Model) -> pages.Page {
  case model.route {
    routes.Index -> pages.PageIndex
    routes.Articles -> {
      case model.articles {
        remote_data.Pending -> pages.PageArticleListLoading
        remote_data.NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        remote_data.Errored(error) ->
          pages.PageError(pages.HttpError(error, "Failed to load article list"))
        remote_data.Loaded(articles_list) ->
          pages.PageArticleList(articles_list, model.session)
      }
    }
    routes.Article(slug) -> {
      case model.articles {
        remote_data.Pending -> pages.PageArticleListLoading
        remote_data.NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        remote_data.Errored(error) ->
          pages.PageError(pages.HttpError(error, "Failed to load articles"))
        remote_data.Loaded(articles_list) -> {
          case list.find(articles_list, fn(art) { art.slug == slug }) {
            Ok(article) -> pages.PageArticle(article, model.session)
            Error(_) ->
              pages.PageError(pages.ArticleNotFound(
                slug,
                pages.get_available_slugs(articles_list),
              ))
          }
        }
      }
    }
    routes.ArticleEdit(id) -> {
      case model.articles {
        remote_data.Pending -> pages.PageArticleListLoading
        remote_data.NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        remote_data.Errored(error) ->
          pages.PageError(pages.HttpError(
            error,
            "Failed to load articles for editing",
          ))
        remote_data.Loaded(articles_list) -> {
          case list.find(articles_list, fn(art) { art.id == id }) {
            Ok(article) -> {
              case article.can_edit(article, model.session), article.draft {
                // TODO: this should be refactored.. the draft should be on the actual article and not on the one in the Page
                True, Some(_) -> pages.PageArticleEdit(article)
                True, None ->
                  pages.PageArticleEdit(
                    article.ArticleV1(
                      ..article,
                      draft: article.to_draft(article),
                    ),
                  )
                False, _ ->
                  pages.PageError(pages.AuthenticationRequired("edit article"))
              }
            }
            Error(_) -> pages.PageError(pages.ArticleEditNotFound(id))
          }
        }
      }
    }
    routes.About -> pages.PageAbout
    routes.NotFound(uri) -> pages.PageNotFound(uri)
  }
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
            view_internal_link(pages.to_uri(pages.PageIndex), [
              html.text("jst.dev"),
            ]),
          ]),
          html.ul([attr.class("flex space-x-8 pr-2")], [
            html.li([], [
              html.button(
                [
                  event.on_mouse_down(AuthLoginClicked("johan-st", "password")),
                  attr.class("bg-pink-700 text-white px-2 rounded-md"),
                ],
                [html.text("Login")],
              ),
            ]),
            html.li([], [
              html.button(
                [
                  event.on_mouse_down(AuthLogoutClicked),
                  attr.class("bg-pink-700 text-white px-2 rounded-md"),
                ],
                [html.text("Logout")],
              ),
            ]),
            html.li([], [
              html.button(
                [
                  event.on_mouse_down(AuthCheckClicked),
                  attr.class("bg-teal-700 text-white px-2 rounded-md"),
                ],
                [html.text("Check")],
              ),
            ]),
            view_header_link(
              // target: pages.PageArticleList([], model.session),
              target: routes.Articles,
              current: model.route,
              label: "Articles",
            ),
            view_header_link(
              target: routes.About,
              current: model.route,
              label: "About",
            ),
          ]),
        ],
      ),
    ],
  )
}

fn view_header_link(
  target to: Route,
  current curr: Route,
  label text: String,
) -> Element(Msg) {
  html.li(
    [
      attr.classes([
        #("border-transparent border-b-2 hover:border-pink-700", True),
        #("text-pink-700", routes.is_sub(route: to, maybe_sub: curr)),
      ]),
    ],
    [view_internal_link(to |> routes.to_uri, [html.text(text)])],
  )
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(Msg)) {
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

fn view_article_listing(
  articles: List(Article),
  session: session.Session,
) -> List(Element(Msg)) {
  let articles_elements =
    articles
    |> list.sort(fn(a, b) { string.compare(a.slug, b.slug) })
    |> list.map(fn(article) {
      case article {
        ArticleV1(_, slug, _, title, leading, subtitle, _content, _draft_option) -> {
          let article_uri = routes.Article(article.slug) |> routes.to_uri
          html.article([attr.class("mt-14")], [
            html.a(
              [
                attr.class(
                  "group block border-l border-zinc-700 pl-4 hover:border-pink-700 transition-colors duration-25",
                ),
                attr.href(uri.to_string(article_uri)),
                event.on_mouse_enter(ArticleHovered(article)),
                event.on_mouse_down(UserMouseDownNavigation(article_uri)),
              ],
              [
                html.div([attr.class("flex justify-between gap-4 h-6")], [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl text-pink-600 font-light group-hover:text-pink-500 transition-colors"),
                    ],
                    [html.text(title)],
                  ),
                  case article.can_edit(article, session) {
                    True -> view_edit_link(article, "edit")
                    False -> element.none()
                  },
                ]),
                view_subtitle(subtitle, slug),
                html.p([
                  attr.class("mt-3 line-clamp-3 text-zinc-400"),
                ], [html.text(leading)]),
              ],
            ),
          ])
        }
      }
    })
  [view_title("Articles", "articles"), ..articles_elements]
}

fn view_article_edit(_model: Model, article: Article) -> List(Element(Msg)) {
  let assert Ok(index_uri) = uri.parse("/")
  case article.draft {
    None -> [view_error("creating draft..")]
    Some(draft) -> {
      [
        html.article([attr.class("with-transition")], [
          view_article_edit_input(
            "Slug",
            ArticleEditInputTypeSlug,
            draft.slug(draft),
            ArticleDraftUpdatedSlug(article, _),
            article.slug,
          ),
          view_article_edit_input(
            "Title",
            ArticleEditInputTypeTitle,
            draft.title(draft),
            ArticleDraftUpdatedTitle(article, _),
            article.slug,
          ),
          view_article_edit_input(
            "Subtitle",
            ArticleEditInputTypeSubtitle,
            draft.subtitle(draft),
            ArticleDraftUpdatedSubtitle(article, _),
            article.slug,
          ),
          view_article_edit_input(
            "Leading",
            ArticleEditInputTypeLeading,
            draft.leading(draft),
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
              list.index_map(draft.content(draft), fn(content_item, index) {
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
                event.on_mouse_down(ArticleDraftDiscardClicked(article)),
                attr.disabled(draft.is_saving(draft)),
              ],
              [html.text("Discard")],
            ),
            html.button(
              [
                attr.class(
                  "px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600",
                ),
                event.on_mouse_down(ArticleDraftSaveClicked(article)),
                attr.disabled(draft.is_saving(draft)),
              ],
              [
                case draft.is_saving(draft) {
                  True -> html.text("Saving...")
                  False -> html.text("Save")
                },
              ],
            ),
          ]),
        ]),
      ]
    }
  }
}

fn view_article_edit_not_found(
  _available_articles: RemoteData(List(Article), HttpError),
  id: String,
) -> List(Element(Msg)) {
  [
    view_title("Article not found", id),
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

fn view_article(article: Article, can_edit: Bool) -> List(Element(Msg)) {
  let edit_button = case can_edit {
    True -> view_edit_link(article, "Edit")
    False -> element.none()
  }
  let content: List(Element(Msg)) = case article.content {
    NotInitialized -> [view_error("content not initialized")]
    Pending -> [view_error("loading")]
    Loaded(content) -> view_article_content(content)
    Errored(error) -> [view_error(error_string.http_error(error))]
  }
  [
    html.article([attr.class("with-transition")], [
      html.div([attr.class("flex justify-between gap-4")], [
        view_title(article.title, article.slug),
        edit_button,
      ]),
      view_subtitle(article.subtitle, article.slug),
      view_leading(article.leading, article.slug),
      ..content
    ]),
  ]
}

fn view_article_not_found(
  available_articles: RemoteData(List(Article), HttpError),
  slug: String,
) -> List(Element(Msg)) {
  case available_articles {
    Loaded(_articles) -> [
      view_title("Article not found", slug),
      view_paragraph([
        content.Text("The article you are looking for does not exist."),
      ]),
    ]
    Errored(error) -> [
      view_title("There was an error loading the article", slug),
      view_paragraph([content.Text(error_string.http_error(error))]),
    ]
    Pending -> [
      view_title("Loading article", slug),
      view_paragraph([content.Text("Loading article...")]),
    ]
    NotInitialized -> [
      view_title("Loading article", slug),
      view_paragraph([content.Text("Loading article...")]),
    ]
  }
}

fn view_about() -> List(Element(Msg)) {
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

fn view_not_found(requested_uri: Uri) -> List(Element(Msg)) {
  [
    view_title("404 - Page Not Found", "not-found"),
    view_subtitle("The page you're looking for doesn't exist.", "not-found"),
    view_paragraph([
      content.Text(
        "The page at " <> uri.to_string(requested_uri) <> " could not be found.",
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
      attr.href(routes.to_string(routes.ArticleEdit(article.id))),
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

fn view_paragraph(contents: List(Content)) -> Element(Msg) {
  html.p([attr.class("pt-8")], view_article_content(contents))
}

fn view_error(error_string: String) -> Element(Msg) {
  html.p([attr.class("pt-8 text-orange-500")], [html.text(error_string)])
}

fn view_link(url: Uri, title: String) -> Element(Msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("text-pink-700 hover:underline cursor-pointer"),
      event.on_mouse_down(UserMouseDownNavigation(url)),
    ],
    [html.text(title)],
  )
}

fn view_link_external(url: Uri, title: String) -> Element(Msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("text-pink-700 hover:underline cursor-pointer"),
      attr.target("_blank"),
    ],
    [html.text(title)],
  )
}

fn view_link_missing(url: Uri, title: String) -> Element(Msg) {
  html.a(
    [
      event.on_mouse_down(UserMouseDownNavigation(url)),
      attr.href(uri.to_string(url)),
      attr.class("hover:underline cursor-pointer"),
    ],
    [
      html.span([attr.class("text-orange-500")], [html.text("broken link: ")]),
      html.text(title),
    ],
  )
}

fn view_block(contents: List(Content)) -> Element(Msg) {
  html.div([attr.class("pt-8")], view_article_content(contents))
}

fn view_list(items: List(Content)) -> Element(Msg) {
  html.ul(
    [attr.class("pt-8 list-disc list-inside")],
    items
      |> list.map(fn(item) {
        html.li([attr.class("pt-1")], view_article_content([item]))
      }),
  )
}

fn view_unknown(content_type: String) -> Element(Msg) {
  html.span([attr.class("text-orange-500")], [
    html.text("<unknown: " <> content_type <> ">"),
  ])
}

// VIEW ARTICLE CONTENT --------------------------------------------------------

fn view_article_content(contents: List(Content)) -> List(Element(Msg)) {
  let view_content = fn(content: Content) -> Element(Msg) {
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
      event.on_mouse_down(click_message),
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
            event.on_mouse_down(ArticleDraftContentMoveUp(content_item, index)),
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
            event.on_mouse_down(ArticleDraftContentMoveDown(content_item, index)),
          ],
          [html.text("↓")],
        ),
        // Delete button
        html.button(
          [
            attr.class("text-xs px-2 py-1 bg-red-900 rounded hover:bg-red-800"),
            event.on_mouse_down(ArticleDraftContentRemove(content_item, index)),
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

fn view_article_listing_loading() -> List(Element(Msg)) {
  [
    view_title("Articles", "articles"),
    view_paragraph([content.Text("Loading articles...")]),
  ]
}

fn view_internal_link(uri: Uri, content: List(Element(Msg))) -> Element(Msg) {
  html.a(
    [
      attr.class(""),
      attr.href(uri.to_string(uri)),
      event.on_mouse_down(UserMouseDownNavigation(uri)),
    ],
    content,
  )
}

fn view_authentication_required(action: String) -> List(Element(Msg)) {
  [
    view_title("Authentication Required", "auth-required"),
    view_paragraph([content.Text("You need to be logged in to " <> action)]),
  ]
}
