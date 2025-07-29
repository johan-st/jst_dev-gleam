// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article, ArticleV1}
import article/draft
import birl
import components/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/set.{type Set}
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{type Attribute} as attr
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
import utils/icon
import utils/jot_to_lustre
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Optimistic, Pending,
}
import utils/session
import utils/short_url.{
  type ShortUrl, type ShortUrlCreateRequest, type ShortUrlListResponse,
  type ShortUrlUpdateRequest,
}
import helpers

@external(javascript, "./app.ffi.mjs", "clipboard_copy")
fn clipboard_copy(text: String) -> Nil

@external(javascript, "./app.ffi.mjs", "set_timeout")
fn set_timeout(callback: fn() -> Nil, delay: Int) -> Nil



// MAIN ------------------------------------------------------------------------

pub fn main() {
  // let app = lustre.application(init, update, view)
  let app = lustre.application(init, update_with_localstorage, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

pub type Model {
  Model(
    base_uri: Uri,
    route: Route,
    session: session.Session,
    articles: RemoteData(List(Article), HttpError),
    short_urls: RemoteData(List(ShortUrl), HttpError),
    short_url_form_short_code: String,
    short_url_form_target_url: String,
    djot_demo_content: String,
    edit_view_mode: EditViewMode,
    profile_menu_open: Bool,
    notice: String,
    debug_use_local_storage: Bool,
    delete_confirmation: option.Option(String),
    copy_feedback: option.Option(String),
    expanded_urls: Set(String),
    login_form_open: Bool,
    login_username: String,
    login_password: String,
    login_loading: Bool,
  )
}

pub type EditViewMode {
  EditViewModeEdit
  EditViewModePreview
}

fn init(_) -> #(Model, Effect(Msg)) {
  // if this failes we have no app to run..
  let assert Ok(uri) = modem.initial_uri()

  let local_storage_effect =
    persist.localstorage_get(
      persist.model_localstorage_key,
      persist.decoder(),
      GotLocalModelResult,
    )

  let model =
    Model(
      route: routes.from_uri(uri),
      session: session.Unauthenticated,
      articles: NotInitialized,
      short_urls: NotInitialized,
      short_url_form_short_code: "",
      short_url_form_target_url: "",
      base_uri: uri,
      djot_demo_content: initial_djot,
      edit_view_mode: EditViewModeEdit,
      profile_menu_open: False,
      notice: "",
      debug_use_local_storage: True,
      delete_confirmation: None,
      copy_feedback: None,
      expanded_urls: set.new(),
      login_form_open: False,
      login_username: "",
      login_password: "",
      login_loading: False,
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> UserNavigatedTo
    })

  // let #(model_nav, effect_nav) = update_navigation(model, uri)
  #(
    model,
    effect.batch([
      effect_modem,
      local_storage_effect,
      // effect_nav,
      session.auth_check(AuthCheckResponse, model.base_uri),
    ]),
  )
}

// pub fn flags_get(msg) -> Effect(Msg) {
//   let url = "http://127.0.0.1:1234/priv/static/flags.json"
//   http.get(url, http.expect_json(article_decoder(), msg))
// }

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  UserNavigatedTo(uri: Uri)
  UserMouseDownNavigation(uri: Uri)
  ProfileMenuToggled
  NoticeCleared
  PersistGotModel(opt: Option(PersistentModel))
  ArticleHovered(article: Article)
  ArticleGot(id: String, result: Result(Article, HttpError))
  ArticleMetaGot(result: Result(List(Article), HttpError))
  ArticleDraftUpdatedSlug(article: Article, text: String)
  ArticleDraftUpdatedTitle(article: Article, text: String)
  ArticleDraftUpdatedLeading(article: Article, text: String)
  ArticleDraftUpdatedSubtitle(article: Article, text: String)
  ArticleDraftUpdatedContent(article: Article, content: String)
  ArticleUpdateResponse(id: String, result: Result(Article, HttpError))
  ArticleDraftSaveClicked(article: Article)
  ArticleDraftDiscardClicked(article: Article)
  ArticleCreateClicked
  ArticleCreateResponse(result: Result(Article, HttpError))
  ArticleDeleteClicked(article: Article)
  ArticleDeleteResponse(id: String, result: Result(String, HttpError))
  ArticlePublishClicked(article: Article)
  ArticleUnpublishClicked(article: Article)
  AuthLoginClicked(username: String, password: String)
  AuthLoginResponse(result: Result(session.Session, HttpError))
  AuthLogoutClicked
  AuthLogoutResponse(result: Result(String, HttpError))
  AuthCheckClicked
  AuthCheckResponse(result: Result(session.Session, HttpError))
  DjotDemoContentUpdated(content: String)
  ShortUrlCreateClicked(short_code: String, target_url: String)
  ShortUrlCreateResponse(result: Result(ShortUrl, HttpError))
  ShortUrlListGot(result: Result(ShortUrlListResponse, HttpError))
  ShortUrlDeleteClicked(id: String)
  ShortUrlDeleteResponse(id: String, result: Result(String, HttpError))
  ShortUrlDeleteConfirmClicked(id: String)
  ShortUrlDeleteCancelClicked
  ShortUrlFormShortCodeUpdated(text: String)
  ShortUrlFormTargetUrlUpdated(text: String)
  ShortUrlCopyClicked(short_code: String)
  ShortUrlCopyFeedbackCleared
  ShortUrlToggleActiveClicked(id: String, is_active: Bool)
  ShortUrlToggleActiveResponse(id: String, result: Result(ShortUrl, HttpError))
  ShortUrlToggleExpanded(id: String)
  EditViewModeToggled
  DebugToggleLocalStorage
  GotLocalModelResult(res: Option(PersistentModel))
  LoginFormToggled
  LoginUsernameUpdated(String)
  LoginPasswordUpdated(String)
  LoginFormSubmitted
}

