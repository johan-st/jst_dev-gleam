import article/article.{type Article}
import article/draft.{type Draft}
import article/id
import routes/routes.{type Route}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}
import utils/session.{type Session, type SessionAuthenticated}
import gleam/list
import gleam/option.{Some, None}
import gleam/uri

// Improved Page type with better state management
pub type Page {
  // Home/Index pages
  PageIndex

  // Article-related pages
  PageArticle(article: Article, permissions: PagePermissions)
  PageArticleEdit(article: Article, draft: Draft, permissions: PagePermissions)
  PageArticleList(articles: List(Article), permissions: PagePermissions)
  PageArticleListLoading 
  
  // Error states  
  PageError(error: PageError)
  
  // Static pages
  PageAbout
  PageNotFound(requested_path: String)
}

// Consolidated permissions
pub type PagePermissions {
  PagePermissions(can_edit: Bool, can_delete: Bool, can_create: Bool)
}



// Consolidated error types
pub type PageError {
  ArticleNotFound(slug: String, available_slugs: List(String))
  ArticleEditNotFound(id: String)
  HttpError(error: HttpError, context: String)
  AuthenticationRequired(attempted_action: String)
}

pub fn from_route(
  route: Route,
  session: Session,
  articles: RemoteData(List(Article), HttpError),
) -> Page {
  let permissions = get_permissions_from_session(session)

  case route {
    routes.Index -> PageIndex
    
    routes.Article(slug) -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized -> PageArticleListLoading
        remote_data.Loaded(articles_list) -> {
          case find_article_by_slug(articles_list, slug) {
            Ok(article) -> PageArticle(article, permissions)
            Error(_) -> PageError(ArticleNotFound(slug, get_available_slugs(articles_list)))
          }
        }
        remote_data.Errored(error) -> PageError(HttpError(error, "Failed to load articles"))
      }
    }
    
    routes.ArticleEdit(id) -> {
      case session {
        session.Unauthenticated -> PageError(AuthenticationRequired("edit article"))
        session.Authenticated(_) -> {
          case articles {
            remote_data.Pending -> PageArticleListLoading
            remote_data.NotInitialized -> PageArticleListLoading
            remote_data.Loaded(articles_list) -> {
              case find_article_by_id(articles_list, id) {
                Ok(article) -> {
                  // Create a simple draft for now - you can enhance this
                  let draft = draft.Draft(
                    saving: False,
                    slug: "",
                    title: "",
                    subtitle: "",
                    leading: "",
                    content: []
                  )
                  PageArticleEdit(article, draft, permissions)
                }
                Error(Nil) -> PageError(ArticleEditNotFound(id))
              }
            }
            remote_data.Errored(error) -> PageError(HttpError(error, "Failed to load articles for editing"))
          }
        }
      }
    }
    
    routes.Articles -> {
      case articles {
        remote_data.Pending -> PageArticleListLoading
        remote_data.NotInitialized -> PageArticleListLoading
        remote_data.Loaded(articles_list) -> PageArticleList(articles_list, permissions)
        remote_data.Errored(error) -> PageError(HttpError(error, "Failed to load article list"))
      }
    }
    
    routes.About -> PageAbout
    routes.NotFound(uri) -> PageNotFound(uri.to_string(uri))
  }
}

// Helper functions
fn get_permissions_from_session(session: Session) -> PagePermissions {
  case session {
    session.Authenticated(_) -> PagePermissions(
      can_edit: True,
      can_delete: True,
      can_create: True
    )
    session.Unauthenticated -> PagePermissions(
      can_edit: False,
      can_delete: False,
      can_create: False
    )
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
fn find_article_by_slug(articles: List(Article), slug: String) -> Result(Article, Nil) {
  list.find(articles, fn(article) {
    case article {
      article.ArticleV1(_, article_slug, _, _, _, _, _, _) -> article_slug == slug
    }
  })
}

// Helper function to find article by id
fn find_article_by_id(articles: List(Article), id_string: String) -> Result(Article, Nil) {
  list.find(articles, fn(article) {
    case article {
      article.ArticleV1(article_id, _, _, _, _, _, _, _) -> id.to_string(article_id) == id_string
    }
  })
}
