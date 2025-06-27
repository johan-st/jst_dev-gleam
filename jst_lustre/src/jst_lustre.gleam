// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article, ArticleV1}
import article/draft
import birl.{type Time}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import modem
import pages/pages
import routes/routes.{type Route}
import utils/error_string
import utils/http.{type HttpError}
import utils/jot_to_lustre
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Optimistic, Pending,
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
    base_uri: Uri,
    route: Route,
    session: session.Session,
    articles: RemoteData(List(Article), HttpError),
    djot_demo_content: String,
    edit_view_mode: EditViewMode,
    profile_menu_open: Bool,
  )
}

type EditViewMode {
  EditViewModeEdit
  EditViewModePreview
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
      djot_demo_content: initial_djot,
      edit_view_mode: EditViewModeEdit,
      profile_menu_open: False,
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
  // HAMBURGER MENU
  ProfileMenuToggled
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
  ArticleDraftUpdatedSubtitle(article: Article, text: String)
  ArticleDraftUpdatedContent(article: Article, content: String)
  // ARTICLE ACTIONS
  ArticleUpdateResponse(id: String, result: Result(Article, HttpError))
  ArticleDraftSaveClicked(article: Article)
  ArticleDraftDiscardClicked(article: Article)
  ArticleCreateClicked
  ArticleCreateResponse(result: Result(Article, HttpError))
  ArticleDeleteClicked(article: Article)
  ArticleDeleteResponse(id: String, result: Result(String, HttpError))
  ArticlePublishClicked(article: Article)
  ArticleUnpublishClicked(article: Article)
  // AUTH
  AuthLoginClicked(username: String, password: String)
  AuthLoginResponse(result: Result(session.Session, HttpError))
  AuthLogoutClicked
  AuthLogoutResponse(result: Result(String, HttpError))
  AuthCheckClicked
  AuthCheckResponse(result: Result(session.Session, HttpError))
  // CHAT
  // ChatMsg(msg: chat.Msg)
  // DJOT DEMO
  DjotDemoContentUpdated(content: String)
  // EDIT VIEW TOGGLE
  EditViewModeToggled
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
    // MENU
    ProfileMenuToggled -> {
      #(
        Model(..model, profile_menu_open: !model.profile_menu_open),
        effect.none(),
      )
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
            Ok(ArticleV1(
              id:,
              slug: _,
              author: _,
              title: _,
              leading: _,
              subtitle: _,
              content: NotInitialized,
              draft: _,
              published_at: _,
              revision: _,
              tags: _,
            ))
            | Ok(ArticleV1(
                id:,
                slug: _,
                author: _,
                title: _,
                leading: _,
                subtitle: _,
                content: NotInitialized,
                draft: _,
                published_at: _,
                revision: _,
                tags: _,
              )) -> {
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
            |> remote_data.map(
              with: list.map(_, fn(article_current) {
                case id == article_current.id {
                  True -> article
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        Error(err) -> {
          let updated_articles =
            model.articles
            |> remote_data.map(
              with: list.map(_, fn(article_current) {
                case id == article_current.id {
                  True -> ArticleV1(..article_current, content: Errored(err))
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
      }
    }
    ArticleHovered(article:) -> {
      case article.content {
        NotInitialized -> {
          let updated_articles =
            model.articles
            |> remote_data.map(
              with: list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> ArticleV1(..article_current, content: Pending)
                  False -> article_current
                }
              }),
            )
          #(
            Model(..model, articles: updated_articles),
            article.article_get(
              ArticleGot(article.id, _),
              article.id,
              model.base_uri,
            ),
          )
        }
        Errored(_) -> #(
          model,
          article.article_get(
            ArticleGot(article.id, _),
            article.id,
            model.base_uri,
          ),
        )
        Pending | Loaded(_) | Optimistic(_) -> {
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
          _author,
          _tags,
          _published_at,
          _title,
          _leading,
          _subtitle,
          _content,
          draft: Some(_draft),
        ) -> {
          let updated_article =
            article.draft_update(article, fn(draft) {
              draft.set_slug(draft, text)
            })
          #(
            Model(
              ..model,
              articles: remote_data.map(
                model.articles,
                with: list.map(_, fn(article_current) {
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
      let updated_article =
        article.draft_update(article, fn(draft) { draft.set_title(draft, text) })
      let updated_articles =
        remote_data.map(
          model.articles,
          with: list.map(_, fn(article_current) {
            case article.id == article_current.id {
              True -> updated_article
              False -> article_current
            }
          }),
        )
      #(Model(..model, articles: updated_articles), effect.none())
    }
    ArticleDraftUpdatedLeading(article, text) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_leading(draft, text)
        })
      let updated_articles =
        remote_data.map(
          model.articles,
          with: list.map(_, fn(article_current) {
            case article.id == article_current.id {
              True -> updated_article
              False -> article_current
            }
          }),
        )
      #(Model(..model, articles: updated_articles), effect.none())
    }
    ArticleDraftUpdatedSubtitle(article, text) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_subtitle(draft, text)
        })
      let updated_articles =
        remote_data.map(
          model.articles,
          with: list.map(_, fn(article_current) {
            case article.id == article_current.id {
              True -> updated_article
              False -> article_current
            }
          }),
        )
      #(Model(..model, articles: updated_articles), effect.none())
    }
    ArticleDraftUpdatedContent(article, content) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_content(draft, content)
        })
      #(
        Model(
          ..model,
          articles: remote_data.map(
            model.articles,
            with: list.map(_, fn(article_current) {
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
    // ARTICLE DRAFT DISCARD
    ArticleDraftDiscardClicked(article) -> {
      echo "article draft discard clicked"
      let updated_articles =
        remote_data.map(
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
      case article.draft {
        Some(current_draft) -> {
          let updated_article =
            ArticleV1(
              ..article,
              slug: draft.slug(current_draft),
              title: draft.title(current_draft),
              leading: draft.leading(current_draft),
              subtitle: draft.subtitle(current_draft),
              content: Loaded(draft.content(current_draft)),
              draft: None,
            )
          let updated_articles =
            remote_data.map(
              model.articles,
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True -> updated_article
                  False -> article_current
                }
              }),
            )
          #(
            Model(..model, articles: updated_articles),
            effect.batch([
              article.article_update(
                ArticleUpdateResponse(updated_article.id, _),
                updated_article,
                model.base_uri,
              ),
              modem.push(
                pages.to_uri(pages.PageArticle(updated_article, model.session))
                  |> uri.to_string,
                None,
                None,
              ),
            ]),
          )
        }
        None -> #(model, effect.none())
      }
    }
    ArticleUpdateResponse(id, result) -> {
      case result {
        Ok(saved_article) -> {
          let updated_articles =
            remote_data.map(
              model.articles,
              list.map(_, fn(article_current) {
                case id == article_current.id {
                  True -> saved_article
                  False -> article_current
                }
              }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        Error(err) -> {
          echo "article update response error"
          echo err
          #(model, effect.none())
        }
      }
    }
    // AUTH
    AuthLoginClicked(username, password) -> {
      #(
        model,
        session.login(AuthLoginResponse, username, password, model.base_uri),
      )
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
    // DJOT DEMO
    DjotDemoContentUpdated(content) -> {
      #(Model(..model, djot_demo_content: content), effect.none())
    }
    // EDIT VIEW TOGGLE
    EditViewModeToggled -> {
      let new_mode = case model.edit_view_mode {
        EditViewModeEdit -> EditViewModePreview
        EditViewModePreview -> EditViewModeEdit
      }
      #(Model(..model, edit_view_mode: new_mode), effect.none())
    }
    // ARTICLE ACTIONS
    ArticleCreateClicked -> {
      echo "article create clicked"
      // Create a new article with default values
      let new_article =
        ArticleV1(
          id: "",
          // Will be set by server
          slug: "new-article",
          revision: 1,
          author: "current-user",
          // TODO: get from session
          tags: [],
          published_at: None,
          title: "New Article",
          subtitle: "A new article subtitle",
          leading: "This is a new article. Start editing to customize it.",
          content: Loaded(
            "# New Article\n\nStart writing your article content here...",
          ),
          draft: None,
        )
      #(
        model,
        article.article_create(
          ArticleCreateResponse,
          new_article,
          model.base_uri,
        ),
      )
    }
    ArticleCreateResponse(result) -> {
      case result {
        Ok(created_article) -> {
          echo "article created successfully with id: " <> created_article.id
          // Add the new article to the local state
          let updated_articles = case model.articles {
            Loaded(articles) -> Loaded([created_article, ..articles])
            other -> other
            // If articles aren't loaded, don't update
          }
          #(
            Model(..model, articles: updated_articles),
            // Navigate to edit the newly created article
            modem.push(
              routes.ArticleEdit(created_article.id)
                |> routes.to_uri
                |> uri.to_string,
              None,
              None,
            ),
          )
        }
        Error(err) -> {
          echo "article creation error"
          echo err
          // TODO: Show user-friendly error message
          #(model, effect.none())
        }
      }
    }
    ArticleDeleteClicked(article) -> {
      echo "article delete clicked"
      #(
        model,
        effect.batch([
          article.article_delete(
            ArticleDeleteResponse(article.id, _),
            article.id,
            model.base_uri,
          ),
          modem.push(
            routes.Articles |> routes.to_uri |> uri.to_string,
            None,
            None,
          ),
        ]),
      )
    }
    ArticleDeleteResponse(id, result) -> {
      case result {
        Ok(_) -> {
          let updated_articles =
            remote_data.map(
              model.articles,
              list.filter(_, fn(article_current) { article_current.id != id }),
            )
          #(Model(..model, articles: updated_articles), effect.none())
        }
        Error(err) -> {
          echo "article delete response error"
          echo err
          #(model, effect.none())
        }
      }
    }
    ArticlePublishClicked(article) -> {
      echo "article publish clicked"
      let updated_article = ArticleV1(..article, published_at: Some(birl.now()))
      #(
        model,
        article.article_update(
          ArticleUpdateResponse(article.id, _),
          updated_article,
          model.base_uri,
        ),
      )
    }
    ArticleUnpublishClicked(article) -> {
      echo "article unpublish clicked"
      #(
        model,
        article.article_update(
          ArticleUpdateResponse(article.id, _),
          ArticleV1(..article, published_at: None),
          model.base_uri,
        ),
      )
    }
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
                      article.article_get(
                        ArticleGot(art.id, _),
                        art.id,
                        model.base_uri,
                      ),
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
                      article.article_get(
                        ArticleGot(art.id, _),
                        art.id,
                        model.base_uri,
                      ),
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
    routes.DjotDemo -> #(Model(..model, route:), effect.none())
    routes.NotFound(uri) -> #(Model(..model, route:), effect.none())
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let page = page_from_model(model)
  let content = case page {
    pages.PageIndex -> view_index()
    pages.PageArticleList(articles, session) ->
      view_article_listing(articles, session)
    pages.PageArticleListLoading -> view_article_listing_loading()
    pages.PageArticle(article, session) -> view_article(article, session)
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
    pages.PageDjotDemo(content) -> view_djot_demo(content)
    pages.PageNotFound(uri) -> view_not_found(uri)
  }
  let layout = case page {
    pages.PageDjotDemo(_) | pages.PageArticleEdit(_) -> {
      fn(content) {
        html.div(
          [
            attr.class(
              "min-h-screen bg-zinc-900 text-zinc-100 selection:bg-pink-700 selection:text-zinc-100 ",
            ),
          ],
          [
            view_header(model),
            html.main([attr.class("mx-auto px-10 py-10")], content),
          ],
        )
      }
    }
    _ -> {
      fn(content) {
        html.div(
          [
            attr.class(
              "min-h-screen bg-zinc-900 text-zinc-100 selection:bg-pink-700 selection:text-zinc-100 ",
            ),
          ],
          [
            view_header(model),
            html.main(
              [attr.class("max-w-screen-md mx-auto px-10 py-10")],
              content,
            ),
          ],
        )
      }
    }
  }
  layout(content)
}