fn update_with_localstorage(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case model.debug_use_local_storage {
    True -> {
      let #(new_model, effect) = update(model, msg)
      let persistent_model = fn(model: Model) -> PersistentModel {
        PersistentModelV1(articles: case model.articles {
          NotInitialized -> []
          Pending -> []
          Loaded(articles) -> articles
          Optimistic(_) -> []
          Errored(_) -> []
        })
      }
      case msg {
        ArticleMetaGot(_) -> {
          persist.localstorage_set(
            persist.model_localstorage_key,
            persist.encode(persistent_model(new_model)),
          )
        }
        ArticleGot(_, _) -> {
          persist.localstorage_set(
            persist.model_localstorage_key,
            persist.encode(persistent_model(new_model)),
          )
        }
        _ -> Nil
      }
      #(new_model, effect)
    }
    False -> update(model, msg)
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // LOCAL MODEL
    GotLocalModelResult(res) -> {
      echo "GotLocalModelResult called"
      echo res
      let uri = routes.to_uri(model.route)
      case res {
        Some(persistent_model) -> {
          case persistent_model {
            PersistentModelV0 -> update_navigation(model, uri)
            PersistentModelV1(articles:) ->
              update_navigation(
                Model(
                  ..model,
                  debug_use_local_storage: True,
                  articles: Loaded(articles),
                ),
                uri,
              )
          }
        }
        None -> {
          Model(..model, debug_use_local_storage: False)
          |> update_navigation(uri)
          |> fetch_articles_model()
        }
      }
    }

    // LOGIN FORM HANDLERS
    LoginFormToggled -> {
      #(
        Model(
          ..model,
          login_form_open: !model.login_form_open,
          login_username: "",
          login_password: "",
        ),
        effect.none(),
      )
    }
    LoginUsernameUpdated(username) -> {
      #(Model(..model, login_username: username), effect.none())
    }
    LoginPasswordUpdated(password) -> {
      #(Model(..model, login_password: password), effect.none())
    }
    LoginFormSubmitted -> {
      case model.login_username, model.login_password {
        "", _ | _, "" -> #(model, effect.none())
        // Don't submit with empty fields
        username, password -> {
          #(
            Model(..model, login_loading: True, session: session.Pending),
            session.login(AuthLoginResponse, username, password, model.base_uri),
          )
        }
      }
    }

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
    // Messages
    NoticeCleared -> {
      #(Model(..model, notice: ""), effect.none())
    }
    // Browser Persistance
    PersistGotModel(opt:) -> {
      case opt {
        Some(PersistentModelV1(articles)) -> {
          #(Model(..model, articles: Loaded(articles)), effect.none())
        }
        Some(PersistentModelV0) -> {
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
            Ok(_) -> {
              echo "article exists. content is pending or loading."
              #(model, effect.none())
            }
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
              draft: Some(current_draft),
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
        Model(..model, notice: "login, CLICK", session: session.Pending),
        session.login(AuthLoginResponse, username, password, model.base_uri),
      )
    }
    AuthLoginResponse(session_result) -> {
      case session_result {
        Ok(session) -> #(
          Model(
            ..model,
            session: session,
            notice: "Successfully logged in",
            login_form_open: False,
            login_loading: False,
            login_username: "",
            login_password: "",
          ),
          effect.none(),
        )
        Error(err) -> {
          echo err
          #(
            Model(
              ..model,
              session: session.Unauthenticated,
              notice: "Login failed. Please check your credentials.",
              login_loading: False,
            ),
            effect.none(),
          )
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
      #(
        Model(..model, notice: "auth check, CLICK"),
        session.auth_check(AuthCheckResponse, model.base_uri),
      )
    }
    AuthCheckResponse(result) -> {
      case result {
        Ok(session) -> {
          #(Model(..model, session:, notice: "auth check, OK"), effect.none())
        }
        Error(err) -> {
          echo "session check response error"
          echo err
          #(
            Model(
              ..model,
              session: session.Unauthenticated,
              notice: "auth check, ERROR",
            ),
            effect.none(),
          )
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
          title: "",
          subtitle: "",
          leading: "",
          content: Loaded(""),
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
    // SHORT URLS
    ShortUrlCreateClicked(short_code, target_url) -> {
      let #(is_valid, _) = helpers.validate_target_url(target_url)
      case is_valid, model.session {
        True, session.Authenticated(_session_data) -> {
          let req =
            short_url.ShortUrlCreateRequest(
              short_code: short_code,
              target_url: target_url,
            )
          #(
            model,
            short_url.create_short_url(
              ShortUrlCreateResponse,
              model.base_uri,
              req,
            ),
          )
        }
        False, _ -> #(model, effect.none())
        _, _ -> #(model, effect.none())
      }
    }
    ShortUrlCreateResponse(result) -> {
      case result {
        Ok(short_url) -> {
          let updated_short_urls = case model.short_urls {
            NotInitialized -> Loaded([short_url])
            Pending -> Loaded([short_url])
            Loaded(urls) -> Loaded([short_url, ..urls])
            Optimistic(_) -> Loaded([short_url])
            Errored(_) -> Loaded([short_url])
          }
          #(Model(..model, short_urls: updated_short_urls), effect.none())
        }
        Error(err) -> {
          #(Model(..model, short_urls: Errored(err)), effect.none())
        }
      }
    }
    ShortUrlListGot(result) -> {
      case result {
        Ok(response) -> {
          #(
            Model(..model, short_urls: Loaded(response.short_urls)),
            effect.none(),
          )
        }
        Error(err) -> {
          #(Model(..model, short_urls: Errored(err)), effect.none())
        }
      }
    }
    ShortUrlDeleteClicked(id) -> {
      #(Model(..model, delete_confirmation: Some(id)), effect.none())
    }
    ShortUrlDeleteConfirmClicked(id) -> {
      #(
        Model(..model, delete_confirmation: None),
        short_url.delete_short_url(
          fn(result) { ShortUrlDeleteResponse(id, result) },
          model.base_uri,
          id,
        ),
      )
    }
    ShortUrlDeleteCancelClicked -> {
      #(Model(..model, delete_confirmation: None), effect.none())
    }
    ShortUrlDeleteResponse(id, result) -> {
      case result {
        Ok(_) -> {
          let updated_short_urls = case model.short_urls {
            NotInitialized -> NotInitialized
            Pending -> Pending
            Loaded(urls) -> Loaded(list.filter(urls, fn(url) { url.id != id }))
            Optimistic(_) -> NotInitialized
            Errored(_) -> NotInitialized
          }
          #(
            Model(..model, short_urls: updated_short_urls),
            modem.push(
              uri.to_string(routes.to_uri(routes.UrlShortIndex)),
              None,
              None,
            ),
          )
        }
        Error(_) -> #(model, effect.none())
      }
    }

    ShortUrlFormShortCodeUpdated(text) -> {
      #(Model(..model, short_url_form_short_code: text), effect.none())
    }
    ShortUrlFormTargetUrlUpdated(text) -> {
      #(Model(..model, short_url_form_target_url: text), effect.none())
    }
    ShortUrlCopyClicked(short_code) -> {
      let url = "u.jst.dev/" <> short_code
      clipboard_copy(url)
      #(
        Model(..model, copy_feedback: Some(short_code)),
        effect.from(fn(dispatch) {
          // Clear feedback after 2 seconds
          set_timeout(fn() { dispatch(ShortUrlCopyFeedbackCleared) }, 2000)
        }),
      )
    }
    ShortUrlCopyFeedbackCleared -> {
      #(Model(..model, copy_feedback: None), effect.none())
    }
    ShortUrlToggleActiveClicked(id, is_active) -> {
      let update_req =
        short_url.ShortUrlUpdateRequest(id: id, is_active: Some(!is_active))
      #(
        model,
        short_url.update_short_url(
          fn(result) { ShortUrlToggleActiveResponse(id, result) },
          model.base_uri,
          update_req,
        ),
      )
    }
    ShortUrlToggleActiveResponse(id, result) -> {
      case result {
        Ok(updated_url) -> {
          let updated_short_urls = case model.short_urls {
            NotInitialized -> NotInitialized
            Pending -> Pending
            Loaded(urls) ->
              Loaded(
                list.map(urls, fn(url) {
                  case url.id == id {
                    True -> updated_url
                    False -> url
                  }
                }),
              )
            Optimistic(_) -> NotInitialized
            Errored(_) -> NotInitialized
          }
          #(Model(..model, short_urls: updated_short_urls), effect.none())
        }
        Error(err) -> {
          #(Model(..model, short_urls: Errored(err)), effect.none())
        }
      }
    }
    ShortUrlToggleExpanded(id) -> {
      let updated_expanded_urls = case set.contains(model.expanded_urls, id) {
        True -> set.delete(model.expanded_urls, id)
        False -> set.insert(model.expanded_urls, id)
      }
      #(Model(..model, expanded_urls: updated_expanded_urls), effect.none())
    }
    DebugToggleLocalStorage -> {
      // Fells a bit wierd to call a function just for the side-effect and not use the result.. 
      case model.debug_use_local_storage {
        True -> persist.localstorage_set(persist.model_localstorage_key, "")
        False -> {
          let persistent_model = {
            PersistentModelV1(articles: case model.articles {
              NotInitialized -> []
              Pending -> []
              Loaded(articles) -> articles
              Optimistic(_) -> []
              Errored(_) -> []
            })
          }
          persist.localstorage_set(
            persist.model_localstorage_key,
            persist.encode(persistent_model),
          )
        }
      }
      #(
        Model(..model, debug_use_local_storage: !model.debug_use_local_storage),
        effect.none(),
      )
    }
  }
}

