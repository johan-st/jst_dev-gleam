// IMPORTS ---------------------------------------------------------------------

import article/article.{type Article, ArticleV1}
import article/draft
import birl
import components/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
// removed unused order import (sorting moved to page modules)
import gleam/set.{type Set}
import gleam/string
import gleam/uri.{type Uri}

import helpers
import keyboard as key
import lustre
import lustre/attribute.{type Attribute} as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import pages/pages
import pages/index_view as index_view
import pages/about_view as about_view
import pages/article_list_view as article_list_view
import pages/article_view as article_view
import pages/url_index_view as url_index_view
import pages/url_list_view as url_list_view
import plinth/browser/event as p_event
import routes.{type Route}
import session.{type Session}
import utils/dom_utils
import utils/error_string
import utils/http.{type HttpError}
import utils/icon
import utils/jot_to_lustre
import utils/mouse
import utils/notification.{type NotificationResponse}
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
} as rd
import utils/short_url.{type ShortUrl, type ShortUrlListResponse}
import utils/user
import utils/window_events

@external(javascript, "./app.ffi.mjs", "clipboard_copy")
fn clipboard_copy(text: String) -> Nil

@external(javascript, "./app.ffi.mjs", "set_timeout")
fn set_timeout(callback: fn() -> Nil, delay: Int) -> Nil

// MODEL -----------------------------------------------------------------------

// Keyboard chord bindings ------------------------------------------------------
pub type ChordGroup {
  Nav
  Cmd
}

pub type ChordBinding {
  ChordBinding(
    chord: key.Chord,
    msg: Msg,
    group: ChordGroup,
    label: String,
    block_default: Bool,
  )
}

fn chord_from_keys(keys: List(key.Key)) -> key.Chord {
  key.Chord(set.from_list(keys))
}

fn bindings_for(page: pages.Page) -> List(ChordBinding) {
  let alt = key.Captured(key.Alt)
  let ctrl = key.Captured(key.Ctrl)

  let global_nav = []
    |> filter_nav_by_session(page)

  let page_cmd =
    case page {
      pages.PageArticleList(_, session) -> {
        case session {
          session.Authenticated(_) -> [
            // Ctrl+N → New article
            ChordBinding(
              chord: chord_from_keys([ctrl, key.Captured(key.N)]),
              msg: ArticleCreateClicked,
              group: Cmd,
              label: "New article",
              block_default: True,
            ),
          ]
          _ -> []
        }
      }
      pages.PageArticle(article, session) -> {
        case article.can_edit(article, session) {
          True -> [
            // Ctrl+E → Start editing
            ChordBinding(
              chord: chord_from_keys([ctrl, key.Captured(key.E)]),
              msg: UserMouseDownNavigation(routes.to_uri(routes.ArticleEdit(article.id))),
              group: Cmd,
              label: "Edit",
              block_default: True,
            ),
          ]
          False -> []
        }
      }
      pages.PageArticleEdit(article, _) -> [
        // Ctrl+S → Save draft
        ChordBinding(
          chord: chord_from_keys([ctrl, key.Captured(key.S)]),
          msg: ArticleDraftSaveClicked(article),
          group: Cmd,
          label: "Save draft",
          block_default: True,
        ),
        // Alt+Space → Toggle preview/edit
        ChordBinding(
          chord: chord_from_keys([alt, key.Captured(key.Space)]),
          msg: EditViewModeToggled,
          group: Nav,
          label: "Toggle preview/edit",
          block_default: True,
        ),
      ]
      _ -> []
    }

  let global_cmd = [
    // Ctrl+N → prevent browser new-window globally (no-op here)
    ChordBinding(
      chord: chord_from_keys([ctrl, key.Captured(key.N)]),
      msg: NoOp,
      group: Cmd,
      label: "",
      block_default: True,
    ),
    // Ctrl+S → prevent browser save globally (no-op here)
    ChordBinding(
      chord: chord_from_keys([ctrl, key.Captured(key.S)]),
      msg: NoOp,
      group: Cmd,
      label: "",
      block_default: True,
    ),
    // Alt+Space → prevent OS menu globally (no-op here when not in edit)
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Space)]),
      msg: NoOp,
      group: Nav,
      label: "",
      block_default: True,
    ),
  ]

  global_nav
  |> list.append(page_cmd)
  |> list.append(global_cmd)
}

fn filter_nav_by_session(bindings: List(ChordBinding), page: pages.Page) -> List(ChordBinding) {
  let session =
    case page {
      pages.PageArticleList(_, sess) -> sess
      pages.PageArticle(_, sess) -> sess
      pages.PageArticleEdit(_, sess) -> session.Authenticated(sess)
      pages.PageUrlShortIndex(sess) -> session.Authenticated(sess)
      pages.PageUrlShortInfo(_, sess) -> session.Authenticated(sess)
      pages.PageUiComponents(sess) -> session.Authenticated(sess)
      pages.PageNotifications(sess) -> session.Authenticated(sess)
      pages.PageProfile(sess) -> session.Authenticated(sess)
      pages.PageDjotDemo(sess, _) -> session.Authenticated(sess)
      _ -> session.Unauthenticated
    }

  let alt = key.Captured(key.Alt)
  let numbers_common = [
    // Alt+1 → Home
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit1)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.Index)),
      group: Nav,
      label: "Home",
      block_default: False,
    ),
    // Alt+2 → Articles
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit2)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.Articles)),
      group: Nav,
      label: "Articles",
      block_default: False,
    ),
    // Alt+3 → About
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit3)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.About)),
      group: Nav,
      label: "About",
      block_default: False,
    ),
  ]

  let numbers_more = [
    // Alt+4 → Djot Demo
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit4)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.DjotDemo)),
      group: Nav,
      label: "Djot Demo",
      block_default: False,
    ),
    // Alt+5 → URL Shortener
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit5)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.UrlShortIndex)),
      group: Nav,
      label: "URL Shortener",
      block_default: False,
    ),
    // Alt+6 → UI Components
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit6)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.UiComponents)),
      group: Nav,
      label: "UI Components",
      block_default: False,
    ),
    // Alt+7 → Notifications
    ChordBinding(
      chord: chord_from_keys([alt, key.Captured(key.Digit7)]),
      msg: UserMouseDownNavigation(routes.to_uri(routes.Notifications)),
      group: Nav,
      label: "Notifications",
      block_default: False,
    ),
  ]

  let auth_based = case session {
    session.Authenticated(_) -> [
      // Alt+P → Profile (only when authenticated)
      ChordBinding(
        chord: chord_from_keys([key.Captured(key.Alt), key.Captured(key.P)]),
        msg: UserMouseDownNavigation(routes.to_uri(routes.Profile)),
        group: Nav,
        label: "Profile",
        block_default: False,
      ),
      ..numbers_more
    ]
    session.Unauthenticated | session.Pending -> [
      // Alt+L → Login (toggle login form)
      ChordBinding(
        chord: chord_from_keys([key.Captured(key.Alt), key.Captured(key.L)]),
        msg: LoginFormToggled,
        group: Nav,
        label: "Login",
        block_default: False,
      ),
    ]
  }

  bindings
  |> list.append(numbers_common)
  |> list.append(auth_based)
}

fn recompute_bindings_for_current_page(model: Model) -> Model {
  let page = pages.from_route(False, model.route, model.session, model.articles)
  let new_bindings = bindings_for(page)
  let new_chords = new_bindings |> list.map(fn(b) { b.chord }) |> set.from_list
  Model(..model, chord_bindings: new_bindings, chords_available: new_chords)
}

fn chord_equals(a: key.Chord, b: key.Chord) -> Bool {
  case a, b {
    key.Chord(ak), key.Chord(bk) -> set.is_subset(ak, bk) && set.is_subset(bk, ak)
  }
}

fn should_prevent_keydown(active_chords: Set(key.Chord)) -> fn(p_event.Event(p_event.UIEvent(p_event.KeyboardEvent))) -> Bool {
  fn(ev) {
    let parsed = key.parse_key(p_event.code(ev), p_event.key(ev))
    let keys = set.from_list([parsed])
    // If the single key contains Ctrl or Alt with sensitive keys, prevent default immediately
    // We simulate a quick check for our critical combos by looking for the base keys in the event flags
    let is_ctrl = p_event.ctrl_key(ev)
    let is_alt = p_event.alt_key(ev)
    let code = p_event.code(ev)

    let ctrl_sensitive = case code {
      "KeyN" -> True
      "KeyS" -> True
      "KeyE" -> True
      _ -> False
    }
    let alt_sensitive = case code {
      "Space" -> True
      _ -> False
    }
    let sensitive = case is_ctrl {
      True -> ctrl_sensitive
      False -> case is_alt {
        True -> alt_sensitive
        False -> False
      }
    }

    case sensitive {
      True -> True
      False -> {
        // Also consult active chords in case a full chord would match using subset logic
        case key.triggered_chord(keys, active_chords) {
          Some(_) -> True
          None -> False
        }
      }
    }
  }
}