fn page_from_model(model: Model) -> pages.Page {
  case model.route {
    routes.Index -> pages.PageIndex
    routes.Articles -> {
      case model.articles {
        Pending -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error) ->
          pages.PageError(pages.HttpError(error, "Failed to load article list"))
        Loaded(articles_list) | Optimistic(articles_list) ->
          pages.PageArticleList(articles_list, model.session)
      }
    }
    routes.Article(slug) -> {
      case model.articles {
        Pending -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error) ->
          pages.PageError(pages.HttpError(error, "Failed to load articles"))
        Loaded(articles_list) | Optimistic(articles_list) -> {
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
        Pending -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error) ->
          pages.PageError(pages.HttpError(
            error,
            "Failed to load articles for editing",
          ))
        Loaded(articles_list) | Optimistic(articles_list) -> {
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
    routes.DjotDemo -> pages.PageDjotDemo(model.djot_demo_content)
    routes.About -> pages.PageAbout
    routes.NotFound(uri) -> pages.PageNotFound(uri)
  }
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(Msg) {
  html.nav(
    [attr.class("py-2 border-b bg-zinc-800 border-pink-700 font-mono relative")],
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
          html.div([attr.class("flex items-center space-x-8")], [
            // Desktop navigation
            html.ul([attr.class("hidden sm:flex space-x-8 pr-2")], [
              view_header_link(
                target: routes.Articles,
                current: model.route,
                label: "Articles",
              ),
              view_header_link(
                target: routes.About,
                current: model.route,
                label: "About",
              ),
              view_header_link(
                target: routes.DjotDemo,
                current: model.route,
                label: "Djot Demo",
              ),
            ]),
            // Hamburger menu for auth actions
            html.div([attr.class("relative")], [
              html.button(
                [
                  attr.class(
                    "p-2 rounded-md bg-zinc-700 hover:bg-zinc-600 transition-colors",
                  ),
                  event.on_mouse_down(ProfileMenuToggled),
                ],
                [
                  html.svg(
                    [
                      attr.attribute("fill", "none"),
                      attr.attribute("viewBox", "0 0 24 24"),
                      attr.attribute("stroke-width", "1.5"),
                      attr.attribute("stroke", "currentColor"),
                      attr.class("w-6 h-6"),
                    ],
                    [
                      svg.path([
                        attr.attribute("stroke-linecap", "round"),
                        attr.attribute("stroke-linejoin", "round"),
                        attr.attribute(
                          "d",
                          "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5",
                        ),
                      ]),
                    ],
                  ),
                ],
              ),
              // Dropdown menu
              case model.profile_menu_open {
                True ->
                  html.div(
                    [
                      attr.class(
                        "absolute right-0 mt-2 w-48 rounded-md shadow-lg bg-zinc-700 ring-1 ring-black ring-opacity-5 z-50",
                      ),
                    ],
                    [
                      html.div([attr.class("py-1")], [
                        html.ul(
                          [attr.class("sm:hidden flex flex-col gap-2 px-4")],
                          [
                            view_header_link(
                              target: routes.Articles,
                              current: model.route,
                              label: "Articles",
                            ),
                            view_header_link(
                              target: routes.About,
                              current: model.route,
                              label: "About",
                            ),
                            view_header_link(
                              target: routes.DjotDemo,
                              current: model.route,
                              label: "Djot Demo",
                            ),
                          ],
                        ),
                        html.button(
                          [
                            attr.class(
                              "block w-full text-left px-4 py-2 text-sm text-zinc-200 hover:bg-green-800 transition-colors cursor-pointe",
                            ),
                            attr.classes([
                              #(
                                "hidden",
                                model.session != session.Unauthenticated,
                              ),
                            ]),
                            event.on_mouse_down(AuthLoginClicked(
                              "johan-st",
                              "password",
                            )),
                          ],
                          [html.text("Login")],
                        ),
                        html.button(
                          [
                            attr.class(
                              "block w-full text-left px-4 py-2 text-sm text-zinc-200 hover:bg-orange-800 transition-colors cursor-pointe",
                            ),
                            attr.classes([
                              #(
                                "hidden",
                                model.session == session.Unauthenticated,
                              ),
                            ]),
                            event.on_mouse_down(AuthLogoutClicked),
                          ],
                          [html.text("Logout")],
                        ),
                        html.button(
                          [
                            attr.class(
                              "block w-full text-left px-4 py-2 text-sm text-zinc-200 hover:bg-teal-800 transition-colors cursor-pointe",
                            ),
                            event.on_mouse_down(AuthCheckClicked),
                          ],
                          [html.text("Check")],
                        ),
                      ]),
                    ],
                  )
                False -> html.div([], [])
              },
            ]),
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
        #(
          "border-transparent border-b-2 hover:border-pink-700 cursor-pointer",
          True,
        ),
        #("text-pink-700", routes.is_sub(route: to, maybe_sub: curr)),
      ]),
      event.on_mouse_down(UserMouseDownNavigation(to |> routes.to_uri)),
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
    view_simple_paragraph(
      "It to is a work in progress and I mostly keep it here for my own reference.",
    ),
    view_simple_paragraph(
      "I'm also a software developer and a writer. I'm also a father and a 
        husband. I'm also a software developer and a writer. I'm also a father 
        and a husband. I'm also a software developer and a writer. I'm also a 
        father and a husband. I'm also a software developer and a writer.",
    ),
  ]
}