fn fetch_articles_model(model_effect_touple) -> #(Model, Effect(Msg)) {
  echo "fetch_articles_model called"
  let #(model, effect) = model_effect_touple

  let model = Model(..model, articles: remote_data.Pending)
  let effect =
    effect.batch([
      effect,
      article.article_metadata_get(ArticleMetaGot, model.base_uri),
    ])

  #(model, effect)
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
    routes.UrlShortIndex -> {
      case model.short_urls {
        NotInitialized -> #(
          Model(..model, route:, short_urls: Pending),
          short_url.list_short_urls(ShortUrlListGot, model.base_uri, 10, 0),
        )
        _ -> #(Model(..model, route:), effect.none())
      }
    }
    routes.UrlShortInfo(short_code) -> #(Model(..model, route:), effect.none())
    routes.DjotDemo -> #(Model(..model, route:), effect.none())
    routes.NotFound(_uri) -> #(Model(..model, route:), effect.none())
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let page = page_from_model(model)
  let content = case page {
    pages.Loading(_) -> view_loading()
    pages.PageIndex -> view_index()
    pages.PageArticleList(articles, session) ->
      view_article_listing(articles, session)
    pages.PageArticleListLoading -> view_article_listing_loading()
    pages.PageArticle(article, session) -> view_article(article, session)
    pages.PageArticleEdit(article, _) -> view_article_edit(model, article)
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
    pages.PageUrlShortIndex(_) -> view_url_index(model)
    pages.PageUrlShortInfo(short, _) -> view_url_info_page(model, short)
    pages.PageDjotDemo(content) -> view_djot_demo(content)
    pages.PageNotFound(uri) -> view_not_found(uri)
  }
  let layout = case page {
    pages.PageDjotDemo(_) | pages.PageArticleEdit(_, _) -> {
      fn(content) {
        html.div(
          [
            attr.class(
              "min-h-screen bg-zinc-900 text-zinc-100 selection:bg-pink-700 selection:text-zinc-100 ",
            ),
          ],
          [
            view_notice(model.notice),
            view_header(model),
            html.main([attr.class("mx-auto px-10 py-10")], content),
            view_modals(model),
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
            view_notice(model.notice),
            view_header(model),
            html.main(
              [attr.class("max-w-screen-md mx-auto px-10 py-10")],
              content,
            ),
            view_modals(model),
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
                True, Some(_) -> {
                  case model.session {
                    session.Authenticated(session_auth) ->
                      pages.PageArticleEdit(article, session_auth)
                    _ ->
                      pages.PageError(pages.AuthenticationRequired("edit article"))
                  }
                }
                True, None -> {
                  case model.session {
                    session.Authenticated(session_auth) ->
                      pages.PageArticleEdit(
                        article.ArticleV1(
                          ..article,
                          draft: article.to_draft(article),
                        ),
                        session_auth,
                      )
                    _ ->
                      pages.PageError(pages.AuthenticationRequired("edit article"))
                  }
                }
                False, _ ->
                  pages.PageError(pages.AuthenticationRequired("edit article"))
              }
            }
            Error(_) -> pages.PageError(pages.ArticleEditNotFound(id))
          }
        }
      }
    }
    routes.UrlShortIndex -> {
      case model.session {
        session.Authenticated(session_auth) ->
          pages.PageUrlShortIndex(session_auth)
        _ ->
          pages.PageError(pages.AuthenticationRequired("access URL shortener"))
      }
    }
    routes.UrlShortInfo(short_code) -> {
      case model.session {
        session.Authenticated(session_auth) ->
          pages.PageUrlShortInfo(short_code, session_auth)
        _ ->
          pages.PageError(pages.AuthenticationRequired("access URL shortener info"))
      }
    }
    routes.DjotDemo -> pages.PageDjotDemo(model.djot_demo_content)
    routes.About -> pages.PageAbout
    routes.NotFound(uri) -> pages.PageNotFound(uri)
  }
}

fn view_notice(notice: String) -> Element(Msg) {
  echo notice
  element.none()
  // case notice {
  //   "" -> element.none()
  //  notice ->
  //   html.div(
  //    [
  //     event.on_click(NoticeCleared),
  //    attr.class(
  //     "h-5 w-full cursor-pointer bg-zinc-700 text-mono text-zinc-200 text-xs px-8",
  //  ),
  //  ],
  // [html.text(notice)],
  // )
  // }
}

fn view_modals(model: Model) -> Element(Msg) {
  case model.login_form_open {
    True -> view_login_modal(model)
    False -> element.none()
  }
}

