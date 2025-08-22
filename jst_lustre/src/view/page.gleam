import article.{type Article}
import gleam/dict
import gleam/list
import gleam/uri.{type Uri}
import routes.{type Route}
import session.{type Session}
import sync.{type KV, type KVState}
import utils/http.{type HttpError}
import utils/short_url.{type ShortUrl}

/// The `Page` ADT encapsulates all views/screens in the app.
///
/// - Drives routing: produced by `from_route/4`, converted to URLs by `to_uri/1`.
/// - Drives rendering: consumed by `page/*_view` modules to render UI.
/// - Carries per-view state such as `Session`, `Article`, loading and error info.
/// - Add new screens by introducing new `Page` constructors.
pub type Page {
  Loading(Route)

  // Home/Index page
  PageIndex

  // Article-related page
  PageArticle(article: Article, session: Session)
  PageArticleEdit(
    article: Article,
    session_authenticated: session.SessionAuthenticated,
  )
  PageArticleList(in_sync: Bool, articles: List(Article), session: Session)

  // Url Shortener page
  PageUrlShortIndex(kv_short_urls: sync.KV(String, ShortUrl))
  PageUrlShortInfo(
    short_url: ShortUrl,
    session_authenticated: session.SessionAuthenticated,
  )

  // UI Components showcase
  PageUiComponents

  // Notifications
  PageNotifications

  // Profile
  PageProfile(session_authenticated: session.SessionAuthenticated)

  // Debug
  PageDebug

  // Error states  
  PageError(error: PageError)

  // Static page
  PageAbout
  PageNotFound(requested_uri: Uri)
  PageDjotDemo(
    session_authenticated: session.SessionAuthenticated,
    content: String,
  )
}

// Consolidated error types
pub type PageError {
  ArticleNotFound(slug: String, available_slugs: List(String))
  ArticleEditNotFound(id: String)
  HttpError(error: HttpError, context: String)
  AuthenticationRequired(attempted_action: String)
  Other(msg: String)
}

pub fn to_uri(page: Page) -> Uri {
  case page {
    Loading(route) -> {
      routes.to_uri(route)
    }
    PageIndex -> {
      let assert Ok(uri) = uri.parse("/")
      uri
    }
    PageArticleList(_, _, _) -> {
      let assert Ok(uri) = uri.parse("/articles")
      uri
    }
    PageArticle(article, _) -> {
      let assert Ok(uri) = uri.parse("/article/" <> article.slug)
      uri
    }
    PageArticleEdit(article, _) -> {
      let assert Ok(uri) = uri.parse("/article/" <> article.id <> "/edit")
      uri
    }
    PageUrlShortIndex(_) -> {
      let assert Ok(uri) = uri.parse("/url/")
      uri
    }
    PageUrlShortInfo(short, _) -> {
      let assert Ok(uri) = uri.parse("/url/" <> short.id)
      uri
    }
    PageUiComponents -> {
      let assert Ok(uri) = uri.parse("/ui-components")
      uri
    }
    PageNotifications -> {
      let assert Ok(uri) = uri.parse("/notifications")
      uri
    }
    PageProfile(_) -> {
      let assert Ok(uri) = uri.parse("/profile")
      uri
    }

    PageDebug -> {
      let assert Ok(uri) = uri.parse("/debug")
      uri
    }

    PageError(error) -> {
      case error {
        ArticleNotFound(slug, _) -> {
          let assert Ok(uri) = uri.parse("/article/" <> slug)
          uri
        }
        ArticleEditNotFound(id) -> {
          let assert Ok(uri) = uri.parse("/article/" <> id <> "/edit")
          uri
        }
        HttpError(_, _) -> {
          let assert Ok(uri) = uri.parse("/")
          uri
        }
        AuthenticationRequired(_) -> {
          let assert Ok(uri) = uri.parse("/")
          uri
        }
        Other(_) -> {
          let assert Ok(uri) = uri.parse("/")
          uri
        }
      }
    }

    PageAbout -> {
      let assert Ok(uri) = uri.parse("/about")
      uri
    }
    PageNotFound(requested_uri) -> requested_uri
    PageDjotDemo(_, _) -> {
      let assert Ok(uri) = uri.parse("/djot-demo")
      uri
    }
  }
}

// Note: Rendering for page lives under `page/*_view.gleam` modules

