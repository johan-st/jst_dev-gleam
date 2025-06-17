import article/article.{type Article}
import article/id
import gleam/list
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}
import utils/session.{type Session}

// Improved Page type with better state management
pub type Page {
  // Home/Index pages
  PageIndex

  // Article-related pages
  PageArticle(article: Article, session: Session)
  PageArticleEdit(article: Article)
  PageArticleList(articles: List(Article), session: Session)
  PageArticleListLoading

  // Error states  
  PageError(error: PageError)

  // Static pages
  PageAbout
  PageNotFound(requested_uri: Uri)
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
    PageArticleEdit(article) -> {
      let assert Ok(uri) =
        uri.parse("/article/" <> id.to_string(article.id) <> "/edit")
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
    PageNotFound(uri) -> {
      uri
    }
  }
}

pub fn from_uri(
  uri: Uri,
  session: Session,
  articles: RemoteData(List(Article), HttpError),
) -> Page {
  case uri.path_segments(uri.path) {
    [] | [""] -> PageIndex
    ["articles"] -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized -> PageArticleListLoading
        remote_data.Errored(error) ->
          PageError(HttpError(error, "Failed to load article list"))
        remote_data.Loaded(articles_list) ->
          PageArticleList(articles_list, session)
      }
    }
    ["article", slug] -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized ->
          PageError(Other("articles not initialized"))
        remote_data.Errored(error) ->
          PageError(HttpError(error, "Failed to load articles"))
        remote_data.Loaded(articles_list) -> {
          case find_article_by_slug(articles_list, slug) {
            Ok(article) -> PageArticle(article, session)
            Error(_) ->
              PageError(ArticleNotFound(
                slug,
                get_available_slugs(articles_list),
              ))
          }
        }
      }
    }
    ["article", id, "edit"] -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized ->
          PageError(Other("articles not initialized"))
        remote_data.Errored(error) ->
          PageError(HttpError(error, "Failed to load articles for editing"))
        remote_data.Loaded(articles_list) -> {
          case find_article_by_id(articles_list, id) {
            Ok(article) -> {
              let article_updated = case
                article.can_edit(article, session),
                article.get_draft(article)
              {
                True, Some(draft) -> PageArticleEdit(article)
                True, None ->
                  PageArticleEdit(
                    article.ArticleV1(
                      ..article,
                      draft: Some(article.to_draft(article)),
                    ),
                  )
                False, _ -> PageError(AuthenticationRequired("edit article"))
              }
            }
            Error(_) -> PageError(ArticleEditNotFound(id))
          }
        }
      }
    }
    ["about"] -> PageAbout
    _ -> PageNotFound(uri)
  }
}

fn get_available_slugs(articles: List(Article)) -> List(String) {
  list.map(articles, fn(article) {
    case article {
      article.ArticleV1(_, slug, _, _, _, _, _, _) -> slug
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
      article.ArticleV1(_, article_slug, _, _, _, _, _, _) ->
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
      article.ArticleV1(article_id, _, _, _, _, _, _, _) ->
        id.to_string(article_id) == id_string
    }
  })
}