fn view_article_listing(
  articles: List(Article),
  session: session.Session,
) -> List(Element(Msg)) {
  let filtered_articles = case session {
    session.Unauthenticated ->
      articles
      |> list.filter(fn(article) {
        case article.published_at {
          Some(_) -> True
          None -> False
        }
      })
    _ -> articles
  }

  let articles_elements =
    filtered_articles
    |> list.sort(fn(a, b) {
      case a.published_at, b.published_at {
        // Both unpublished - sort by slug
        None, None -> string.compare(a.slug, b.slug)
        // A is unpublished, B is published - A comes first
        None, Some(_) -> order.Lt
        // A is published, B is unpublished - B comes first  
        Some(_), None -> order.Gt
        // Both published - sort by date (most recent first)
        Some(date_a), Some(date_b) -> birl.compare(date_b, date_a)
      }
    })
    |> list.map(fn(article) {
      case article {
        ArticleV1(
          id: _,
          slug:,
          author: _,
          title:,
          leading:,
          subtitle:,
          content: _,
          draft: _,
          published_at: _,
          revision: _,
          tags:,
        ) -> {
          let article_uri = routes.Article(slug) |> routes.to_uri
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
                html.div([attr.class("flex justify-between gap-4")], [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl text-pink-600 font-light group-hover:text-pink-500 transition-colors"),
                    ],
                    [html.text(title)],
                  ),
                  html.div([attr.class("flex flex-col items-end")], [
                    view_publication_status(article),
                    view_author(article.author),
                  ]),
                ]),
                view_subtitle(subtitle, slug),
                view_simple_paragraph(leading),
                html.div([attr.class("flex justify-end mt-2")], [
                  view_article_tags(tags),
                ]),
              ],
            ),
          ])
        }
      }
    })

  let header_section = [
    html.div([attr.class("flex justify-between items-center mb-4")], [
      view_title("Articles", "articles"),
      case session {
        session.Authenticated(_) ->
          html.button(
            [
              attr.class(
                "text-gray-500 pe-4 text-underline pt-2 hover:text-teal-300 hover:border-teal-300 border-t border-zinc-700 border-e",
              ),
              event.on_mouse_down(ArticleCreateClicked),
            ],
            [html.text("New")],
          )
        _ -> element.none()
      },
    ]),
  ]

  list.append(header_section, articles_elements)
}