fn view_login_modal(model: Model) -> Element(Msg) {
  html.div([], [
    ui.modal_backdrop(LoginFormToggled),
    ui.modal(
      "Sign In",
      [
        ui.form_input(
          "Username",
          model.login_username,
          "Enter your username",
          "text",
          True,
          None,
          LoginUsernameUpdated,
        ),
        ui.form_input(
          "Password",
          model.login_password,
          "Enter your password",
          "password",
          True,
          None,
          LoginPasswordUpdated,
        ),
      ],
      [
        ui.button_action("Cancel", ui.ButtonRed, False, LoginFormToggled),
        ui.button_action(
          case model.login_loading {
            True -> "Signing In..."
            False -> "Sign In →"
          },
          ui.ButtonTeal,
          model.login_username == "" || model.login_password == "",
          LoginFormSubmitted,
        ),
      ],
      LoginFormToggled,
    ),
  ])
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(Msg) {
  let top_nav_attributes_small = [
    attr.class(
      "block w-full text-left px-4 py-2 text-sm text-zinc-400 hover:text-teal-300 hover:bg-teal-800/20 transition-colors cursor-pointer",
    ),
  ]
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
            html.ul([attr.class("hidden sm:flex space-x-8 pr-2")], 
              list.flatten([
                [
                  view_header_link(
                    target: routes.Articles,
                    current: model.route,
                    label: "Articles",
                    attributes: [],
                  ),
                  view_header_link(
                    target: routes.About,
                    current: model.route,
                    label: "About",
                    attributes: [],
                  ),
                ],
                case model.session {
                  session.Authenticated(_) -> [
                    view_header_link(
                      target: routes.UrlShortIndex,
                      current: model.route,
                      label: "Short Urls",
                      attributes: [],
                    ),
                  ]
                  _ -> []
                },
                [
                  view_header_link(
                    target: routes.DjotDemo,
                    current: model.route,
                    label: "Djot Demo",
                    attributes: [],
                  ),
                ],
              ])
            ),
            // Hamburger menu for auth actions
            html.div([attr.class("relative")], [
              html.button(
                [
                  attr.class(
                    "px-4 py-2 border-l-2 border-teal-600 border-r border-r-zinc-700 border-t border-t-zinc-700 border-b border-b-zinc-700 bg-zinc-800 hover:bg-teal-500/10 hover:border-l-teal-400 transition-colors duration-200",
                  ),
                  event.on_mouse_down(ProfileMenuToggled),
                ],
                [
                  case model.profile_menu_open {
                    True -> icon.view([attr.class("w-6 h-6")], icon.Close)
                    False -> icon.view([attr.class("w-6 h-6")], icon.Menu)
                  },
                ],
              ),
              // Dropdown menu
              case model.profile_menu_open {
                True ->
                  html.div(
                    [
                      attr.class(
                        "absolute right-0 mt-2 w-48 shadow-lg bg-zinc-800 border-l-2 border-teal-600 border-r border-r-zinc-700 border-t border-t-zinc-700 border-b border-b-zinc-700 z-50",
                      ),
                    ],
                    [
                      html.div([attr.class("py-1")], [
                        html.ul(
                          [
                            attr.class(
                              "sm:hidden flex flex-col border-b border-zinc-400",
                            ),
                          ],
                          list.flatten([
                            [
                              view_header_link(
                                target: routes.Articles,
                                current: model.route,
                                label: "Articles",
                                attributes: top_nav_attributes_small,
                              ),
                              view_header_link(
                                target: routes.About,
                                current: model.route,
                                label: "About",
                                attributes: top_nav_attributes_small,
                              ),
                            ],
                            case model.session {
                              session.Authenticated(_) -> [
                                view_header_link(
                                  target: routes.UrlShortIndex,
                                  current: model.route,
                                  label: "Short urls",
                                  attributes: top_nav_attributes_small,
                                ),
                              ]
                              _ -> []
                            },
                            [
                              view_header_link(
                                target: routes.DjotDemo,
                                current: model.route,
                                label: "Djot Demo",
                                attributes: top_nav_attributes_small,
                              ),
                            ],
                          ])
                        ),
                        case model.session {
                          session.Unauthenticated -> {
                            html.button(
                              [
                                attr.class(
                                  "block w-full text-left px-4 py-2 text-sm text-teal-400 border-l border-teal-600 hover:text-teal-300 hover:bg-teal-500/10 hover:border-l-teal-400 transition-colors cursor-pointer",
                                ),
                                event.on_mouse_down(LoginFormToggled),
                              ],
                              [html.text("Login")],
                            )
                          }
                          session.Pending -> {
                            html.button(
                              [
                                attr.class(
                                  "block w-full text-left px-4 py-2 text-sm bg-zinc-700 text-zinc-500 transition-colors cursor-not-allowed opacity-60",
                                ),
                                event.on_mouse_down(AuthLogoutClicked),
                              ],
                              [html.text("logging in..")],
                            )
                          }
                          session.Authenticated(_auth_sess) -> {
                            html.button(
                              [
                                attr.class(
                                  "block w-full text-left px-4 py-2 text-sm text-orange-400 border-l border-orange-600 hover:text-orange-300 hover:bg-orange-500/10 hover:border-l-orange-400 transition-colors cursor-pointer",
                                ),
                                event.on_mouse_down(AuthLogoutClicked),
                              ],
                              [html.text("Logout")],
                            )
                          }
                        },
                        html.button(
                          [
                            attr.class(
                              "block w-full text-left px-4 py-2 text-sm text-zinc-400 hover:text-teal-300 hover:bg-teal-800/20 transition-colors cursor-pointer",
                            ),
                            event.on_mouse_down(AuthCheckClicked),
                          ],
                          [html.text("Check")],
                        ),
                        case model.debug_use_local_storage {
                          True ->
                            html.button(
                              [
                                attr.class(
                                  "block w-full text-left px-4 py-2 text-sm text-zinc-400 hover:text-orange-300 hover:bg-orange-800/20 transition-colors cursor-pointer",
                                ),
                                event.on_mouse_down(DebugToggleLocalStorage),
                              ],
                              [
                                html.div([attr.class("flex justify-between")], [
                                  html.text("LocalStorage"),
                                  icon.view(
                                    [attr.class("w-6 text-green-400")],
                                    icon.Checkmark,
                                  ),
                                ]),
                              ],
                            )
                          False ->
                            html.button(
                              [
                                attr.class(
                                  "block w-full text-left px-4 py-2 text-sm text-zinc-400 hover:text-teal-300 hover:bg-teal-800/20 transition-colors cursor-pointer",
                                ),
                                event.on_mouse_down(DebugToggleLocalStorage),
                              ],
                              [
                                html.div([attr.class("flex justify-between ")], [
                                  html.text("LocalStorage"),
                                  icon.view(
                                    [attr.class("w-6 text-orange-400")],
                                    icon.Close,
                                  ),
                                ]),
                              ],
                            )
                        },
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
  attributes extra_attr: List(Attribute(Msg)),
) -> Element(Msg) {
  html.li(
    list.append(extra_attr, [
      attr.classes([
        #("relative cursor-pointer transition-all duration-300 ease-out px-3 py-2 rounded-lg", True),
        #("active text-pink-500", routes.is_sub(route: to, maybe_sub: curr)),
      ]),
      event.on_mouse_down(UserMouseDownNavigation(to |> routes.to_uri)),
    ]),
    [view_internal_link(to |> routes.to_uri, [html.text(text)])],
  )
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(Msg)) {
  let assert Ok(nats_uri) = uri.parse("/article/nats-all-the-way-down")
  [
    ui.page_header(
      "Welcome to jst.dev!", 
      Some("...or, A lesson on overengineering for fun and... well just for fun.")
    ),
    ui.content_container([
      html.div([attr.class("prose prose-lg text-zinc-300 max-w-none")], [
        html.p([attr.class("text-xl leading-relaxed mb-8")], [
          html.text(
            "This site and its underlying IT infrastructure is the primary 
            place for me to experiment with technologies and topologies. I 
            also share some of my thoughts and learnings here."
          ),
        ]),
        html.p([attr.class("mb-6")], [
          html.text(
            "This site and its underlying IT infrastructure is the primary 
            place for me to experiment with technologies and topologies. I 
            also share some of my thoughts and learnings here. Feel free to 
            check out my overview: "
          ),
          ui.link_primary("NATS all the way down →", UserMouseDownNavigation(nats_uri)),
        ]),
        html.p([attr.class("mb-6")], [
          html.text("It too is a work in progress and I mostly keep it here for my own reference."),
        ]),
        html.p([attr.class("mb-6")], [
          html.text(
            "I'm a software developer and writer, exploring modern technologies 
            and sharing insights from my experiments. This space serves as both 
            a playground for new ideas and a platform for documenting the journey."
          ),
        ]),
      ]),
    ]),
  ]
}

fn view_loading() -> List(Element(Msg)) {
  [ui.loading_state("Loading page...")]
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
                  html.div([attr.class("flex flex-col")], [
                    html.h3(
                      [
                        attr.id("article-title-" <> slug),
                        attr.class("article-title"),
                        attr.class("text-xl text-pink-700 font-light"),
                      ],
                      [html.text(title)],
                    ),
                    view_subtitle(subtitle, slug),
                  ]),
                  html.div([attr.class("flex flex-col items-end")], [
                    view_publication_status(article),
                    view_author(article.author),
                  ]),
                ]),
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
    ui.flex_between(
      ui.page_title("Articles"),
      case session {
        session.Authenticated(_) ->
          ui.button_action("New Article", ui.ButtonTeal, False, ArticleCreateClicked)
        _ -> element.none()
      },
    ),
  ]

  // Show helpful message when no articles are available
  let content_section = case articles_elements {
    [] -> [
      ui.empty_state(
        "No articles yet",
        case session {
          session.Authenticated(_) ->
            "Ready to share your thoughts? Create your first article to get started."
          _ -> "No published articles are available yet. Check back later for new content!"
        },
        case session {
          session.Authenticated(_) ->
            Some(ui.button_action("Create Your First Article", ui.ButtonTeal, False, ArticleCreateClicked))
          _ -> None
        },
      ),
    ]
    _ -> articles_elements
  }

  list.append(header_section, content_section)
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
          ui.button_secondary(
            case model.edit_view_mode {
              EditViewModeEdit -> "Show Preview"
              EditViewModePreview -> "Show Editor"
            },
            False,
            EditViewModeToggled,
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
    Pending -> [ui.loading_indicator_bar(), ui.loading_indicator_subtle()]
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

fn view_url_index(model: Model) -> List(Element(Msg)) {
  [
    view_title("URL Shortener", "url-shortener"),
    view_simple_paragraph("Create and manage short URLs for easy sharing."),
    view_url_create_form(model),
    view_url_list(model),
  ]
}

fn view_url_create_form(model: Model) -> Element(Msg) {
  html.div(
    [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
    [
      html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
        html.text("Create Short URL"),
      ]),
      html.div([attr.class("space-y-4")], [
        html.div([], [
          html.label(
            [attr.class("block text-sm font-medium text-zinc-300 mb-2")],
            [html.text("Target URL")],
          ),
          html.input([
            attr.class(
              case helpers.validate_target_url(model.short_url_form_target_url) {
                #(_, Some(_)) ->
                  "w-full px-3 py-2 bg-zinc-700 border border-red-500 rounded-md text-zinc-100 focus:outline-none focus:border-red-400"
                #(_, None) ->
                  "w-full px-3 py-2 bg-zinc-700 border border-zinc-600 rounded-md text-zinc-100 focus:outline-none focus:border-pink-500"
              },
            ),
            attr.placeholder("https://example.com"),
            attr.type_("url"),
            attr.value(model.short_url_form_target_url),
            event.on_input(ShortUrlFormTargetUrlUpdated),
          ]),
          case helpers.validate_target_url(model.short_url_form_target_url) {
            #(_, Some(error_msg)) ->
              html.p([attr.class("text-xs text-red-400 mt-1")], [
                html.text(error_msg),
              ])
            #(True, None) ->
              html.p([attr.class("text-xs text-green-400 mt-1")], [
                html.text("✓ Valid URL"),
              ])
            #(False, None) -> element.none()
          },
        ]),
        html.div([], [
          html.label(
            [attr.class("block text-sm font-medium text-zinc-300 mb-2")],
            [
              html.text("Short Code"),
              html.span([attr.class("text-xs text-zinc-500 font-normal ml-2")], [
                html.text("(optional)"),
              ]),
            ],
          ),
          html.input([
            attr.class(
              "w-full px-3 py-2 bg-zinc-700 border border-zinc-600 rounded-md text-zinc-100 focus:outline-none focus:border-pink-500",
            ),
            attr.placeholder("Leave empty for random code"),
            attr.type_("text"),
            attr.value(model.short_url_form_short_code),
            event.on_input(ShortUrlFormShortCodeUpdated),
          ]),
          html.p([attr.class("text-xs text-zinc-500 mt-1")], [
            html.text(
              "Only fill this if you want a specific short code. Otherwise, a random one will be generated.",
            ),
          ]),
        ]),
        html.button(
          [
            attr.class(
              case helpers.validate_target_url(model.short_url_form_target_url) {
                #(True, None) ->
                  "w-full px-4 py-2 bg-pink-600 text-white rounded-md hover:bg-pink-700 transition-colors"
                _ ->
                  "w-full px-4 py-2 bg-gray-600 text-gray-300 rounded-md cursor-not-allowed"
              },
            ),
            attr.disabled(
              case helpers.validate_target_url(model.short_url_form_target_url) {
                #(True, None) -> False
                _ -> True
              },
            ),
            event.on_mouse_down(ShortUrlCreateClicked(
              model.short_url_form_short_code,
              model.short_url_form_target_url,
            )),
          ],
          [html.text("Create Short URL")],
        ),
      ]),
    ],
  )
}

fn view_url_list(model: Model) -> Element(Msg) {
  case model.short_urls {
    NotInitialized ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          ui.loading_indicator_small(),
        ],
      )
    Pending ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          ui.loading_indicator_small(),
        ],
      )
    Loaded(short_urls) -> {
      case short_urls {
        [] ->
          html.div(
            [
              attr.class(
                "mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700",
              ),
            ],
            [
              html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
                html.text("URLs"),
              ]),
              html.div([attr.class("text-center py-12")], [
                html.div([attr.class("text-zinc-400 text-lg mb-2")], [
                  html.text("No short URLs created yet."),
                ]),
                html.div([attr.class("text-zinc-500 text-sm")], [
                  html.text("Create your first short URL using the form above."),
                ]),
              ]),
            ],
          )
        _ -> {
          let url_elements =
            list.map(short_urls, fn(url) {
              let is_expanded = set.contains(model.expanded_urls, url.id)

              case is_expanded {
                True -> view_expanded_url_card(model, url)
                False -> view_compact_url_card(model, url)
              }
            })
          html.div(
            [
              attr.class(
                "mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700",
              ),
            ],
            [
              html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
                html.text("URLs"),
              ]),
              html.ul(
                [attr.class("space-y-2"), attr.role("list")],
                url_elements,
              ),
              case model.delete_confirmation {
                Some(delete_id) ->
                  view_delete_confirmation(delete_id, short_urls)
                None -> element.none()
              },
            ],
          )
        }
      }
    }
    Errored(error) ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          html.div([attr.class("text-center py-12")], [
            html.div([attr.class("text-red-400 text-lg mb-2")], [
              html.text("Error loading short URLs"),
            ]),
            html.div([attr.class("text-zinc-500 text-sm")], [
              html.text(error_string.http_error(error)),
            ]),
          ]),
        ],
      )
    Optimistic(_) ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          ui.loading_indicator_small(),
        ],
      )
  }
}

