import article/article.{type Article}
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/uri.{type Uri}
import routes.{type Route}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}
import session.{type Session}
import utils/short_url.{type ShortUrl}

// Improved Page type with better state management
pub type Page {
  Loading(Route)

  // Home/Index pages
  PageIndex

  // Article-related pages
  PageArticle(article: Article, session: Session)
  PageArticleEdit(
    article: Article,
    session_authenticated: session.SessionAuthenticated,
  )
  PageArticleList(articles: List(Article), session: Session)
  PageArticleListLoading

  // Url Shortener pages
  PageUrlShortIndex(session_authenticated: session.SessionAuthenticated)
  PageUrlShortInfo(
    short: String,
    session_authenticated: session.SessionAuthenticated,
  )

  // UI Components showcase
  PageUiComponents(session_authenticated: session.SessionAuthenticated)

  // Error states  
  PageError(error: PageError)

  // Static pages
  PageAbout
  PageNotFound(requested_uri: Uri)
  PageDjotDemo(content: String)
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
    PageArticleList(_, _) -> {
      let assert Ok(uri) = uri.parse("/articles")
      uri
    }
    PageArticleListLoading -> {
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
      let assert Ok(uri) = uri.parse("/url/")
      uri
    }
    PageUiComponents(_) -> {
      let assert Ok(uri) = uri.parse("/ui-components")
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
    PageDjotDemo(content) -> {
      let assert Ok(uri) = uri.parse("/djot-demo/" <> content)
      uri
    }
    PageNotFound(uri) -> {
      uri
    }
  }
}

pub fn from_route(
  loading: Bool,
  route: Route,
  session: Session,
  articles: RemoteData(List(Article), HttpError),
) -> Page {
  case loading {
    True -> Loading(route)
    False -> {
      case route {
        routes.Index -> PageIndex
        routes.Articles -> {
          case articles {
            remote_data.Pending -> PageArticleListLoading
            remote_data.NotInitialized -> PageArticleListLoading
            remote_data.Errored(error) ->
              PageError(HttpError(error, "Failed to load article list"))
            remote_data.Loaded(articles_list)
            | remote_data.Optimistic(articles_list) -> {
              let allowed_articles =
                articles_list
                |> list.filter(article.can_view(_, session))
              PageArticleList(allowed_articles, session)
            }
          }
        }
        routes.Article(slug) -> {
          case articles {
            remote_data.Pending -> PageArticleListLoading
            remote_data.NotInitialized ->
              PageError(Other("articles not initialized"))
            remote_data.Errored(error) ->
              PageError(HttpError(error, "Failed to load articles"))
            remote_data.Loaded(articles_list)
            | remote_data.Optimistic(articles_list) -> {
              let allowed_articles =
                articles_list
                |> list.filter(article.can_view(_, session))
              case find_article_by_slug(allowed_articles, slug) {
                Ok(article) -> PageArticle(article, session)
                Error(_) ->
                  PageError(ArticleNotFound(
                    slug,
                    get_available_slugs(allowed_articles),
                  ))
              }
            }
          }
        }
        routes.ArticleEdit(id) -> {
          case articles {
            remote_data.Pending -> PageArticleListLoading
            remote_data.NotInitialized ->
              PageError(Other("articles not initialized"))
            remote_data.Errored(error) ->
              PageError(HttpError(error, "Failed to load articles for editing"))
            remote_data.Loaded(articles_list)
            | remote_data.Optimistic(articles_list) -> {
              let allowed_articles =
                articles_list
                |> list.filter(article.can_view(_, session))
              case find_article_by_id(allowed_articles, id) {
                Ok(article) -> {
                  case article.can_edit(article, session), article.draft {
                    True, Some(_) -> {
                      case session {
                        session.Authenticated(session_auth) ->
                          PageArticleEdit(article, session_auth)
                        session.Unauthenticated ->
                          PageError(AuthenticationRequired("edit article"))
                        session.Pending ->
                          PageError(AuthenticationRequired("edit article"))
                      }
                    }
                    True, None -> {
                      case session {
                        session.Authenticated(session_auth) ->
                          PageArticleEdit(
                            article.ArticleV1(
                              ..article,
                              draft: article.to_draft(article),
                            ),
                            session_auth,
                          )
                        session.Unauthenticated ->
                          PageError(AuthenticationRequired("edit article"))
                        session.Pending ->
                          PageError(AuthenticationRequired("edit article"))
                      }
                    }
                    False, _ ->
                      PageError(AuthenticationRequired("edit article"))
                  }
                }
                Error(_) -> PageError(ArticleEditNotFound(id))
              }
            }
          }
        }
        routes.About -> PageAbout
        routes.DjotDemo -> PageDjotDemo("")
        routes.UrlShortIndex -> {
          case session {
            session.Authenticated(session_auth) ->
              PageUrlShortIndex(session_auth)
            session.Unauthenticated ->
              PageError(AuthenticationRequired("access URL shortener"))
            session.Pending ->
              PageError(AuthenticationRequired("access URL shortener"))
          }
        }
        routes.UrlShortInfo(short) -> {
          case session {
            session.Authenticated(session_auth) ->
              PageUrlShortInfo(short, session_auth)
            session.Unauthenticated ->
              PageError(AuthenticationRequired("access URL shortener info"))
            session.Pending ->
              PageError(AuthenticationRequired("access URL shortener info"))
          }
        }
        routes.UiComponents -> {
          case session {
            session.Authenticated(session_auth) ->
              PageUiComponents(session_auth)
            session.Unauthenticated ->
              PageError(AuthenticationRequired("access UI components"))
            session.Pending ->
              PageError(AuthenticationRequired("access UI components"))
          }
        }
        routes.NotFound(uri) -> PageNotFound(uri)
      }
    }
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