type Model {
  Model(
    base_uri: Uri,
    route: Route,
    session: Session,
    articles: RemoteData(List(Article), HttpError),
    short_urls: RemoteData(List(ShortUrl), HttpError),
    short_url_form_short_code: String,
    short_url_form_target_url: String,
    djot_demo_content: String,
    edit_view_mode: EditViewMode,
    profile_menu_open: Bool,
    notice: String,
    debug_use_local_storage: Bool,
    delete_confirmation: Option(String),
    copy_feedback: Option(String),
    expanded_urls: Set(String),
    login_form_open: Bool,
    login_username: String,
    login_password: String,
    login_loading: Bool,
    // Keyboard
    keys_down: Set(key.Key),
    chords_available: Set(key.Chord),
    chord_bindings: List(ChordBinding),
    // Notification form fields
    notification_form_title: String,
    notification_form_message: String,
    notification_form_category: String,
    notification_form_priority: String,
    notification_form_ntfy_topic: String,
    notification_form_data: List(#(String, String)),
    notification_sending: Bool,
    // Profile page state
    profile_user: RemoteData(user.UserFull, HttpError),
    profile_form_username: String,
    profile_form_email: String,
    profile_form_new_password: String,
    profile_form_confirm_password: String,
    profile_form_old_password: String,
    profile_saving: Bool,
    password_saving: Bool,
  )
}

pub type EditViewMode {
  EditViewModeEdit
  EditViewModePreview
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  UserNavigatedTo(uri: Uri)
  UserMouseDownNavigation(uri: Uri)
  ProfileMenuToggled
  ProfileMenuAction(msg: Msg)
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
  AuthRefreshTimerFired
  AuthRefreshResponse(result: Result(session.Session, HttpError))
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

  // Keyboard events
  KeyboardDown(p_event.Event(p_event.UIEvent(p_event.KeyboardEvent)))
  KeyboardUp(p_event.Event(p_event.UIEvent(p_event.KeyboardEvent)))

  // Other events
  WindowUnfocused

  // Notifications
  NotificationFormTitleUpdated(String)
  NotificationFormMessageUpdated(String)
  NotificationFormCategoryUpdated(String)
  NotificationFormPriorityUpdated(String)
  NotificationFormNtfyTopicUpdated(String)
  NotificationFormDataUpdated(List(#(String, String)))
  NotificationSendClicked
  NotificationSendResponse(Result(NotificationResponse, HttpError))

  // UI Components
  NoOp

  // Profile
  ProfileMeGot(Result(user.UserFull, HttpError))
  ProfileFormUsernameUpdated(String)
  ProfileFormEmailUpdated(String)
  ProfileFormNewPasswordUpdated(String)
  ProfileFormConfirmPasswordUpdated(String)
  ProfileFormOldPasswordUpdated(String)
  ProfileSaveClicked
  ProfileSaveResponse(Result(user.UserUpdateResponse, HttpError))
  ProfileChangePasswordClicked
  ProfileChangePasswordResponse(Result(user.UserUpdateResponse, HttpError))
}

fn update_with_localstorage(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case model.debug_use_local_storage {
    True -> {
      let #(new_model, effect) = update(model, msg)
      let persistent_model = fn(model: Model) -> PersistentModel {
        PersistentModelV1(articles: case model.articles {
          Loaded(articles, _, _) -> articles
          NotInitialized -> []
          Pending(_, _) -> []
          Errored(_, _) -> []
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
                  articles: Loaded(
                    articles,
                    birl.from_unix(0),
                    birl.from_unix(0),
                  ),
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
      let new_login_form_open = !model.login_form_open
      let focus_effect = case new_login_form_open {
        True -> dom_utils.focus_and_select_element("login-username-input")
        False -> effect.none()
      }
      #(
        Model(
          ..model,
          login_form_open: new_login_form_open,
          login_username: "",
          login_password: "",
        ),
        focus_effect,
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
      #(model, modem.push(uri.to_string(uri), None, None))
    }
    // MENU
    ProfileMenuToggled -> {
      #(
        Model(..model, profile_menu_open: !model.profile_menu_open),
        effect.none(),
      )
    }
    ProfileMenuAction(msg) -> {
      let model = Model(..model, profile_menu_open: False)
      update(model, msg)
    }

    // Keyboard events
    KeyboardDown(ev) -> {
      update_chord(ev, model)
    }

    KeyboardUp(key) -> {
      let code = p_event.code(key)
      let key = p_event.key(key)
      let key_parsed = key.parse_key(code, key)
      let model =
        Model(..model, keys_down: set.delete(model.keys_down, key_parsed))
      #(model, effect.none())
    }

    // Other events
    WindowUnfocused -> {
      #(Model(..model, keys_down: set.new()), effect.none())
    }

    // Messages
    NoticeCleared -> {
      #(Model(..model, notice: ""), effect.none())
    }
    // Browser Persistance
    PersistGotModel(opt:) -> {
      case opt {
        Some(PersistentModelV1(articles)) -> {
          #(
            Model(
              ..model,
              articles: Loaded(articles, birl.from_unix(0), birl.from_unix(0)),
            ),
            effect.none(),
          )
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
              slug: slug,
              author: _,
              title: _,
              leading: _,
              subtitle: _,
              content: _,
              draft: _,
              published_at: _,
              revision: _,
              tags: _,
            )) -> {
              let articles_with_pending_content =
                list.map(articles, fn(article) {
                  case article.slug == slug {
                    True ->
                      ArticleV1(..article, content: Pending(None, birl.now()))
                    False -> article
                  }
                })
              #(
                Model(
                  ..model,
                  articles: Loaded(
                    articles_with_pending_content,
                    birl.now(),
                    birl.now(),
                  ),
                ),
                article.article_get(ArticleGot(id, _), id, model.base_uri),
              )
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
          Model(..model, articles: model.articles |> rd.to_loaded(articles)),
          article.article_get(ArticleGot(id, _), id, model.base_uri),
        )

        Ok(articles), _ -> {
          let model = Model(..model, articles: model.articles |> rd.to_loaded(articles))
          |> recompute_bindings_for_current_page
          #(model, effect.none())
        }
        Error(err), _ -> #(
          Model(..model, articles: model.articles |> rd.to_errored(err)),
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
            |> rd.map(
              list.map(_, fn(article_current) {
                case id == article_current.id {
                  True -> article
                  False -> article_current
                }
              }),
            )
          let model = Model(..model, articles: updated_articles)
          |> recompute_bindings_for_current_page
          #(model, effect.none())
        }
        Error(err) -> {
          let updated_articles =
            model.articles
            |> rd.map(
              list.map(_, fn(article_current) {
                case id == article_current.id {
                  True ->
                    ArticleV1(
                      ..article_current,
                      content: Errored(err, birl.now()),
                    )
                  False -> article_current
                }
              }),
            )
          let model = Model(..model, articles: updated_articles)
          |> recompute_bindings_for_current_page
          #(model, effect.none())
        }
      }
    }
    ArticleHovered(article:) -> {
      case article.content {
        NotInitialized -> {
          let updated_articles =
            model.articles
            |> rd.map(
              list.map(_, fn(article_current) {
                case article.id == article_current.id {
                  True ->
                    ArticleV1(
                      ..article_current,
                      content: article.content |> rd.to_pending(None),
                    )
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
        Errored(_, _) -> #(
          model,
          article.article_get(
            ArticleGot(article.id, _),
            article.id,
            model.base_uri,
          ),
        )
        Pending(_, _) | Loaded(_, _, _) -> {
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
              articles: rd.map(
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
      let updated_article =
        article.draft_update(article, fn(draft) { draft.set_title(draft, text) })
      let updated_articles =
        rd.map(
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
    ArticleDraftUpdatedLeading(article, text) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_leading(draft, text)
        })
      let updated_articles =
        rd.map(
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
    ArticleDraftUpdatedSubtitle(article, text) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_subtitle(draft, text)
        })
      let updated_articles =
        rd.map(
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
    ArticleDraftUpdatedContent(article, content) -> {
      let updated_article =
        article.draft_update(article, fn(draft) {
          draft.set_content(draft, content)
        })
      #(
        Model(
          ..model,
          articles: rd.map(
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
    // ARTICLE DRAFT DISCARD
    ArticleDraftDiscardClicked(article) -> {
      echo "article draft discard clicked"
      let updated_articles =
        rd.map(
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
              content: rd.to_loaded(
                rd.NotInitialized,
                draft.content(current_draft),
              ),
              draft: Some(current_draft),
            )
          let updated_articles =
            rd.map(
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
            rd.map(
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
        Ok(sess) -> {
          let schedule_effect = case session.expiry(sess) {
            Some(expiry) ->
              session.schedule_refresh(
                AuthRefreshTimerFired,
                model.base_uri,
                expiry,
              )
            None -> effect.none()
          }
          let model = Model(
            ..model,
            session: sess,
            notice: "Successfully logged in",
            login_form_open: False,
            login_loading: False,
            login_username: "",
            login_password: "",
          )
          |> recompute_bindings_for_current_page
          #(model, schedule_effect)
        }
        Error(err) -> {
          echo err
          let model = Model(
            ..model,
            session: session.Unauthenticated,
            notice: "Login failed. Please check your credentials.",
            login_loading: False,
          )
          |> recompute_bindings_for_current_page
          #(model, effect.none())
        }
      }
    }
    AuthLogoutClicked -> {
      let model = Model(..model, session: session.Unauthenticated)
      |> recompute_bindings_for_current_page
      #(model, session.auth_logout(AuthLogoutResponse, model.base_uri))
    }
    AuthLogoutResponse(_result) -> {
      let model = Model(..model, session: session.Unauthenticated)
      |> recompute_bindings_for_current_page
      #(model, effect.none())
    }
    AuthCheckClicked -> {
      #(
        Model(..model, notice: "auth check, CLICK"),
        session.auth_check(AuthCheckResponse, model.base_uri),
      )
    }
    AuthCheckResponse(result) -> {
      case result {
        Ok(sess) -> {
          let schedule_effect = case session.expiry(sess) {
            Some(expiry) ->
              session.schedule_refresh(
                AuthRefreshTimerFired,
                model.base_uri,
                expiry,
              )
            None -> effect.none()
          }
          let model = Model(..model, session: sess, notice: "auth check, OK")
          |> recompute_bindings_for_current_page
          #(model, schedule_effect)
        }
        Error(err) -> {
          echo "session check response error"
          echo err
          let model = Model(
            ..model,
            session: session.Unauthenticated,
            notice: "auth check, ERROR",
          )
          |> recompute_bindings_for_current_page
          #(model, effect.none())
        }
      }
    }
    AuthRefreshTimerFired -> {
      #(model, session.refresh(AuthRefreshResponse, model.base_uri))
    }
    AuthRefreshResponse(result) -> {
      case result {
        Ok(sess) -> {
          let schedule_effect = case session.expiry(sess) {
            Some(expiry) ->
              session.schedule_refresh(
                AuthRefreshTimerFired,
                model.base_uri,
                expiry,
              )
            None -> effect.none()
          }
          let model = Model(..model, session: sess)
          |> recompute_bindings_for_current_page
          #(model, schedule_effect)
        }
        Error(_err) -> #(model, effect.none())
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
          content: rd.to_pending(rd.NotInitialized, Some("")),
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
            Loaded(articles, _, _) ->
              Loaded([created_article, ..articles], birl.now(), birl.now())
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
            rd.map(
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
            Pending(Some(urls), _) | Loaded(urls, _, _) ->
              Loaded([short_url, ..urls], birl.now(), birl.now())
            _ -> Loaded([short_url], birl.now(), birl.now())
          }
          #(Model(..model, short_urls: updated_short_urls), effect.none())
        }
        Error(err) -> {
          #(
            Model(..model, short_urls: rd.to_errored(model.short_urls, err)),
            effect.none(),
          )
        }
      }
    }
    ShortUrlListGot(result) -> {
      case result {
        Ok(response) -> {
          #(
            Model(
              ..model,
              short_urls: model.short_urls |> rd.to_loaded(response.short_urls),
            ),
            effect.none(),
          )
        }
        Error(err) -> {
          #(
            Model(..model, short_urls: rd.to_errored(model.short_urls, err)),
            effect.none(),
          )
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
            Pending(Some(urls), _) | Loaded(urls, _, _) ->
              Loaded(
                list.filter(urls, fn(url) { url.id != id }),
                birl.now(),
                birl.now(),
              )
            _ -> Loaded([], birl.now(), birl.now())
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
        // TODO: Handle error
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
            Pending(Some(urls), _) | Loaded(urls, _, _) ->
              Loaded(
                list.map(urls, fn(url) {
                  case url.id == id {
                    True -> updated_url
                    False -> url
                  }
                }),
                birl.now(),
                birl.now(),
              )
            _ -> Loaded([], birl.now(), birl.now())
          }
          #(Model(..model, short_urls: updated_short_urls), effect.none())
        }
        Error(err) -> {
          #(
            Model(..model, short_urls: rd.to_errored(model.short_urls, err)),
            effect.none(),
          )
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
    // NOTIFICATION HANDLERS
    NotificationFormTitleUpdated(title) -> {
      #(Model(..model, notification_form_title: title), effect.none())
    }
    NotificationFormMessageUpdated(message) -> {
      #(Model(..model, notification_form_message: message), effect.none())
    }
    NotificationFormCategoryUpdated(category) -> {
      #(Model(..model, notification_form_category: category), effect.none())
    }
    NotificationFormPriorityUpdated(priority) -> {
      #(Model(..model, notification_form_priority: priority), effect.none())
    }
    NotificationFormNtfyTopicUpdated(topic) -> {
      #(Model(..model, notification_form_ntfy_topic: topic), effect.none())
    }
    NotificationFormDataUpdated(data) -> {
      #(Model(..model, notification_form_data: data), effect.none())
    }
    NotificationSendClicked -> {
      case
        model.notification_form_title,
        model.notification_form_message,
        model.notification_form_category
      {
        "", _, _ | _, "", _ | _, _, "" -> #(model, effect.none())
        title, message, category -> {
          let request =
            notification.create_notification_request(
              title,
              message,
              category,
              model.notification_form_priority,
              model.notification_form_ntfy_topic,
              model.notification_form_data,
            )
          #(
            Model(..model, notification_sending: True),
            notification.send_notification(
              NotificationSendResponse,
              model.base_uri,
              request,
            ),
          )
        }
      }
    }
    NotificationSendResponse(result) -> {
      case result {
        Ok(_response) -> {
          #(
            Model(
              ..model,
              notification_sending: False,
              notification_form_title: "",
              notification_form_message: "",
              notification_form_category: "",
              notification_form_priority: "normal",
              notification_form_ntfy_topic: "",
              notification_form_data: [],
              notice: "Notification sent successfully!",
            ),
            effect.none(),
          )
        }
        Error(err) -> {
          #(
            Model(
              ..model,
              notification_sending: False,
              notice: "Failed to send notification: "
                <> error_string.http_error(err),
            ),
            effect.none(),
          )
        }
      }
    }
    // PROFILE
    ProfileMeGot(result) -> {
      case result {
        Ok(user_full) -> #(
          Model(
            ..model,
            profile_user: model.profile_user |> rd.to_loaded(user_full),
            profile_form_username: user_full.username,
            profile_form_email: user_full.email,
          ),
          effect.none(),
        )
        Error(err) -> #(
          Model(..model, profile_user: model.profile_user |> rd.to_errored(err)),
          effect.none(),
        )
      }
    }
    ProfileFormUsernameUpdated(text) -> #(
      Model(..model, profile_form_username: text),
      effect.none(),
    )
    ProfileFormEmailUpdated(text) -> #(
      Model(..model, profile_form_email: text),
      effect.none(),
    )
    ProfileFormNewPasswordUpdated(text) -> #(
      Model(..model, profile_form_new_password: text),
      effect.none(),
    )
    ProfileFormConfirmPasswordUpdated(text) -> #(
      Model(..model, profile_form_confirm_password: text),
      effect.none(),
    )
    ProfileFormOldPasswordUpdated(text) -> #(
      Model(..model, profile_form_old_password: text),
      effect.none(),
    )
    ProfileSaveClicked -> {
      case session.subject(model.session) {
        Some(subject) -> {
          let req =
            user.UserUpdateMeRequest(
              username: model.profile_form_username,
              email: model.profile_form_email,
              password: None,
              old_password: None,
            )
          #(
            Model(..model, profile_saving: True, notice: ""),
            user.user_update(ProfileSaveResponse, model.base_uri, subject, req),
          )
        }
        None -> #(model, effect.none())
      }
    }
    ProfileSaveResponse(result) -> {
      case result {
        Ok(updated) -> #(
          Model(
            ..model,
            profile_saving: False,
            profile_form_new_password: "",
            profile_form_confirm_password: "",
            profile_user: model.profile_user
              |> rd.to_loaded(user.UserFull(
                id: updated.id,
                revision: updated.revision,
                username: updated.username,
                email: updated.email,
                permissions: model.profile_user
                  |> rd.data
                  |> option.map(fn(user) { user.permissions })
                  |> option.unwrap([]),
              )),
            notice: "Profile updated",
          ),
          effect.none(),
        )
        Error(err) -> #(
          Model(
            ..model,
            profile_saving: False,
            notice: "Failed to update profile: " <> error_string.http_error(err),
          ),
          effect.none(),
        )
      }
    }
    ProfileChangePasswordClicked -> {
      case session.subject(model.session) {
        Some(subject) -> {
          let can_change =
            model.profile_form_new_password != ""
            && model.profile_form_new_password
            == model.profile_form_confirm_password
            && model.profile_form_old_password != ""
          case can_change {
            False -> #(model, effect.none())
            True -> {
              let req =
                user.UserUpdateMeRequest(
                  username: model.profile_form_username,
                  email: model.profile_form_email,
                  password: Some(model.profile_form_new_password),
                  old_password: Some(model.profile_form_old_password),
                )
              #(
                Model(..model, password_saving: True, notice: ""),
                user.user_update(
                  ProfileChangePasswordResponse,
                  model.base_uri,
                  subject,
                  req,
                ),
              )
            }
          }
        }
        None -> #(model, effect.none())
      }
    }
    ProfileChangePasswordResponse(result) -> {
      case result {
        Ok(_updated) -> #(
          Model(
            ..model,
            password_saving: False,
            profile_form_old_password: "",
            profile_form_new_password: "",
            profile_form_confirm_password: "",
            notice: "Password changed successfully",
          ),
          effect.none(),
        )
        Error(err) -> #(
          Model(
            ..model,
            password_saving: False,
            notice: "Failed to change password: "
              <> error_string.http_error(err),
          ),
          effect.none(),
        )
      }
    }
    DebugToggleLocalStorage -> {
      // Fells a bit wierd to call a function just for the side-effect and not use the result.. 
      case model.debug_use_local_storage {
        True -> persist.localstorage_set(persist.model_localstorage_key, "")
        False -> {
          let persistent_model = {
            PersistentModelV1(articles: case model.articles {
              Loaded(articles, _, _) -> articles
              _ -> []
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
    NoOp -> #(model, effect.none())
  }
}

fn fetch_articles_model(model_effect_touple) -> #(Model, Effect(Msg)) {
  echo "fetch_articles_model called"
  let #(model, effect) = model_effect_touple

  let model = Model(..model, articles: model.articles |> rd.to_pending(None))
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
    routes.About -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.Article(slug) -> {
      case model.articles {
        NotInitialized -> #(
          Model(
            ..model,
            route:,
            articles: model.articles |> rd.to_pending(None),
          ),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        Loaded(articles, _, _) -> {
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
                    ArticleV1(
                      ..art,
                      content: art.content |> rd.to_pending(None),
                    ),
                  )
                  _, _ -> #(eff, art)
                }
              },
            )
          let model = Model(
            ..model,
            route:,
            articles: model.articles |> rd.to_loaded(articles_updated),
          )
          |> recompute_bindings_for_current_page
          #(model, effect)
        }
        _ -> {
          let model = recompute_bindings_for_current_page(Model(..model, route:))
          #(model, effect.none())
        }
      }
    }
    routes.ArticleEdit(id) ->
      case model.articles {
        NotInitialized -> #(
          Model(
            ..model,
            route:,
            articles: model.articles |> rd.to_pending(None),
          ),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        Loaded(articles, _, _) -> {
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
                      content: art.content |> rd.to_pending(None),
                    ),
                  )
                  _, _ -> #(eff, art)
                }
              },
            )
          echo routes.to_string(route)
          let model = Model(
            ..model,
            route:,
            articles: model.articles |> rd.to_loaded(articles_updated),
          )
          |> recompute_bindings_for_current_page
          #(model, effect)
        }
        _ -> {
          let model = recompute_bindings_for_current_page(Model(..model, route:))
          #(model, effect.none())
        }
      }
    routes.Articles -> {
      case model.articles {
        NotInitialized -> #(
          Model(
            ..model,
            route:,
            articles: model.articles |> rd.to_pending(None),
          ),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        _ -> {
          let model = recompute_bindings_for_current_page(Model(..model, route:))
          #(model, effect.none())
        }
      }
    }
    routes.Index -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.UrlShortIndex -> {
      case model.short_urls {
        NotInitialized -> #(
          Model(
            ..model,
            route:,
            short_urls: model.short_urls |> rd.to_pending(None),
          ),
          short_url.list_short_urls(ShortUrlListGot, model.base_uri, 10, 0),
        )
        _ -> {
          let model = recompute_bindings_for_current_page(Model(..model, route:))
          #(model, effect.none())
        }
      }
    }
    routes.UrlShortInfo(_short_code) -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.DjotDemo -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.UiComponents -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.Notifications -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
    routes.Profile -> {
      case session.subject(model.session) {
        Some(subject) -> #(
          Model(
            ..model,
            route:,
            profile_user: model.profile_user |> rd.to_pending(None),
          ),
          user.user_get(ProfileMeGot, model.base_uri, subject),
        )
        None -> {
          let model = recompute_bindings_for_current_page(Model(..model, route:))
          #(model, effect.none())
        }
      }
    }
    routes.NotFound(_uri) -> {
      let model = recompute_bindings_for_current_page(Model(..model, route:))
      #(model, effect.none())
    }
  }
}