pub fn from_route(
  loading _loading: Bool,
  route route: Route,
  session session: Session,
  articles articles: sync.KV(String, Article),
  kv_url kv_url: sync.KV(String, ShortUrl),
) -> Page {
  case route {
    routes.Index -> PageIndex
    routes.Articles -> {
      case articles.state {
        sync.NotInitialized -> PageError(Other("articles not initialized"))
        sync.Connecting -> PageError(Other("articles connecting"))
        sync.CatchingUp -> PageArticleList(False, [], session)
        sync.InSync -> {
          let articles_list = articles.data |> dict.values()
          PageArticleList(True, articles_list, session)
        }
        sync.KVError(error) -> PageError(Other(error))
      }
    }
    routes.Article(slug) -> {
      // Search through all articles to find the one with matching slug
      let articles_list = articles.data |> dict.values()
      case find_article_by_slug(articles_list, slug) {
        Ok(article) -> PageArticle(article, session)
        Error(_) ->
          PageError(ArticleNotFound(slug, articles.data |> dict.keys()))
      }
    }
    routes.ArticleEdit(id) -> {
      case articles.data |> dict.get(id) {
        Ok(article) -> {
          case session {
            session.Authenticated(session_auth) ->
              PageArticleEdit(article, session_auth)
            session.Unauthenticated ->
              PageError(AuthenticationRequired("edit article"))
            session.Pending -> PageError(AuthenticationRequired("edit article"))
          }
        }
        Error(_) -> PageError(ArticleEditNotFound(id))
      }
    }
    routes.About -> PageAbout
    routes.DjotDemo ->
      case session {
        session.Authenticated(session_auth) -> PageDjotDemo(session_auth, "")
        session.Unauthenticated ->
          PageError(AuthenticationRequired("access DJOT demo"))
        session.Pending -> PageError(AuthenticationRequired("access DJOT demo"))
      }
    routes.UrlShortIndex -> PageUrlShortIndex(kv_url)
    routes.UrlShortInfo(short) -> {
      let res_url = dict.get(kv_url.data, short)
      case res_url, kv_url.state, session {
        Ok(short_url), _, session.Authenticated(session_auth) -> {
          PageUrlShortInfo(short_url, session_auth)
        }
        Ok(_short_url), _, session.Unauthenticated -> {
          PageError(AuthenticationRequired("access URL shortener info"))
        }
        Ok(_short_url), _, session.Pending -> {
          PageError(AuthenticationRequired("access URL shortener info"))
        }
        Error(Nil), sync.NotInitialized, _ -> {
          PageError(Other("URL not initialized"))
        }
        Error(Nil), sync.Connecting, _ -> {
          PageError(Other("URL connecting"))
        }
        Error(Nil), sync.CatchingUp, _ -> {
          PageError(Other("URL catching up"))
        }
        Error(Nil), sync.InSync, _ -> {
          PageError(Other("URL in sync"))
        }
        Error(Nil), sync.KVError(error), _ -> {
          PageError(Other(error))
        }
      }
    }
    routes.UiComponents -> PageUiComponents
    routes.Notifications -> PageNotifications
    routes.Profile -> {
      case session {
        session.Authenticated(session_auth) -> PageProfile(session_auth)
        session.Unauthenticated ->
          PageError(AuthenticationRequired("access profile"))
        session.Pending -> PageError(AuthenticationRequired("access profile"))
      }
    }
    routes.Debug -> PageDebug
    routes.NotFound(uri) -> PageNotFound(uri)
  }
}

pub fn get_available_slugs(articles: List(Article)) -> List(String) {
  list.map(articles, fn(article) {
    case article {
      article.ArticleV1(_, slug, _, _, _, _, _, _, _, _, _) -> slug
    }
  })
}

// Helper function to find article by slug
fn find_article_by_slug(
  articles: List(Article),
  slug: String,
) -> Result(Article, Nil) {
  list.find(articles, fn(article) {
    case article {
      article.ArticleV1(_, article_slug, _, _, _, _, _, _, _, _, _) ->
        article_slug == slug
    }
  })
}

// Helper function to find article by id
fn find_article_by_id(
  articles: List(Article),
  id_string: String,
) -> Result(Article, Nil) {
  list.find(articles, fn(article) {
    case article {
      article.ArticleV1(article_id, _, _, _, _, _, _, _, _, _, _) ->
        article_id == id_string
    }
  })
}