fn view_compact_url_card(model: Model, url: ShortUrl) -> Element(Msg) {
  html.li(
    [
      attr.class(
        "bg-zinc-800 border border-zinc-700 rounded-lg transition-colors",
      ),
    ],
    [
      // Fixed header section that stays in place
      html.div([attr.class("flex items-center justify-between p-4")], [
        html.div([attr.class("flex items-center space-x-4 flex-1 min-w-0")], [
          // Short URL - clickable to copy
          html.button(
            [
              attr.class(
                "font-mono text-sm font-medium text-zinc-100 hover:text-pink-300 transition-colors cursor-pointer",
              ),
              event.on_mouse_down(ShortUrlCopyClicked(url.short_code)),
              attr.title("Click to copy short URL"),
            ],
            [
              html.span([attr.class("text-zinc-500")], [html.text("u.jst.dev/")]),
              html.span([attr.class("text-pink-400")], [
                html.text(url.short_code),
              ]),
              case model.copy_feedback == Some(url.short_code) {
                True ->
                  html.span([attr.class("ml-2 text-green-400 text-xs")], [
                    html.text("✓ Copied!"),
                  ])
                False -> element.none()
              },
            ],
          ),
          // Target URL (truncated) - clickable to expand
          html.div(
            [
              attr.class(
                "text-sm text-zinc-400 truncate flex-1 cursor-pointer hover:text-zinc-300 transition-colors",
              ),
              attr.title(url.target_url),
              event.on_mouse_down(ShortUrlToggleExpanded(url.id)),
            ],
            [
              html.span([attr.class("text-zinc-600")], [html.text("→ ")]),
              html.text(url.target_url),
            ],
          ),
          // Status badge - clickable to toggle active state
          html.button(
            [
              attr.class(case url.is_active {
                True ->
                  "inline-flex shrink-0 items-center rounded-full bg-green-600/20 px-2 py-1 text-xs font-medium text-green-400 ring-1 ring-inset ring-green-600/30 cursor-pointer hover:bg-green-600/30 transition-colors"
                False ->
                  "inline-flex shrink-0 items-center rounded-full bg-red-600/20 px-2 py-1 text-xs font-medium text-red-400 ring-1 ring-inset ring-red-600/30 cursor-pointer hover:bg-red-600/30 transition-colors"
              }),
              event.on_mouse_down(ShortUrlToggleActiveClicked(
                url.id,
                url.is_active,
              )),
              attr.title("Toggle active/inactive"),
            ],
            [
              html.text(case url.is_active {
                True -> "Active"
                False -> "Inactive"
              }),
            ],
          ),
          // Access count - clickable to expand
          html.div(
            [
              attr.class(
                "text-xs text-zinc-500 shrink-0 cursor-pointer hover:text-zinc-400 transition-colors",
              ),
              event.on_mouse_down(ShortUrlToggleExpanded(url.id)),
            ],
            [html.text(int.to_string(url.access_count) <> " clicks")],
          ),
        ]),
        // Expand indicator - clickable to expand
        html.div(
          [
            attr.class(
              "flex items-center space-x-2 ml-4 cursor-pointer hover:text-zinc-300 transition-colors",
            ),
            event.on_mouse_down(ShortUrlToggleExpanded(url.id)),
          ],
          [html.div([attr.class("text-zinc-500 text-sm")], [html.text("▼")])],
        ),
      ]),
    ],
  )
}