fn update_chord(
  ev: p_event.Event(p_event.UIEvent(p_event.KeyboardEvent)),
  model: Model,
) -> #(Model, Effect(Msg)) {
  let key_parsed = key.parse_key(p_event.code(ev), p_event.key(ev))
  let model = Model(..model, keys_down: set.insert(model.keys_down, key_parsed))

  case key.triggered_chord(model.keys_down, model.chords_available) {
    None -> #(model, effect.none())
    Some(chord) -> {
      let binding_opt = list.find(model.chord_bindings, fn(b) { chord_equals(b.chord, chord) })
      case binding_opt {
        Error(_) -> #(model, effect.none())
        Ok(binding) -> {
          // Prevent default if requested
          case binding.block_default { True -> p_event.prevent_default(ev) False -> Nil }

          // Clear pressed chord keys
          let keys = case chord { key.Chord(keys) -> keys }
          let model = Model(..model, keys_down: set.difference(model.keys_down, keys))

          // Dispatch the bound message through the regular update
          update(model, binding.msg)
        }
      }
    }
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let page = page_from_model(model)
  let content: List(Element(Msg)) = case page {
    pages.Loading(_) -> view_loading()
    pages.PageIndex -> index_view.view(UserMouseDownNavigation)
    pages.PageArticleList(articles, _session) ->
      article_list_view.view(articles, model.session)
    pages.PageArticleListLoading -> view_article_listing_loading()
    pages.PageArticle(article, session) -> article_view.view_article_page(article, session)
    pages.PageArticleEdit(article, _) -> view_article_edit(model, article)
    pages.PageError(error) -> {
      case error {
        pages.ArticleNotFound(slug, _) ->
          article_view.view_article_not_found(slug)
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
    pages.PageAbout -> about_view.view()
    pages.PageUrlShortIndex(_) -> url_index_view.view(url_list_view.list(
      model.short_urls,
      model.expanded_urls,
      model.delete_confirmation,
      model.copy_feedback,
      url_list_view.Callbacks(
        ShortUrlCopyClicked,
        ShortUrlToggleActiveClicked,
        ShortUrlToggleExpanded,
        ShortUrlDeleteClicked,
        ShortUrlDeleteConfirmClicked,
        fn() { ShortUrlDeleteCancelClicked },
      ),
    ))
    pages.PageUrlShortInfo(short, _) -> view_url_info_page(model, short)
    pages.PageDjotDemo(_, content) -> view_djot_demo(content)
    pages.PageUiComponents(_) -> view_ui_components()
    pages.PageNotifications(_) -> view_notifications(model)
    pages.PageProfile(_) -> view_profile(model)
    pages.PageNotFound(uri) -> view_not_found(uri)
  }
  let nav_hints_overlay = case set.contains(model.keys_down, key.Captured(key.Alt)) {
    True -> view_nav_hints_from_bindings(model)
    False -> element.none()
  }
  let layout = case page {
    pages.PageDjotDemo(_, _) | pages.PageArticleEdit(_, _) -> {
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
              [
                attr.class(
                  "max-w-screen-md mx-auto px-4 sm:px-6 md:px-10 py-6 sm:py-8 md:py-10",
                ),
              ],
              content,
            ),
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
              [
                attr.class(
                  "max-w-screen-md mx-auto px-4 sm:px-6 md:px-10 py-6 sm:py-8 md:py-10",
                ),
              ],
              content,
            ),
            view_modals(model),
          ],
        )
      }
    }
  }
  html.div([], [
    nav_hints_overlay,
    layout(content),
    view_status_bar_with_cmds(model),
  ])
}

