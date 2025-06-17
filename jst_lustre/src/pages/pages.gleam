import article/article.{type Article}
import article/draft.{type Draft}
import article/id
import gleam/list
import gleam/option.{None, Some}
import gleam/uri
import routes/routes.{type Route}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}
import utils/session.{type Session}

// Improved Page type with better state management
pub type Page {
  // Home/Index pages
  PageIndex

  // Article-related pages
  PageArticle(article: Article, session: Session)
  PageArticleEdit(article: Article, draft: Draft)
  PageArticleList(articles: List(Article), session: Session)
  PageArticleListLoading

  // Error states  
  PageError(error: PageError)

  // Static pages
  PageAbout
  PageNotFound(requested_path: String)
}

// Consolidated error types
pub type PageError {
  ArticleNotFound(slug: String, available_slugs: List(String))
  ArticleEditNotFound(id: String)
  HttpError(error: HttpError, context: String)
  AuthenticationRequired(attempted_action: String)
  Other(msg: String)
}

pub fn from_route(
  route: Route,
  session: Session,
  articles: RemoteData(List(Article), HttpError),
) -> Page {
  case route {
    routes.Index -> PageIndex

    routes.Article(slug) -> {
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

    routes.ArticleEdit(id) -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized ->
          PageError(Other("articles not initialized"))
        remote_data.Errored(error) ->
          PageError(HttpError(error, "Failed to load articles for editing"))
        remote_data.Loaded(articles_list) -> {
          case find_article_by_id(articles_list, id) {
            Ok(article) -> {
              case
                article.can_edit(article, session),
                article.get_draft(article)
              {
                True, Some(draft) -> PageArticleEdit(article, draft)
                True, None ->
                  PageArticleEdit(article, article.to_draft(article))
                False, _ -> PageError(AuthenticationRequired("edit article"))
              }
            }
            Error(_) -> PageError(ArticleEditNotFound(id))
          }
        }
      }
    }

    routes.Articles -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized -> PageArticleListLoading
        remote_data.Errored(error) ->
          PageError(HttpError(error, "Failed to load article list"))
        remote_data.Loaded(articles_list) ->
          PageArticleList(articles_list, session)
      }
    }

    routes.About -> PageAbout
    routes.NotFound(uri) -> PageNotFound(uri.to_string(uri))
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