fn view_article_edit(model: Model, article: Article) -> List(Element(Msg)) {
  case article.draft {
    None -> [view_error("no draft..")]
    Some(draft) -> {
      let preview_content = case draft.content(draft) {
        "" -> "Start typing in the editor to see the preview here..."
        content -> content
      }
      let draft_article =
        article.ArticleV1(
          author: article.author,
          published_at: article.published_at,
          tags: article.tags,
          title: draft.title(draft),
          content: Loaded(preview_content),
          draft: None,
          id: article.id,
          leading: draft.leading(draft),
          revision: article.revision,
          slug: draft.slug(draft),
          subtitle: draft.subtitle(draft),
        )
      let preview = view_article(draft_article, session.Unauthenticated)

      [
        // Toggle button for mobile
        html.div([attr.class("lg:hidden mb-4 flex justify-center")], [
          html.button(
            [
              attr.class(
                "px-4 py-2 bg-pink-700 text-white rounded-md hover:bg-pink-700 transition-colors duration-200",
              ),
              event.on_mouse_down(EditViewModeToggled),
            ],
            [
              case model.edit_view_mode {
                EditViewModeEdit -> html.text("Show Preview")
                EditViewModePreview -> html.text("Show Editor")
              },
            ],
          ),
        ]),
        // Main content area
        html.div(
          [
            attr.classes([
              #("grid gap-8 h-screen", True),
              #("grid-cols-2 lg:grid-cols-2", True),
            ]),
          ],
          [
            // Editor column
            html.div(
              [
                attr.classes([
                  #("space-y-4", True),
                  #("lg:block", True),
                  #("lg:col-span-1", True),
                  #("col-span-2", model.edit_view_mode == EditViewModeEdit),
                  #("hidden", model.edit_view_mode == EditViewModePreview),
                ]),
              ],
              view_edit_actions(draft, article),
            ),
            // Preview column
            html.div(
              [
                attr.classes([
                  #("max-w-screen-md mx-auto px-10 py-10 overflow-y-auto", True),
                  #("lg:block", True),
                  #("lg:col-span-1", True),
                  #("col-span-2", model.edit_view_mode == EditViewModePreview),
                  #("hidden", model.edit_view_mode == EditViewModeEdit),
                ]),
              ],
              preview,
            ),
          ],
        ),
        view_djot_quick_reference(),
      ]
    }
  }
}