fn view_nav_hints_from_bindings(model: Model) -> Element(Msg) {
  let shift = set.contains(model.keys_down, key.Captured(key.Shift))
  let nav_items =
    model.chord_bindings
    |> list.filter(fn(b) { b.group == Nav && b.label != "" })
    |> list.map(fn(b) {
      let combo = case b.chord { key.Chord(keys_set) ->
        keys_set
        |> set.to_list
        |> list.map(fn(k) {
          case k { key.Captured(c) -> key.to_string(c, shift) key.Unhandled(code) -> code }
        })
        |> string.join("+")
      }
      #(b.label, combo)
    })

  html.div([attr.class("fixed inset-0 z-50 flex items-center justify-center")], [
    // Dark overlay background
    html.div(
      [attr.class("absolute inset-0 bg-black bg-opacity-50 backdrop-blur-sm")],
      [],
    ),
    // Quick nav content
    html.div(
      [
        attr.class(
          "relative bg-zinc-900 bg-opacity-95 text-white rounded-xl px-12 py-8 shadow-2xl border border-zinc-700 backdrop-blur-sm max-w-md",
        ),
      ],
      [
        html.div(
          [
            attr.class(
              "text-2xl font-semibold text-pink-400 mb-6 text-center font-mono",
            ),
          ],
          [html.text("Quick Navigation")],
        ),
        html.div([attr.class("text-base text-zinc-400 mb-6 text-center")], [
          html.text("Hold Alt and press highlighted keys to navigate"),
        ]),
        html.ul(
          [attr.class("space-y-4")],
          list.map(nav_items, fn(item) {
            case item {
              #(name, shortcut) ->
                html.li(
                  [
                    attr.class(
                      "flex items-center justify-between bg-zinc-800 rounded-lg px-6 py-4 border border-zinc-700 hover:border-pink-600 transition-colors",
                    ),
                  ],
                  [
                    html.span(
                      [attr.class("text-zinc-300 font-medium text-lg")],
                      [html.text(name)],
                    ),
                    html.span(
                      [
                        attr.class(
                          "bg-zinc-700 text-zinc-200 px-3 py-2 rounded text-sm font-mono border border-zinc-600",
                        ),
                      ],
                      [html.text(shortcut)],
                    ),
                  ],
                )
            }
          }),
        ),
      ],
    ),
  ])
}