fn view_expanded_url_card(model: Model, url: ShortUrl) -> Element(Msg) {
  html.li(
    [
      attr.class(
        "bg-zinc-800 border border-zinc-700 rounded-lg transition-colors",
      ),
    ],
    [
      // Fixed header section - identical to compact view
      html.div([attr.class("flex items-center justify-between p-4")], [
        html.div([attr.class("flex items-center space-x-4 flex-1 min-w-0")], [
          // Short URL - clickable to copy
          html.button(
            [
              attr.class(
                "font-mono text-sm font-medium text-zinc-100 hover:text-pink-300 transition-colors cursor-pointer",
              ),
              event.on_mouse_down(ShortUrlCopyClicked(url.short_code)),
              attr.title("Click to copy short URL"),
            ],
            [
              html.span([attr.class("text-zinc-500")], [html.text("u.jst.dev/")]),
              html.span([attr.class("text-pink-400")], [
                html.text(url.short_code),
              ]),
              case model.copy_feedback == Some(url.short_code) {
                True ->
                  html.span([attr.class("ml-2 text-green-400 text-xs")], [
                    html.text("✓ Copied!"),
                  ])
                False -> element.none()
              },
            ],
          ),
          // Target URL (truncated) - shows same as compact
          html.div(
            [
              attr.class("text-sm text-zinc-400 truncate flex-1"),
              attr.title(url.target_url),
            ],
            [
              html.span([attr.class("text-zinc-600")], [html.text("→ ")]),
              html.text(url.target_url),
            ],
          ),
          // Status badge - clickable to toggle active state
          html.button(
            [
              attr.class(case url.is_active {
                True ->
                  "inline-flex shrink-0 items-center rounded-full bg-green-600/20 px-2 py-1 text-xs font-medium text-green-400 ring-1 ring-inset ring-green-600/30 cursor-pointer hover:bg-green-600/30 transition-colors"
                False ->
                  "inline-flex shrink-0 items-center rounded-full bg-red-600/20 px-2 py-1 text-xs font-medium text-red-400 ring-1 ring-inset ring-red-600/30 cursor-pointer hover:bg-red-600/30 transition-colors"
              }),
              event.on_mouse_down(ShortUrlToggleActiveClicked(
                url.id,
                url.is_active,
              )),
              attr.title("Toggle active/inactive"),
            ],
            [
              html.text(case url.is_active {
                True -> "Active"
                False -> "Inactive"
              }),
            ],
          ),
          // Access count - same as compact
          html.div([attr.class("text-xs text-zinc-500 shrink-0")], [
            html.text(int.to_string(url.access_count) <> " clicks"),
          ]),
        ]),
        // Collapse indicator
        html.div(
          [
            attr.class(
              "flex items-center space-x-2 ml-4 cursor-pointer hover:text-zinc-300 transition-colors",
            ),
            event.on_mouse_down(ShortUrlToggleExpanded(url.id)),
          ],
          [html.div([attr.class("text-zinc-500 text-sm")], [html.text("▲")])],
        ),
      ]),
      // Additional expanded content
      html.div([attr.class("px-4 pb-4")], [
        // Full Target URL section
        html.div([attr.class("mb-4 pt-2 border-t border-zinc-700")], [
          html.div([attr.class("text-sm text-zinc-500 mb-2")], [
            html.text("Target URL:"),
          ]),
          html.div(
            [
              attr.class(
                "text-zinc-300 break-all bg-zinc-900 rounded px-3 py-2 text-sm cursor-pointer hover:bg-zinc-850 transition-colors",
              ),
              attr.title(url.target_url <> " (click to collapse)"),
              event.on_mouse_down(ShortUrlToggleExpanded(url.id)),
            ],
            [html.text(url.target_url)],
          ),
        ]),
        // Metadata grid
        html.div([attr.class("grid grid-cols-2 gap-4 text-sm mb-4")], [
          html.div([attr.class("space-y-2")], [
            html.div([attr.class("flex justify-between")], [
              html.span([attr.class("text-zinc-500")], [
                html.text("Created By:"),
              ]),
              html.span([attr.class("text-zinc-300")], [
                html.text(url.created_by),
              ]),
            ]),
            html.div([attr.class("flex justify-between")], [
              html.span([attr.class("text-zinc-500")], [
                html.text("Access Count:"),
              ]),
              html.span([attr.class("text-zinc-300 font-mono")], [
                html.text(int.to_string(url.access_count)),
              ]),
            ]),
          ]),
          html.div([attr.class("space-y-2")], [
            html.div([attr.class("flex justify-between")], [
              html.span([attr.class("text-zinc-500")], [html.text("Created:")]),
              html.span([attr.class("text-zinc-300")], [
                html.text(
                  birl.from_unix_milli(url.created_at * 1000)
                  |> birl.to_naive_date_string,
                ),
              ]),
            ]),
            html.div([attr.class("flex justify-between")], [
              html.span([attr.class("text-zinc-500")], [html.text("Updated:")]),
              html.span([attr.class("text-zinc-300")], [
                html.text(
                  birl.from_unix_milli(url.updated_at * 1000)
                  |> birl.to_naive_date_string,
                ),
              ]),
            ]),
          ]),
        ]),
        // Action buttons
        html.div([attr.class("flex gap-2")], [
          html.button(
            [
              attr.class(
                "flex-1 inline-flex items-center justify-center gap-x-2 py-3 text-sm font-medium text-zinc-400 border border-zinc-600 rounded hover:text-teal-300 hover:border-teal-400 transition-colors",
              ),
              event.on_mouse_down(ShortUrlCopyClicked(url.short_code)),
            ],
            [
              html.div([attr.class("text-sm")], [html.text("📋")]),
              html.text(case model.copy_feedback == Some(url.short_code) {
                True -> "Copied!"
                False -> "Copy URL"
              }),
            ],
          ),
          html.button(
            [
              attr.class(case url.is_active {
                True ->
                  "flex-1 inline-flex items-center justify-center gap-x-2 py-3 text-sm font-medium text-zinc-400 border border-zinc-600 rounded hover:text-orange-300 hover:border-orange-400 transition-colors"
                False ->
                  "flex-1 inline-flex items-center justify-center gap-x-2 py-3 text-sm font-medium text-zinc-400 border border-zinc-600 rounded hover:text-teal-300 hover:border-teal-400 transition-colors"
              }),
              event.on_mouse_down(ShortUrlToggleActiveClicked(
                url.id,
                url.is_active,
              )),
            ],
            [
              html.div([attr.class("text-sm")], [
                html.text(case url.is_active {
                  True -> "⏸"
                  False -> "▶"
                }),
              ]),
              html.text(case url.is_active {
                True -> "Deactivate"
                False -> "Activate"
              }),
            ],
          ),
          html.button(
            [
              attr.class(
                "flex-1 inline-flex items-center justify-center gap-x-2 py-3 text-sm font-medium text-zinc-400 border border-zinc-600 rounded hover:text-red-300 hover:border-red-400 transition-colors",
              ),
              event.on_mouse_down(ShortUrlDeleteClicked(url.id)),
            ],
            [
              html.div([attr.class("text-sm")], [html.text("🗑")]),
              html.text("Delete"),
            ],
          ),
        ]),
      ]),
    ],
  )
}