fn view_edit_actions(draft: draft.Draft, article: Article) -> List(Element(Msg)) {
  [
    // Form inputs - Slug with revision
    html.div([attr.class("mb-4")], [
      html.div([attr.class("flex items-center justify-between mb-1")], [
        html.label([attr.class("block text-sm font-medium text-zinc-400")], [
          html.text("Slug"),
        ]),
        html.span([attr.class("text-xs text-zinc-500")], [
          html.text("rev " <> int.to_string(article.revision)),
        ]),
      ]),
      html.input([
        attr.class(
          "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 font-light text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
        ),
        attr.value(draft.slug(draft)),
        attr.id("edit-" <> article.slug <> "-" <> "Slug"),
        event.on_input(ArticleDraftUpdatedSlug(article, _)),
      ]),
    ]),
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
    // Leading as textarea
    html.div([attr.class("mb-4")], [
      html.label([attr.class("block text-sm font-medium text-zinc-400 mb-1")], [
        html.text("Leading"),
      ]),
      html.textarea(
        [
          attr.class(
            "w-full h-24 bg-zinc-800 border border-zinc-600 rounded-md p-2 font-bold text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
          ),
          attr.value(draft.leading(draft)),
          attr.id("edit-" <> article.slug <> "-" <> "Leading"),
          event.on_input(ArticleDraftUpdatedLeading(article, _)),
          attr.placeholder("Write a compelling leading paragraph..."),
        ],
        draft.leading(draft),
      ),
    ]),
    // Content editor
    html.div([attr.class("mb-4")], [
      html.label([attr.class("block text-sm font-medium text-zinc-400 mb-1")], [
        html.text("Content"),
      ]),
      html.textarea(
        [
          attr.class(
            "w-full h-96 bg-zinc-800 border border-zinc-600 rounded-md p-4 font-mono text-sm text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
          ),
          attr.value(draft.content(draft)),
          event.on_input(ArticleDraftUpdatedContent(article, _)),
          attr.placeholder("Write your article content in Djot format..."),
        ],
        draft.content(draft),
      ),
    ]),
    // Action buttons
    html.div([attr.class("flex justify-between gap-4")], [
      // Article actions (left side)
      view_article_actions(article, session.Unauthenticated),
      // Draft actions (right side)  
      html.div([attr.class("flex gap-4")], [
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600 transition-colors duration-200",
            ),
            event.on_mouse_down(ArticleDraftDiscardClicked(article)),
            attr.disabled(draft.is_saving(draft)),
          ],
          [html.text("Discard Changes")],
        ),
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600 transition-colors duration-200",
            ),
            event.on_mouse_down(ArticleDraftSaveClicked(article)),
            attr.disabled(draft.is_saving(draft)),
          ],
          [
            case draft.is_saving(draft) {
              True -> html.text("Saving...")
              False -> html.text("Save Article")
            },
          ],
        ),
      ]),
    ]),
  ]
}

fn view_djot_quick_reference() -> Element(Msg) {
  // Quick reference section
  html.div(
    [attr.class("mt-8 p-4 bg-zinc-800 rounded-lg border border-zinc-700")],
    [
      html.h3([attr.class("text-lg text-pink-700 font-light")], [
        html.text("Djot Quick Reference"),
      ]),
      html.p([attr.class("text-zinc-300 mb-6")], [
        html.strong([], [html.text("Note: ")]),
        html.text("This editor uses Djot format. See the "),
        html.a(
          [
            attr.href(
              "https://htmlpreview.github.io/?https://github.com/jgm/djot/blob/master/doc/syntax.html",
            ),
            attr.class("text-zinc-300 underline"),
          ],
          [html.text("djot syntax documentation")],
        ),
        html.text(" for complete details."),
      ]),
      html.div(
        [
          attr.class(
            "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 text-sm",
          ),
        ],
        [
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Headings"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("# H1\n## H2\n### H3"),
              ]),
            ]),
          ]),
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Text"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("_italic_\n*bold*\n`code`"),
              ]),
            ]),
          ]),
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Lists"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("- item 1\n- item 2\n\n  - nested"),
              ]),
            ]),
          ]),
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Links"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("[text](url)\n[text](url){title=\"tooltip\"}"),
              ]),
            ]),
          ]),
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Code Blocks"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("```\ncode here\n```"),
              ]),
            ]),
          ]),
          html.div([], [
            html.h4([attr.class("text-pink-700 font-medium mb-2")], [
              html.text("Blockquotes"),
            ]),
            html.code([attr.class("text-zinc-300")], [
              html.pre([attr.class("text-zinc-300")], [
                html.text("> quoted text"),
              ]),
            ]),
          ]),
        ],
      ),
    ],
  )
}