fn view_status_bar_with_cmds(model: Model) -> Element(Msg) {
  let keys = model.keys_down
  let session_ = model.session
  let shift = set.contains(keys, key.Captured(key.Shift))
  let ctrl = set.contains(keys, key.Captured(key.Ctrl))
  let alt = set.contains(keys, key.Captured(key.Alt))

  let cmd_hints = case ctrl {
    True -> {
      model.chord_bindings
      |> list.filter(fn(b) { b.group == Cmd && b.label != "" })
      |> list.map(fn(b) {
        let key_names = case b.chord { key.Chord(keys_set) ->
          keys_set
          |> set.to_list
          |> list.map(fn(k) {
            case k { key.Captured(c) -> key.to_string(c, shift) key.Unhandled(code) -> code }
          })
          |> string.join("+")
        }
        #(b.label, key_names)
      })
    }
    False -> []
  }

  case session_ {
    session.Authenticated(_) -> {
      let key_list = set.to_list(keys)
      html.div(
        [
          attr.class(
            "fixed bottom-0 left-0 right-0 bg-gray-800 text-white px-4 py-2 text-sm font-mono border-t border-gray-700",
          ),
        ],
        [
          html.div([attr.class("flex justify-between items-center")], [
            html.div([attr.class("flex items-center space-x-4")], [
              html.span([attr.class("flex items-center space-x-2")], [
                html.span([], [html.text("Ctrl")]),
                html.div(
                  [
                    attr.class(case ctrl {
                      True -> "w-3 h-3 bg-green-500 rounded-full"
                      False -> "w-3 h-3 bg-gray-500 rounded-full"
                    }),
                  ],
                  [],
                ),
              ]),
              html.span([], [html.text("Alt")]),
              html.div(
                [
                  attr.class(case alt {
                    True -> "w-3 h-3 bg-green-500 rounded-full"
                    False -> "w-3 h-3 bg-gray-500 rounded-full"
                  }),
                ],
                [],
              ),
              ..list.map(key_list, fn(key) {
                let text = case key {
                  key.Captured(key) -> key.to_string(key, shift)
                  key.Unhandled(code) -> "(" <> code <> ")"
                }
                html.span([], [html.text(text)])
              })
            ]),
            html.div([attr.class("flex items-center space-x-6")], [
              html.div([attr.class("text-gray-400")], [html.text("JST Lustre")]),
              case cmd_hints {
                [] -> element.none()
                _ -> html.div([attr.class("flex items-center space-x-4 text-xs text-zinc-300")],
                  list.map(cmd_hints, fn(tuple) {
                    case tuple { #(label, combo) ->
                      html.span([], [html.text(label <> ": " <> combo)])
                    }
                  }),
                )
              }
            ]),
          ]),
        ],
      )
    }
    session.Unauthenticated | session.Pending -> element.none()
  }
}

// PROFILE VIEW -----------------------------------------------------------------
fn view_profile(model: Model) -> List(Element(Msg)) {
  let header =
    ui.page_header(
      "Your Profile",
      Some("Update your personal information and change password"),
    )
  let content = case model.profile_user {
    NotInitialized -> [ui.loading_state("Loading profile", None, ui.ColorTeal)]
    Pending(Some(_user), _) -> [
      ui.loading_state(
        "Loading profile (could have been optimistic)",
        None,
        ui.ColorTeal,
      ),
    ]
    Pending(None, _) -> [
      ui.loading_state("Loading profile...", None, ui.ColorTeal),
    ]
    Errored(_, _) -> [
      ui.error_state(
        ui.ErrorGeneric,
        "Failed to load profile",
        "Please try again",
        Some(UserNavigatedTo(routes.to_uri(routes.Profile))),
      ),
    ]
    Loaded(_user_full, _, _) -> [
      ui.card([
        html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
          html.text("Profile Information"),
        ]),
        html.div([attr.class("space-y-4 max-w-xl")], [
          ui.form_input(
            "Username",
            model.profile_form_username,
            "Your username",
            "text",
            True,
            None,
            ProfileFormUsernameUpdated,
          ),
          ui.form_input(
            "Email",
            model.profile_form_email,
            "you@example.com",
            "email",
            True,
            None,
            ProfileFormEmailUpdated,
          ),
          html.div([attr.class("flex gap-3")], [
            ui.button(
              case model.profile_saving {
                True -> "Saving..."
                False -> "Save Changes"
              },
              ui.ColorTeal,
              case model.profile_saving {
                True -> ui.ButtonStatePending
                False -> ui.ButtonStateNormal
              },
              ProfileSaveClicked,
            ),
          ]),
        ]),
      ]),
      ui.card([
        html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
          html.text("Change Password"),
        ]),
        html.div([attr.class("space-y-4 max-w-xl")], [
          ui.form_input(
            "Current Password",
            model.profile_form_old_password,
            "Current password",
            "password",
            True,
            None,
            ProfileFormOldPasswordUpdated,
          ),
          ui.form_input(
            "New Password",
            model.profile_form_new_password,
            "New password",
            "password",
            False,
            None,
            ProfileFormNewPasswordUpdated,
          ),
          ui.form_input(
            "Confirm Password",
            model.profile_form_confirm_password,
            "Confirm new password",
            "password",
            False,
            case
              model.profile_form_new_password,
              model.profile_form_confirm_password
            {
              "", _ -> None
              _, "" -> None
              new_pw, confirm_pw ->
                case new_pw == confirm_pw {
                  True -> None
                  False -> Some("Passwords do not match")
                }
            },
            ProfileFormConfirmPasswordUpdated,
          ),
          html.div([attr.class("text-sm text-zinc-400")], [
            html.text("Leave blank to keep your current password."),
          ]),
          html.div([attr.class("flex gap-3")], [
            ui.button(
              case model.password_saving {
                True -> "Changing..."
                False -> "Change Password"
              },
              ui.ColorTeal,
              case model.password_saving {
                True -> ui.ButtonStatePending
                False -> {
                  let invalid =
                    model.profile_form_old_password == ""
                    || model.profile_form_new_password == ""
                    || model.profile_form_confirm_password == ""
                    || model.profile_form_new_password
                    != model.profile_form_confirm_password
                  case invalid {
                    True -> ui.ButtonStateDisabled
                    False -> ui.ButtonStateNormal
                  }
                }
              },
              ProfileChangePasswordClicked,
            ),
          ]),
        ]),
      ]),
    ]
  }
  [header, ..content]
}

fn page_from_model(model: Model) -> pages.Page {
  case model.route {
    routes.Index -> pages.PageIndex
    routes.Articles -> {
      case model.articles {
        Pending(_, _) -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error, _) ->
          pages.PageError(pages.HttpError(error, "Failed to load article list"))
        Loaded(articles_list, _, _) ->
          pages.PageArticleList(articles_list, model.session)
      }
    }
    routes.Article(slug) -> {
      case model.articles {
        Pending(_, _) -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error, _) ->
          pages.PageError(pages.HttpError(error, "Failed to load articles"))
        Loaded(articles_list, _, _) -> {
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
        Pending(_, _) -> pages.PageArticleListLoading
        NotInitialized ->
          pages.PageError(pages.Other("articles not initialized"))
        Errored(error, _) ->
          pages.PageError(pages.HttpError(
            error,
            "Failed to load articles for editing",
          ))
        Loaded(articles_list, _, _) -> {
          case list.find(articles_list, fn(art) { art.id == id }) {
            Ok(article) -> {
              case article.can_edit(article, model.session), article.draft {
                // TODO: this should be refactored.. the draft should be on the actual article and not on the one in the Page
                True, Some(_) -> {
                  case model.session {
                    session.Authenticated(session_auth) ->
                      pages.PageArticleEdit(article, session_auth)
                    _ ->
                      pages.PageError(pages.AuthenticationRequired(
                        "edit article",
                      ))
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
                      pages.PageError(pages.AuthenticationRequired(
                        "edit article",
                      ))
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
          pages.PageError(pages.AuthenticationRequired(
            "access URL shortener info",
          ))
      }
    }
    routes.DjotDemo ->
      case model.session {
        session.Authenticated(session_auth) ->
          pages.PageDjotDemo(session_auth, model.djot_demo_content)
        _ -> pages.PageError(pages.AuthenticationRequired("access DJOT demo"))
      }
    routes.About -> pages.PageAbout
    routes.UiComponents -> {
      case model.session {
        session.Authenticated(session_auth) ->
          pages.PageUiComponents(session_auth)
        _ ->
          pages.PageError(pages.AuthenticationRequired("access UI components"))
      }
    }
    routes.Notifications -> {
      case model.session {
        session.Authenticated(session_auth) ->
          pages.PageNotifications(session_auth)
        _ ->
          pages.PageError(pages.AuthenticationRequired("access notifications"))
      }
    }
    routes.Profile -> {
      case model.session {
        session.Authenticated(session_auth) -> pages.PageProfile(session_auth)
        _ -> pages.PageError(pages.AuthenticationRequired("access profile"))
      }
    }
    routes.NotFound(uri) -> pages.PageNotFound(uri)
  }
}

fn view_notice(_notice: String) -> Element(Msg) {
  // echo notice
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
        ui.form_input_with_focus(
          "Username",
          model.login_username,
          "Enter your username",
          "text",
          True,
          None,
          LoginUsernameUpdated,
          Some("login-username-input"),
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
        ui.button("Cancel", ui.ColorRed, ui.ButtonStateNormal, LoginFormToggled),
        ui.button(
          case model.login_loading {
            True -> "Sign In..."
            False -> "Sign In"
          },
          ui.ColorTeal,
          case
            model.login_loading,
            model.login_username == "" || model.login_password == ""
          {
            True, _ -> ui.ButtonStatePending
            False, True -> ui.ButtonStateDisabled
            _, _ -> ui.ButtonStateNormal
          },
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
            html.ul(
              [attr.class("hidden md:flex space-x-8 pr-2")],
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
                      label: "URLs",
                      attributes: [],
                    ),
                    view_header_link(
                      target: routes.UiComponents,
                      current: model.route,
                      label: "UI",
                      attributes: [],
                    ),
                    view_header_link(
                      target: routes.Notifications,
                      current: model.route,
                      label: "ntfy",
                      attributes: [],
                    ),
                  ]
                  _ -> []
                },
                [],
              ]),
            ),
            // Hamburger menu for auth actions
            html.div([attr.class("relative")], [
              html.button(
                [
                  attr.class(
                    "px-4 py-2 bg-zinc-800 hover:bg-teal-500/10 transition-colors duration-200",
                  ),
                  mouse.on_mouse_down_no_right(ProfileMenuToggled),
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
                        "absolute right-0 mt-2 w-48 shadow-lg bg-zinc-800 border border-l-2 border-zinc-700  z-50",
                      ),
                    ],
                    [
                      html.div([attr.class("py-1")], [
                        html.ul(
                          [
                            attr.class(
                              "flex md:hidden flex-col border-b border-zinc-400",
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
                                  label: "URLs",
                                  attributes: top_nav_attributes_small,
                                ),
                                view_header_link(
                                  target: routes.UiComponents,
                                  current: model.route,
                                  label: "UI",
                                  attributes: top_nav_attributes_small,
                                ),
                                view_header_link(
                                  target: routes.Notifications,
                                  current: model.route,
                                  label: "ntfy",
                                  attributes: top_nav_attributes_small,
                                ),
                                view_header_link(
                                  target: routes.DjotDemo,
                                  current: model.route,
                                  label: "Djot",
                                  attributes: top_nav_attributes_small,
                                ),
                              ]
                              _ -> []
                            },
                            [],
                          ]),
                        ),
                        case model.session {
                          session.Unauthenticated ->
                            ui.button_menu(
                              "Login",
                              ui.ColorTeal,
                              ui.ButtonStateNormal,
                              ProfileMenuAction(LoginFormToggled),
                            )
                          session.Pending ->
                            ui.button_menu(
                              "Login",
                              ui.ColorTeal,
                              ui.ButtonStatePending,
                              ProfileMenuAction(AuthLogoutClicked),
                            )
                          session.Authenticated(_auth_sess) ->
                            ui.button_menu(
                              "Logout",
                              ui.ColorOrange,
                              ui.ButtonStateNormal,
                              ProfileMenuAction(AuthLogoutClicked),
                            )
                        },
                        case model.session {
                          session.Authenticated(_) ->
                            ui.button_menu(
                              "Profile",
                              ui.ColorTeal,
                              ui.ButtonStateNormal,
                              ProfileMenuAction(
                                UserNavigatedTo(routes.to_uri(routes.Profile)),
                              ),
                            )
                          _ -> html.text("")
                        },
                        case model.debug_use_local_storage {
                          True ->
                            ui.button_menu_custom(
                              [
                                html.div([attr.class("flex justify-between")], [
                                  html.text("LocalStorage"),
                                  icon.view(
                                    [attr.class("w-6 text-green-400")],
                                    icon.Checkmark,
                                  ),
                                ]),
                              ],
                              ui.ColorNeutral,
                              ui.ButtonStateNormal,
                              DebugToggleLocalStorage,
                            )
                          False ->
                            ui.button_menu_custom(
                              [
                                html.div([attr.class("flex justify-between ")], [
                                  html.text("LocalStorage"),
                                  icon.view(
                                    [attr.class("w-6 text-orange-400")],
                                    icon.Close,
                                  ),
                                ]),
                              ],
                              ui.ColorNeutral,
                              ui.ButtonStateNormal,
                              DebugToggleLocalStorage,
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
        #(
          "relative cursor-pointer transition-all duration-300 ease-out px-3 py-2 rounded-lg",
          True,
        ),
        #("active text-pink-500", routes.is_sub(route: to, maybe_sub: curr)),
      ]),
      mouse.on_mouse_down_no_right(UserMouseDownNavigation(to |> routes.to_uri)),
    ]),
    [view_internal_link(to |> routes.to_uri, [html.text(text)])],
  )
}