fn view_delete_confirmation(
  delete_id: String,
  short_urls: List(ShortUrl),
) -> Element(Msg) {
  let url_to_delete = case
    list.find(short_urls, fn(url) { url.id == delete_id })
  {
    Ok(url) -> url.short_code
    Error(_) -> "unknown"
  }

  html.div(
    [
      attr.class(
        "fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50",
      ),
    ],
    [
      html.div(
        [
          attr.class(
            "bg-zinc-800 rounded-lg p-6 max-w-md w-full mx-4 border border-zinc-700",
          ),
        ],
        [
          html.h3([attr.class("text-lg font-medium text-white mb-4")], [
            html.text("Delete Short URL"),
          ]),
          html.p([attr.class("text-zinc-300 mb-6")], [
            html.text("Are you sure you want to delete the short URL "),
            html.span([attr.class("font-mono text-pink-400")], [
              html.text("u.jst.dev/" <> url_to_delete),
            ]),
            html.text("? This action cannot be undone."),
          ]),
          html.div([attr.class("flex gap-3 justify-end")], [
            html.button(
              [
                attr.class(
                  "px-4 py-2 bg-zinc-600 text-white rounded hover:bg-zinc-700 transition-colors",
                ),
                event.on_mouse_down(ShortUrlDeleteCancelClicked),
              ],
              [html.text("Cancel")],
            ),
            html.button(
              [
                attr.class(
                  "px-4 py-2 text-zinc-400 border border-zinc-600 rounded hover:text-red-300 hover:border-red-400 transition-colors",
                ),
                event.on_mouse_down(ShortUrlDeleteConfirmClicked(delete_id)),
              ],
              [html.text("Delete")],
            ),
          ]),
        ],
      ),
    ],
  )
}