fn view_article_edit_not_found(
  _available_articles: RemoteData(List(Article), HttpError),
  id: String,
) -> List(Element(Msg)) {
  [
    view_title("Article not found", id),
    view_simple_paragraph("The article you are looking for does not exist."),
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
        "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 font-light text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
      )
    ArticleEditInputTypeTitle ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-3xl text-pink-700 font-light focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
      )
    ArticleEditInputTypeSubtitle ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-md text-zinc-500 font-light focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
      )
    ArticleEditInputTypeLeading ->
      attr.class(
        "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 font-bold text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
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

fn view_article(
  article: Article,
  session: session.Session,
) -> List(Element(Msg)) {
  let content: List(Element(Msg)) = case article.content {
    NotInitialized -> [view_error("content not initialized")]
    Pending -> [view_error("loading")]
    Loaded(content_string) | Optimistic(content_string) ->
      jot_to_lustre.to_lustre(content_string)
    Errored(error) -> [view_error(error_string.http_error(error))]
  }
  [
    html.article([attr.class("with-transition")], [
      html.div([attr.class("flex flex-col justify-between")], [
        view_article_actions(article, session),
        html.div([attr.class("flex gap-2 justify-between")], [
          html.div([attr.class("flex flex-col justify-between")], [
            view_title(article.title, article.slug),
            view_subtitle(article.subtitle, article.slug),
          ]),
          html.div([attr.class("flex flex-col items-end")], [
            view_publication_status(article),
            view_author(article.author),
          ]),
        ]),
        html.div([attr.class("flex justify-between mt-2")], [
          view_article_tags(article.tags),
        ]),
      ]),
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
      view_simple_paragraph("The article you are looking for does not exist."),
    ]
    Optimistic(_articles) -> [
      view_title("Article not found", slug),
      view_simple_paragraph(
        "The article you are looking for might not exist yet. Please check back later.",
      ),
    ]
    Errored(error) -> [
      view_title("There was an error loading the article", slug),
      view_simple_paragraph(error_string.http_error(error)),
    ]
    Pending -> [
      view_title("Loading article", slug),
      view_simple_paragraph("Loading article..."),
    ]
    NotInitialized -> [
      view_title("Loading article", slug),
      view_simple_paragraph("Loading article..."),
    ]
  }
}

fn view_about() -> List(Element(Msg)) {
  [
    view_title("About", "about"),
    view_simple_paragraph(
      "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
    ),
    view_simple_paragraph(
      "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
    ),
  ]
}

fn view_not_found(requested_uri: Uri) -> List(Element(Msg)) {
  [
    view_title("404 - Page Not Found", "not-found"),
    view_subtitle("The page you're looking for doesn't exist.", "not-found"),
    view_simple_paragraph(
      "The page at " <> uri.to_string(requested_uri) <> " could not be found.",
    ),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_publication_status(article: Article) -> Element(msg) {
  case article.published_at {
    Some(published_time) -> {
      let formatted_date = birl.to_naive_date_string(published_time)
      html.span(
        [
          attr.class(
            "text-xs text-zinc-500 px-2 pt-2 w-max border-t border-r border-zinc-700 group-hover:border-pink-700 transition-colors duration-25",
          ),
        ],
        [html.text(formatted_date)],
      )
    }
    None ->
      html.span(
        [
          attr.class(
            "text-xs text-zinc-500 px-2 pt-2 w-max italic border-t border-r border-zinc-700 group-hover:border-pink-700 transition-colors duration-25",
          ),
        ],
        [html.text("not published")],
      )
  }
}

fn view_author(author: String) -> Element(msg) {
  html.div(
    [
      attr.class(
        "text-xs text-zinc-400 pt-0 border-r border-zinc-700 pr-2 group-hover:border-pink-700 transition-colors duration-25",
      ),
    ],
    [
      html.span([attr.class("text-zinc-500 font-light")], [html.text("by ")]),
      html.span([attr.class("text-zinc-300")], [html.text(author)]),
    ],
  )
}

fn view_article_tags(tags: List(String)) -> Element(Msg) {
  case tags {
    [] -> element.none()
    _ ->
      html.div(
        [
          attr.class(
            "flex justify-end align-end gap-0 ml-auto flex-wrap border-b border-r border-zinc-700 pb-1 pr-2 hover:border-pink-700 group-hover:border-pink-700 transition-colors duration-25 mt-2",
          ),
        ],
        tags
          |> list.map(fn(tag) {
            html.span(
              [
                attr.class(
                  "text-xs cursor-pointer text-zinc-500 px-2 hover:border-pink-700 hover:text-pink-700 transition-colors duration-25",
                ),
              ],
              [html.text(tag)],
            )
          }),
      )
  }
}

fn view_article_actions(
  article: Article,
  session: session.Session,
) -> Element(Msg) {
  // Determine permissions
  let can_edit = article.can_edit(article, session)
  let can_publish = article.can_publish(article, session)
  let can_delete = article.can_delete(article, session)

  html.div([attr.class("flex justify-start h-10")], [
    case can_edit {
      True ->
        html.button(
          [
            attr.class(
              "text-gray-500 pe-4 text-underline pb-2 hover:text-teal-300 hover:border-teal-300 border-b border-zinc-700",
            ),
            event.on_mouse_down(
              UserMouseDownNavigation(
                routes.to_uri(routes.ArticleEdit(article.id)),
              ),
            ),
          ],
          [html.text("Edit")],
        )
      False -> element.none()
    },
    case can_publish && { article.published_at == None } {
      True ->
        html.button(
          [
            attr.class(
              "text-gray-500 pe-4 text-underline pb-2 hover:text-green-300 hover:border-green-300 border-b border-zinc-700",
            ),
            event.on_mouse_down(ArticlePublishClicked(article)),
          ],
          [html.text("Publish")],
        )
      False -> element.none()
    },
    case can_publish && { article.published_at != None } {
      True ->
        html.button(
          [
            attr.class(
              "text-gray-500 pe-4 text-underline pb-2 hover:text-yellow-300 hover:border-yellow-300 border-b border-zinc-700",
            ),
            event.on_mouse_down(ArticleUnpublishClicked(article)),
          ],
          [html.text("Unpublish")],
        )
      False -> element.none()
    },
    case can_delete {
      True ->
        html.button(
          [
            attr.class(
              "text-gray-500 pe-4 text-underline pb-2 hover:text-red-400 hover:border-red-400 border-b border-zinc-700",
            ),
            event.on_mouse_down(ArticleDeleteClicked(article)),
          ],
          [html.text("Delete")],
        )
      False -> element.none()
    },
  ])
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
      attr.class("text-md text-zinc-500 font-light italic"),
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
      attr.class("text-2xl text-pink-700 font-light pt-16"),
      attr.class("article-h2"),
    ],
    [html.text(title)],
  )
}

// fn view_h3(title: String) -> Element(msg) {
//   html.h3(
//     [attr.class("text-xl text-pink-700 font-light"), attr.class("article-h3")],
//     [html.text(title)],
//   )
// }

// fn view_h4(title: String) -> Element(msg) {
//   html.h4(
//     [attr.class("text-lg text-pink-700 font-light"), attr.class("article-h4")],
//     [html.text(title)],
//   )
// }

fn view_simple_paragraph(text: String) -> Element(Msg) {
  html.p([attr.class("pt-8")], [html.text(text)])
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

// Content rendering functions removed - now using Djot parsing

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

// Content editor functions removed - now using simple Djot textarea

fn view_article_listing_loading() -> List(Element(Msg)) {
  [
    view_title("Articles", "articles"),
    view_simple_paragraph("Loading articles..."),
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
    view_simple_paragraph("You need to be logged in to " <> action),
  ]
}

fn view_djot_demo(content: String) -> List(Element(Msg)) {
  let preview_content = case content {
    "" -> [
      html.div([attr.class("text-zinc-500 italic text-center mt-8")], [
        html.text("Start typing in the editor to see the preview here..."),
      ]),
    ]
    _ -> jot_to_lustre.to_lustre(content)
  }

  [
    view_title("Djot Demo", "djot-demo"),
    html.div([attr.class("grid grid-cols-1 lg:grid-cols-2 gap-6")], [
      // Editor section
      html.section([attr.class("space-y-4")], [
        html.div([attr.class("flex items-center justify-between")], [
          html.h2([attr.class("text-xl text-pink-700 font-light")], [
            html.text("Editor"),
          ]),
          html.div([attr.class("text-xs text-zinc-500")], [
            html.text("Live preview updates as you type"),
          ]),
        ]),
        html.div([attr.class("relative")], [
          html.textarea(
            [
              attr.class(
                "w-full h-[400px] lg:h-[600px] bg-zinc-800 border border-zinc-600 rounded-lg p-4 font-mono text-sm text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
              ),
              attr.placeholder(
                "# Start typing your article content here...\n\n## Headings\n\n- Lists\n- Work too\n\n**Bold** and *italic* text\n\n[Link text](url)",
              ),
              attr.value(content),
              event.on_input(DjotDemoContentUpdated),
              attr.attribute("spellcheck", "false"),
            ],
            content,
          ),
          // Character count
          html.div(
            [
              attr.class(
                "absolute bottom-2 right-2 text-xs text-zinc-500 bg-zinc-800 px-2 py-1 rounded",
              ),
            ],
            [
              html.text(string.length(content) |> string.inspect),
              html.text(" chars"),
            ],
          ),
        ]),
      ]),
      // Preview section
      html.section([attr.class("space-y-4")], [
        html.div([attr.class("flex items-center justify-between")], [
          html.h2([attr.class("text-xl text-pink-700 font-light")], [
            html.text("Preview"),
          ]),
          html.div([attr.class("text-xs text-zinc-500")], [
            html.text("Rendered output"),
          ]),
        ]),
        html.div(
          [
            attr.class(
              "w-full h-[400px] lg:h-[600px] bg-zinc-900 border border-zinc-600 rounded-lg p-6 overflow-y-auto prose prose-invert prose-pink max-w-none",
            ),
          ],
          preview_content,
        ),
      ]),
    ]),
    // Quick reference section
    html.div(
      [attr.class("mt-8 p-4 bg-zinc-800 rounded-lg border border-zinc-700")],
      [
        html.h3([attr.class("text-lg text-pink-700 font-light")], [
          html.text("Quick Reference"),
        ]),
        html.p([attr.class("text-zinc-300")], [
          html.strong([], [html.text("Note: ")]),
          html.text(
            "The djot implementation is a work in progress. Not all features are supported yet.",
          ),
        ]),
        html.p([attr.class("mb-6")], [
          html.text("See the "),
          html.a(
            [
              attr.href(
                "https://htmlpreview.github.io/?https://github.com/jgm/djot/blob/master/doc/syntax.html",
              ),
              attr.class("text-zinc-300 underline"),
            ],
            [html.text("djot syntax documentation")],
          ),
          html.text(" for more details."),
        ]),
        html.div(
          [
            attr.class(
              "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 text-sm",
            ),
          ],
          [
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Headings"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("# H1\n## H2\n### H3"),
                ]),
              ]),
            ]),
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Text"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("_italic_\n*bold*\n`code`"),
                ]),
              ]),
            ]),
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Lists"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("- item 1\n- item 2\n\n  - nested"),
                ]),
              ]),
            ]),
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Links"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("[text](url)\n[text](url){title=\"tooltip\"}"),
                ]),
              ]),
            ]),
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Code Blocks"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("```\ncode here\n```"),
                ]),
              ]),
            ]),
            html.div([], [
              html.h4([attr.class("text-pink-700 font-medium mb-2")], [
                html.text("Blockquotes"),
              ]),
              html.code([attr.class("text-zinc-300")], [
                html.pre([attr.class("text-zinc-300")], [
                  html.text("> quoted text"),
                ]),
              ]),
            ]),
          ],
        ),
      ],
    ),
  ]
}