fn view_loading() -> List(Element(Msg)) {
  [ui.loading_state("Loading page...", None, ui.ColorNeutral)]
}

// removed unused old view function; replaced by pages/article_list_view.gleam

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
          content: article.content |> rd.to_loaded(preview_content),
          draft: None,
          id: article.id,
          leading: draft.leading(draft),
          revision: article.revision,
          slug: draft.slug(draft),
          subtitle: draft.subtitle(draft),
        )
      let preview = article_view.view_article_page(draft_article, session.Unauthenticated)

      [
        // Toggle button for mobile
        html.div([attr.class("lg:hidden mb-4 flex justify-center")], [
          ui.button(
            case model.edit_view_mode {
              EditViewModeEdit -> "Show Preview"
              EditViewModePreview -> "Show Editor"
            },
            ui.ColorTeal,
            ui.ButtonStateNormal,
            EditViewModeToggled,
          ),
        ]),
        // Main content area
        html.div(
          [
            attr.classes([
              #("grid gap-4 lg:gap-8 h-screen", True),
              #("grid-cols-1 lg:grid-cols-2", True),
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
          "w-full bg-zinc-800 border border-zinc-600 rounded-md p-3 sm:p-2 font-light text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
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
            "w-full h-20 sm:h-24 bg-zinc-800 border border-zinc-600 rounded-md p-3 sm:p-2 font-bold text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
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
            "w-full h-64 sm:h-80 lg:h-96 bg-zinc-800 border border-zinc-600 rounded-md p-4 font-mono text-sm text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
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
            mouse.on_mouse_down_no_right(ArticleDraftDiscardClicked(article)),
            attr.disabled(draft.is_saving(draft)),
          ],
          [html.text("Discard Changes")],
        ),
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600 transition-colors duration-200",
            ),
            mouse.on_mouse_down_no_right(ArticleDraftSaveClicked(article)),
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




// removed old URL index helpers; page views now in pages/url_index_view.gleam

fn view_url_list(model: Model) -> Element(Msg) {
  case model.short_urls {
    NotInitialized ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          ui.loading("Loading URLs...", ui.ColorNeutral),
        ],
      )
    Pending(_, _) ->
      html.div(
        [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
        [
          html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
            html.text("URLs"),
          ]),
          ui.loading("Loading URLs...", ui.ColorNeutral),
        ],
      )
    Loaded(short_urls, _, _) -> {
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
              ui.empty_state(
                "No short URLs created yet",
                "Create your first short URL using the form above.",
                None,
              ),
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
    Errored(error, _) ->
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
              mouse.on_mouse_down_no_right(ShortUrlCopyClicked(url.short_code)),
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
              mouse.on_mouse_down_no_right(ShortUrlToggleExpanded(url.id)),
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
              mouse.on_mouse_down_no_right(ShortUrlToggleActiveClicked(
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
              mouse.on_mouse_down_no_right(ShortUrlToggleExpanded(url.id)),
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
            mouse.on_mouse_down_no_right(ShortUrlToggleExpanded(url.id)),
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
              mouse.on_mouse_down_no_right(ShortUrlCopyClicked(url.short_code)),
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
              mouse.on_mouse_down_no_right(ShortUrlToggleActiveClicked(
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
            mouse.on_mouse_down_no_right(ShortUrlToggleExpanded(url.id)),
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
              mouse.on_mouse_down_no_right(ShortUrlToggleExpanded(url.id)),
            ],
            [html.text(url.target_url)],
          ),
        ]),
        // Metadata grid
        html.div([attr.class("space-y-3 text-sm mb-4")], [
          html.div([attr.class("flex justify-between items-center")], [
            html.span([attr.class("text-zinc-500 shrink-0")], [
              html.text("Created By:"),
            ]),
            html.span([attr.class("text-zinc-300 truncate ml-2")], [
              html.text(url.created_by),
            ]),
          ]),
          html.div([attr.class("flex justify-between items-center")], [
            html.span([attr.class("text-zinc-500 shrink-0")], [
              html.text("Access Count:"),
            ]),
            html.span([attr.class("text-zinc-300 font-mono")], [
              html.text(int.to_string(url.access_count)),
            ]),
          ]),
          html.div([attr.class("flex justify-between items-center")], [
            html.span([attr.class("text-zinc-500 shrink-0")], [
              html.text("Created:"),
            ]),
            html.span([attr.class("text-zinc-300")], [
              html.text(
                birl.from_unix_milli(url.created_at * 1000)
                |> birl.to_naive_date_string,
              ),
            ]),
          ]),
          html.div([attr.class("flex justify-between items-center")], [
            html.span([attr.class("text-zinc-500 shrink-0")], [
              html.text("Updated:"),
            ]),
            html.span([attr.class("text-zinc-300")], [
              html.text(
                birl.from_unix_milli(url.updated_at * 1000)
                |> birl.to_naive_date_string,
              ),
            ]),
          ]),
        ]),
        // Action buttons
        html.div([attr.class("space-y-2")], [
          html.button(
            [
              attr.class(
                "w-full px-4 py-3 text-sm font-medium text-teal-400 border border-teal-600 bg-teal-500/10 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400 cursor-pointer transition-colors duration-200 rounded",
              ),
              mouse.on_mouse_down_no_right(ShortUrlCopyClicked(url.short_code)),
            ],
            [
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
                  "w-full px-4 py-3 text-sm font-medium text-orange-400 border border-orange-600 bg-orange-500/10 hover:bg-orange-950/50 hover:text-orange-300 hover:border-orange-400 cursor-pointer transition-colors duration-200 rounded"
                False ->
                  "w-full px-4 py-3 text-sm font-medium text-teal-400 border border-teal-600 bg-teal-500/10 hover:bg-teal-950/50 hover:text-teal-300 hover:border-teal-400 cursor-pointer transition-colors duration-200 rounded"
              }),
              mouse.on_mouse_down_no_right(ShortUrlToggleActiveClicked(
                url.id,
                url.is_active,
              )),
            ],
            [
              html.text(case url.is_active {
                True -> "Deactivate"
                False -> "Activate"
              }),
            ],
          ),
          html.button(
            [
              attr.class(
                "w-full px-4 py-3 text-sm font-medium text-red-400 border border-red-600 bg-red-500/10 hover:bg-red-950/50 hover:text-red-300 hover:border-red-400 cursor-pointer transition-colors duration-200 rounded",
              ),
              mouse.on_mouse_down_no_right(ShortUrlDeleteClicked(url.id)),
            ],
            [html.text("Delete")],
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

  html.div([], [
    ui.modal_backdrop(ShortUrlDeleteCancelClicked),
    ui.modal(
      "Delete Short URL",
      [
        html.p([attr.class("text-zinc-300")], [
          html.text("Are you sure you want to delete the short URL "),
          html.span([attr.class("font-mono text-pink-400")], [
            html.text("u.jst.dev/" <> url_to_delete),
          ]),
          html.text("? This action cannot be undone."),
        ]),
      ],
      [
        ui.button(
          "Cancel",
          ui.ColorTeal,
          ui.ButtonStateNormal,
          ShortUrlDeleteCancelClicked,
        ),
        ui.button(
          "Delete",
          ui.ColorRed,
          ui.ButtonStateNormal,
          ShortUrlDeleteConfirmClicked(delete_id),
        ),
      ],
      ShortUrlDeleteCancelClicked,
    ),
  ])
}

fn view_url_info_page(model: Model, short_code: String) -> List(Element(Msg)) {
  case model.short_urls {
    Loaded(urls, _, _) -> {
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
                ui.button(
                  "Back to URLs",
                  ui.ColorTeal,
                  ui.ButtonStateNormal,
                  UserMouseDownNavigation(routes.to_uri(routes.UrlShortIndex)),
                ),
                ui.button(
                  case model.copy_feedback == Some(url.short_code) {
                    True -> "Copied!"
                    False -> "Copy URL"
                  },
                  ui.ColorTeal,
                  ui.ButtonStateNormal,
                  ShortUrlCopyClicked(url.short_code),
                ),
                ui.button(
                  case url.is_active {
                    True -> "Deactivate"
                    False -> "Activate"
                  },
                  case url.is_active {
                    True -> ui.ColorOrange
                    False -> ui.ColorTeal
                  },
                  ui.ButtonStateNormal,
                  ShortUrlToggleActiveClicked(url.id, url.is_active),
                ),
                ui.button(
                  "Delete URL",
                  ui.ColorRed,
                  ui.ButtonStateNormal,
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

// removed: moved to partials/article_partials.gleam

// removed: moved to partials/article_partials.gleam

// removed: moved to partials/article_partials.gleam

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
            mouse.on_mouse_down_no_right(
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
            mouse.on_mouse_down_no_right(ArticlePublishClicked(article)),
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
            mouse.on_mouse_down_no_right(ArticleUnpublishClicked(article)),
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
            mouse.on_mouse_down_no_right(ArticleDeleteClicked(article)),
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
      attr.class(
        "text-2xl sm:text-3xl sm:h-10 md:text-4xl md:h-12 font-bold text-pink-700",
      ),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.div([attr.id("article-subtitle-" <> slug), attr.class("page-subtitle")], [
    html.text(title),
  ])
}

// removed: moved to partials/article_partials.gleam

// moved to partials/article_partials.gleam
fn view_simple_paragraph(text: String) -> Element(Msg) {
  html.p([attr.class("pt-8")], [html.text(text)])
}

fn view_error(error_string: String) -> Element(Msg) {
  ui.error_state(ui.ErrorGeneric, "Something went wrong", error_string, None)
}

fn view_article_listing_loading() -> List(Element(Msg)) {
  [
    ui.page_title("Articles"),
    ui.loading_state("Loading articles...", None, ui.ColorNeutral),
  ]
}

fn view_internal_link(uri: Uri, content: List(Element(Msg))) -> Element(Msg) {
  html.a(
    [
      attr.class(""),
      attr.href(uri.to_string(uri)),
      mouse.on_mouse_down_no_right(UserMouseDownNavigation(uri)),
    ],
    content,
  )
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

// UI COMPONENTS SHOWCASE -----------------------------------------------------

fn view_ui_components() -> List(Element(Msg)) {
  [
    ui.page_header(
      "UI Components",
      Some("Showcase of all available UI components"),
    ),
    // Loading States Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Loading States", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Loading Indicators"),
        ]),
        html.div([attr.class("space-y-6")], [
          // All color variants for loading
          html.div([attr.class("grid grid-cols-2 md:grid-cols-3 gap-4")], [
            ui.loading("Loading...", ui.ColorNeutral),
            ui.loading("Loading...", ui.ColorPink),
            ui.loading("Loading...", ui.ColorTeal),
            ui.loading("Loading...", ui.ColorOrange),
            ui.loading("Loading...", ui.ColorRed),
            ui.loading("Loading...", ui.ColorGreen),
          ]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Loading Bars"),
        ]),
        html.div([attr.class("space-y-4")], [
          ui.loading_bar(ui.ColorNeutral),
          ui.loading_bar(ui.ColorPink),
          ui.loading_bar(ui.ColorTeal),
          ui.loading_bar(ui.ColorOrange),
          ui.loading_bar(ui.ColorRed),
          ui.loading_bar(ui.ColorGreen),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Full Loading States"),
        ]),
        html.div([attr.class("space-y-6")], [
          ui.loading_state(
            "Loading content...",
            Some("Please wait while we fetch your data"),
            ui.ColorTeal,
          ),
          ui.loading_state(
            "Processing...",
            Some("This may take a few moments"),
            ui.ColorOrange,
          ),
        ]),
      ]),
    ]),
    // Buttons Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Buttons", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Button Variants"),
        ]),
        // Neutral Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-zinc-400 mb-3")], [
            html.text("Neutral"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorNeutral,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorNeutral,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorNeutral,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        // Pink Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-pink-400 mb-3")], [
            html.text("Pink"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorPink,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorPink,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorPink,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        // Teal Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-teal-400 mb-3")], [
            html.text("Teal"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorTeal,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorTeal,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorTeal,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        // Orange Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-orange-400 mb-3")], [
            html.text("Orange"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorOrange,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorOrange,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorOrange,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        // Red Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-red-400 mb-3")], [
            html.text("Red"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorRed,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorRed,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorRed,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        // Green Variant - All States
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-green-400 mb-3")], [
            html.text("Green"),
          ]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button(
              "Normal",
              ui.ColorGreen,
              ui.ButtonStateNormal,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Pending",
              ui.ColorGreen,
              ui.ButtonStatePending,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            ui.button(
              "Disabled",
              ui.ColorGreen,
              ui.ButtonStateDisabled,
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
          ]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Menu Buttons"),
        ]),
        html.div(
          [attr.class("max-w-sm")],
          list.map(
            [
              #(ui.ColorNeutral, ui.ButtonStateNormal, "Neutral Menu (Normal)"),
              #(
                ui.ColorNeutral,
                ui.ButtonStatePending,
                "Neutral Menu (Pending)",
              ),
              #(
                ui.ColorNeutral,
                ui.ButtonStateDisabled,
                "Neutral Menu (Disabled)",
              ),
              #(ui.ColorPink, ui.ButtonStateNormal, "Pink Menu (Normal)"),
              #(ui.ColorPink, ui.ButtonStatePending, "Pink Menu (Pending)"),
              #(ui.ColorPink, ui.ButtonStateDisabled, "Pink Menu (Disabled)"),
              #(ui.ColorTeal, ui.ButtonStateNormal, "Teal Menu (Normal)"),
              #(ui.ColorTeal, ui.ButtonStatePending, "Teal Menu (Pending)"),
              #(ui.ColorTeal, ui.ButtonStateDisabled, "Teal Menu (Disabled)"),
              #(ui.ColorOrange, ui.ButtonStateNormal, "Orange Menu (Normal)"),
              #(ui.ColorOrange, ui.ButtonStatePending, "Orange Menu (Pending)"),
              #(
                ui.ColorOrange,
                ui.ButtonStateDisabled,
                "Orange Menu (Disabled)",
              ),
              #(ui.ColorRed, ui.ButtonStateNormal, "Red Menu (Normal)"),
              #(ui.ColorRed, ui.ButtonStatePending, "Red Menu (Pending)"),
              #(ui.ColorRed, ui.ButtonStateDisabled, "Red Menu (Disabled)"),
              #(ui.ColorGreen, ui.ButtonStateNormal, "Green Menu (Normal)"),
              #(ui.ColorGreen, ui.ButtonStatePending, "Green Menu (Pending)"),
              #(ui.ColorGreen, ui.ButtonStateDisabled, "Green Menu (Disabled)"),
            ],
            fn(btn_var) {
              let #(color, state, text) = btn_var
              ui.button_menu(text, color, state, NoOp)
            },
          ),
        ),
      ]),
    ]),
    // Form Components Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Form Components", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Input Fields"),
        ]),
        html.div([attr.class("max-w-md space-y-6")], [
          ui.form_input(
            "Email",
            "user@example.com",
            "Enter your email",
            "email",
            True,
            None,
            fn(_) { UserNavigatedTo(routes.to_uri(routes.UiComponents)) },
          ),
          ui.form_input(
            "Error State",
            "",
            "This field has an error",
            "text",
            True,
            Some("This field is required"),
            fn(_) { UserNavigatedTo(routes.to_uri(routes.UiComponents)) },
          ),
          ui.form_textarea(
            "Description",
            "Sample content",
            "Enter description",
            "h-32",
            False,
            None,
            fn(_) { UserNavigatedTo(routes.to_uri(routes.UiComponents)) },
          ),
        ]),
      ]),
    ]),
    // Status & Feedback Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Status & Feedback", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Status Badges"),
        ]),
        html.div([attr.class("flex flex-wrap gap-4 mb-8")], [
          ui.status_badge("Neutral", ui.ColorNeutral),
          ui.status_badge("Active", ui.ColorGreen),
          ui.status_badge("Pending", ui.ColorOrange),
          ui.status_badge("Error", ui.ColorRed),
          ui.status_badge("Info", ui.ColorTeal),
          ui.status_badge("Primary", ui.ColorPink),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Notices"),
        ]),
        html.div([attr.class("space-y-4")], [
          ui.notice(
            "Neutral message",
            ui.ColorNeutral,
            True,
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.notice(
            "Success message",
            ui.ColorGreen,
            True,
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.notice(
            "Warning message",
            ui.ColorOrange,
            True,
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.notice(
            "Error message",
            ui.ColorRed,
            True,
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.notice(
            "Info message",
            ui.ColorTeal,
            True,
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.notice("Primary message", ui.ColorPink, False, None),
        ]),
      ]),
    ]),
    // Error States Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Error States", [
        html.div([attr.class("space-y-8")], [
          ui.error_state(
            ui.ErrorNetwork,
            "Network Error",
            "Failed to connect to server",
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.error_state(
            ui.ErrorNotFound,
            "Not Found",
            "The requested resource was not found",
            None,
          ),
          ui.error_state(
            ui.ErrorPermission,
            "Access Denied",
            "You don't have permission to access this resource",
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
          ui.error_state(
            ui.ErrorGeneric,
            "Something Went Wrong",
            "An unexpected error occurred",
            Some(UserNavigatedTo(routes.to_uri(routes.UiComponents))),
          ),
        ]),
      ]),
    ]),
    // Modal Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Modals", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Modal Example"),
        ]),
        html.div([attr.class("space-y-4")], [
          ui.button(
            "Open Modal",
            ui.ColorTeal,
            ui.ButtonStateNormal,
            UserNavigatedTo(routes.to_uri(routes.UiComponents)),
          ),
          html.p([attr.class("text-zinc-400 text-sm")], [
            html.text("Click the button above to see a modal in action."),
          ]),
        ]),
      ]),
    ]),
    // Layout Components Section  
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Layout Components", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Cards"),
        ]),
        html.div([attr.class("space-y-0")], [
          ui.card_with_title("Card with Title", [
            html.p([attr.class("text-zinc-300")], [
              html.text("This is a card with a title section."),
            ]),
          ]),
          ui.glass_panel([
            html.h4([attr.class("text-lg font-medium text-zinc-100 mb-2")], [
              html.text("Glass Panel"),
            ]),
            html.p([attr.class("text-zinc-300")], [
              html.text("This panel has a glass-like effect."),
            ]),
          ]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Empty States"),
        ]),
        ui.empty_state(
          "No Items Found",
          "There are no items to display at the moment.",
          Some(ui.button(
            "Create New",
            ui.ColorTeal,
            ui.ButtonStateNormal,
            UserNavigatedTo(routes.to_uri(routes.UiComponents)),
          )),
        ),
      ]),
    ]),
    // Skeleton Loaders Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Skeleton Loaders", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Loading Placeholders"),
        ]),
        html.div([attr.class("space-y-6")], [
          html.div([], [
            html.h4([attr.class("text-md font-medium text-zinc-200 mb-4")], [
              html.text("Text Skeleton"),
            ]),
            ui.skeleton_text(3),
          ]),
          html.div([], [
            html.h4([attr.class("text-md font-medium text-zinc-200 mb-4")], [
              html.text("Card Skeleton"),
            ]),
            ui.skeleton_card(),
          ]),
        ]),
      ]),
    ]),
    // Page Headers Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Page Headers", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Page Header with Subtitle"),
        ]),
        ui.page_header(
          "Example Page Title",
          Some("This is a subtitle that provides additional context"),
        ),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Page Title Only"),
        ]),
        ui.page_title("Simple Page Title"),
      ]),
    ]),
    // Typography & Links Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Typography & Links", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Text Styles"),
        ]),
        html.div([attr.class("space-y-4")], [
          html.p([attr.class("text-zinc-300")], [
            html.text("Regular text with "),
            ui.link_primary(
              "primary link",
              UserNavigatedTo(routes.to_uri(routes.UiComponents)),
            ),
            html.text(" embedded."),
          ]),
        ]),
      ]),
    ]),
    // Layout Helpers Section
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("Layout Helpers", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [
          html.text("Flex Between Layout"),
        ]),
        ui.flex_between(
          html.span([attr.class("text-zinc-300")], [html.text("Left content")]),
          html.span([attr.class("text-zinc-300")], [html.text("Right content")]),
        ),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [
          html.text("Content Container"),
        ]),
        ui.content_container([
          html.p([attr.class("text-zinc-300")], [
            html.text(
              "This content is wrapped in a container with consistent spacing.",
            ),
          ]),
          html.p([attr.class("text-zinc-300")], [
            html.text("Multiple elements get proper spacing between them."),
          ]),
        ]),
      ]),
    ]),
  ]
}