fn view_url_info_page(model: Model, short_code: String) -> List(Element(Msg)) {
  case model.short_urls {
    Loaded(urls) -> {
      case list.find(urls, fn(url) { url.short_code == short_code }) {
        Ok(url) -> [
          view_title("URL Info", "url-info"),
          html.div(
            [
              attr.class(
                "mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700",
              ),
            ],
            [
              html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
                html.text("URL Details"),
              ]),
              html.div([attr.class("space-y-4 text-zinc-300")], [
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Short Code:"),
                  ]),
                  html.span([attr.class("font-mono text-pink-700")], [
                    html.text(url.short_code),
                  ]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Target URL:"),
                  ]),
                  html.span([attr.class("break-all")], [
                    html.text(url.target_url),
                  ]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Created By:"),
                  ]),
                  html.span([], [html.text(url.created_by)]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Created:"),
                  ]),
                  html.span([], [
                    html.text(
                      birl.from_unix_milli(url.created_at * 1000)
                      |> birl.to_naive_date_string,
                    ),
                  ]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Updated:"),
                  ]),
                  html.span([], [
                    html.text(
                      birl.from_unix_milli(url.updated_at * 1000)
                      |> birl.to_naive_date_string,
                    ),
                  ]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Access Count:"),
                  ]),
                  html.span([], [html.text(int.to_string(url.access_count))]),
                ]),
                html.div([attr.class("flex justify-between items-center")], [
                  html.span([attr.class("text-zinc-500")], [
                    html.text("Status:"),
                  ]),
                  case url.is_active {
                    True -> {
                      html.span([attr.class("text-green-400")], [
                        html.text("Active"),
                      ])
                    }
                    False -> {
                      html.span([attr.class("text-red-400")], [
                        html.text("Inactive"),
                      ])
                    }
                  },
                ]),
              ]),
              html.div([attr.class("mt-6 flex gap-4")], [
                ui.button_action(
                  "Back to URLs",
                  ui.ButtonTeal,
                  False,
                  UserMouseDownNavigation(routes.to_uri(routes.UrlShortIndex)),
                ),
                ui.button_action(
                  case model.copy_feedback == Some(url.short_code) {
                    True -> "Copied!"
                    False -> "Copy URL"
                  },
                  ui.ButtonTeal,
                  False,
                  ShortUrlCopyClicked(url.short_code),
                ),
                ui.button_action(
                  case url.is_active {
                    True -> "Deactivate"
                    False -> "Activate"
                  },
                  case url.is_active {
                    True -> ui.ButtonOrange
                    False -> ui.ButtonTeal
                  },
                  False,
                  ShortUrlToggleActiveClicked(url.id, url.is_active),
                ),
                ui.button_action(
                  "Delete URL",
                  ui.ButtonRed,
                  False,
                  ShortUrlDeleteClicked(url.id),
                ),
              ]),
            ],
          ),
        ]
        Error(_) -> [
          view_title("URL Not Found", "url-not-found"),
          view_simple_paragraph("The requested URL was not found."),
        ]
      }
    }
    _ -> [
      view_title("URL Info", "url-info"),
      view_simple_paragraph("Loading URL information..."),
    ]
  }
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
      attr.class("page-title text-2xl sm:text-3xl md:text-4xl text-pink-600 font-light article-title leading-tight"),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.div(
    [
      attr.id("article-subtitle-" <> slug),
      attr.class("page-subtitle"),
    ],
    [html.text(title)],
  )
}

fn view_leading(text: String, slug: String) -> Element(msg) {
  html.p(
    [
      attr.id("article-lead-" <> slug),
      attr.class(
        "font-medium text-zinc-300 pt-6 md:pt-8 border-b border-zinc-800 pb-4",
      ),
      attr.class("article-leading"),
    ],
    [html.text(text)],
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
  ui.error_state(ui.ErrorGeneric, "Something went wrong", error_string, None)
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

// fn view_link_external(url: Uri, title: String) -> Element(Msg) {
//   html.a(
//     [
//       attr.href(uri.to_string(url)),
//       attr.class("text-pink-700 hover:underline cursor-pointer"),
//       attr.target("_blank"),
//     ],
//     [html.text(title)],
//   )
// }

// fn view_link_missing(url: Uri, title: String) -> Element(Msg) {
//   html.a(
//     [
//       event.on_mouse_down(UserMouseDownNavigation(url)),
//       attr.href(uri.to_string(url)),
//       attr.class("hover:underline cursor-pointer"),
//     ],
//     [
//       html.span([attr.class("text-orange-500")], [html.text("broken link: ")]),
//       html.text(title),
//     ],
//   )
// }

// Content editor functions removed - now using simple Djot textarea

fn view_article_listing_loading() -> List(Element(Msg)) {
  [ui.page_title("Articles"), ui.loading_state("Loading articles...")]
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

// fn view_authentication_required(action: String) -> List(Element(Msg)) {
//   [
//     view_title("Authentication Required", "auth-required"),
//     view_simple_paragraph("You need to be logged in to " <> action),
//   ]
// }

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