const initial_djot = "# Quick Start for Markdown users

Djot is a lot like Markdown.  Here are some of the main
differences you need to be aware of in making the transition.

#### Blank lines

In djot you need blank lines around block-level
elements.  Hence, instead of

```
This is some text.
## My next heading
```

you must write

```
This is some text.

## My next heading
```

Instead of

````
This is some text.
``` lua
local foo = bar.baz or false
```
````

you must write

````
This is some text.

``` lua
local foo = bar.baz or false
```
````

Instead of

```
Text.
> a blockquote.
```

you must write

```
Text.

> a blockquote.
```

And instead of

```
Before a thematic break.
****
After a thematic break.
```

you must write

```
Before a thematic break.

****

After a thematic break.
```

#### Lists

A special case of this is that you always need a blank line before a
list, even if it's a sublist. So, while in Markdown you can write

```
- one
  - two
  - three
```

in djot you must write

```
- one

  - two
  - three
```

#### Headings

There are no Setext-style (underlined) headings, only ATX- (`#`) style.

Heading content can extend over several lines, which may or
may not be preceded by `#` characters:

```
## This is a single
## level-2 heading

### This is a single
level-3 heading
```

As a result, headings must always have a blank line following.

Trailing `#` characters in a heading are read as part of the
content and not ignored.