fn view_notifications(model: Model) -> List(Element(Msg)) {
  [
    view_title("Send Notification", "notifications"),
    view_simple_paragraph(
      "Send push notifications to your devices via ntfy.sh. Configure your ntfy topic to receive notifications on your mobile device or desktop.",
    ),
    view_notification_help(),
    view_notification_form(model),
  ]
}

fn view_notification_help() -> Element(Msg) {
  html.div(
    [attr.class("mt-6 p-4 bg-teal-900/30 border border-teal-600/40 rounded-lg")],
    [
      html.h4([attr.class("text-teal-400 font-medium mb-2")], [
        html.text("How to use:"),
      ]),
      html.ul([attr.class("text-sm text-zinc-300 space-y-1")], [
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Download the ntfy app on your phone or subscribe to a topic on ntfy.sh",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Enter your custom topic or leave empty to use your default user topic",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Choose priority: Low (silent), Normal (default sound), High (louder), Urgent (critical alert)",
          ),
        ]),
        html.li([attr.class("flex items-start")], [
          html.span([attr.class("text-teal-400 mr-2")], [html.text("•")]),
          html.text(
            "Categories help organize your notifications (e.g., 'system', 'alerts', 'reminders')",
          ),
        ]),
      ]),
    ],
  )
}

fn view_notification_form(model: Model) -> Element(Msg) {
  html.div(
    [attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")],
    [
      html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [
        html.text("Send Notification"),
      ]),
      html.div([attr.class("space-y-4")], [
        ui.form_input(
          "Title",
          model.notification_form_title,
          "Enter notification title",
          "text",
          True,
          None,
          NotificationFormTitleUpdated,
        ),
        ui.form_input(
          "Message",
          model.notification_form_message,
          "Enter notification message",
          "text",
          True,
          None,
          NotificationFormMessageUpdated,
        ),
        ui.form_input(
          "Category",
          model.notification_form_category,
          "e.g., system, alerts, reminders, info",
          "text",
          True,
          None,
          NotificationFormCategoryUpdated,
        ),
        html.div([attr.class("space-y-2")], [
          html.label([attr.class("block text-sm font-medium text-zinc-400")], [
            html.text("Priority"),
          ]),
          html.select(
            [
              attr.class(
                "w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200",
              ),
              event.on_input(NotificationFormPriorityUpdated),
            ],
            [
              html.option(
                [
                  attr.value("low"),
                  attr.selected(model.notification_form_priority == "low"),
                ],
                "Low",
              ),
              html.option(
                [
                  attr.value("normal"),
                  attr.selected(model.notification_form_priority == "normal"),
                ],
                "Normal",
              ),
              html.option(
                [
                  attr.value("high"),
                  attr.selected(model.notification_form_priority == "high"),
                ],
                "High",
              ),
              html.option(
                [
                  attr.value("urgent"),
                  attr.selected(model.notification_form_priority == "urgent"),
                ],
                "Urgent",
              ),
            ],
          ),
        ]),
        ui.form_input(
          "Ntfy Topic (optional)",
          model.notification_form_ntfy_topic,
          "Custom topic name or leave empty for user_{your_id}",
          "text",
          False,
          None,
          NotificationFormNtfyTopicUpdated,
        ),
        ui.button(
          case model.notification_sending {
            True -> "Sending..."
            False -> "Send Notification"
          },
          ui.ColorTeal,
          case
            model.notification_sending,
            model.notification_form_title == ""
            || model.notification_form_message == ""
            || model.notification_form_category == ""
          {
            True, _ -> ui.ButtonStatePending
            False, True -> ui.ButtonStateDisabled
            _, _ -> ui.ButtonStateNormal
          },
          NotificationSendClicked,
        ),
      ]),
    ],
  )
}