#### Code blocks

There are no indented code blocks, only fenced with ` ``` `.

#### Block quotes

You need a space after the `>` character, unless it is followed
by a newline.

#### Emphasis

Use single `_` delimiters for regular emphasis and
single `*` delimiters for strong emphasis.

#### Links

There is no special syntax for adding a title to a link, as
in Markdown:

```
[link](http://example.com \"Go to my website\")
```

If you want a title attribute on a link, use the general attribute syntax:

```
[link](http://example.com){title=\"Go to my website\"}
```

#### Hard line breaks

In Markdown you can create a hard line break by ending a line
with two spaces. In djot you use a backslash before the newline.

```
A new\\
line.
```

#### Raw HTML

In Markdown you can just insert raw HTML \"as is.\"  In djot,
you must mark it as raw HTML:

````
This is raw HTML: `<a id=\"foo\">`{=html}.

Here is a raw HTML block:

``` =html
<table>
<tr><td>foo</td></tr>
</table>
```
````

#### Tables

Pipe tables always require a pipe character at the start and end
of each line, unlike in many Markdown implementations.  So, this
is not a table:

```
a|b
-|-
1|2
```

but this is:

```
| a | b |
| - | - |
| 1 | 2 |
```


#### That's enough to get started!

Here we have just focused on things that might trip up
Markdown users.  If you keep these in mind, you should be
able to start using djot without looking at any more
documentation.

However, we haven't discussed any of the things
you can do in djot but not Markdown. See the [syntax
description](https://htmlpreview.github.io/?https://github.com/jgm/djot/blob/master/doc/syntax.html)
to find about the new constructions that are available.
"