// MAIN ------------------------------------------------------------------------

pub fn main() {
  // let app = lustre.application(init, update, view)
  let app = lustre.application(init, update_with_localstorage, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

fn init(_) -> #(Model, Effect(Msg)) {
  // if this failes we have no app to run..
  let uri = case modem.initial_uri() {
    Ok(u) -> u
    Error(_) -> routes.to_uri(routes.Index)
  }

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
      // Keyboard
      keys_down: set.new(),
      chords_available: set.new(),
      chord_bindings: [],
      // Notification form fields
      notification_form_title: "",
      notification_form_message: "",
      notification_form_category: "",
      notification_form_priority: "normal",
      notification_form_ntfy_topic: "",
      notification_form_data: [],
      notification_sending: False,
      // profile state
      profile_user: NotInitialized,
      profile_form_username: "",
      profile_form_email: "",
      profile_form_new_password: "",
      profile_form_confirm_password: "",
      profile_form_old_password: "",
      profile_saving: False,
      password_saving: False,
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> UserNavigatedTo
    })

  // let #(model_nav, effect_nav) = update_navigation(model, uri)

  // Set up global keyboard listener

  let model = recompute_bindings_for_current_page(model)

  #(
    model,
    effect.batch([
      effect_modem,
      local_storage_effect,
      // effect_nav,
      session.auth_check(AuthCheckResponse, model.base_uri),
      key.setup(should_prevent_keydown(model.chords_available), KeyboardDown, KeyboardUp),
      window_events.setup(WindowUnfocused),
    ]),
  )
}
