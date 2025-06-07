import article/article.{type Article}
import article/id.{type ArticleId} as article_id
import gleam/list
import gleam/uri.{type Uri}
import utils/http.{type HttpError}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}

pub type Route {
  Index
  Articles(RemoteData(List(Article), HttpError))
  Article(article: Article)
  ArticleNotFound(
    available_articles: RemoteData(List(Article), HttpError),
    slug: String,
  )
  ArticleEdit(article: Article)
  ArticleEditNotFound(
    available_articles: RemoteData(List(Article), HttpError),
    id: ArticleId,
  )
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

pub fn from_uri(
  uri: Uri,
  loaded_articles: RemoteData(List(Article), HttpError),
) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles(loaded_articles)
    ["article", slug] -> {
      echo "article " <> slug
      case loaded_articles {
        Loaded(articles) -> {
          case list.find(articles, fn(article) { article.slug == slug }) {
            Ok(article) -> Article(article)
            Error(Nil) -> ArticleNotFound(loaded_articles, slug)
          }
        }
        _ -> ArticleNotFound(loaded_articles, slug)
      }
    }
    ["article", id, "edit"] -> {
      echo "edit " <> id
      case loaded_articles {
        Loaded(articles) -> {
          case
            list.find(articles, fn(article) {
              article.id == article_id.from_string(id)
            })
          {
            Ok(article) -> ArticleEdit(article)
            Error(Nil) ->
              ArticleEditNotFound(loaded_articles, article_id.from_string(id))
          }
        }
        _ -> ArticleEditNotFound(loaded_articles, article_id.from_string(id))
      }
    }
    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

pub fn to_string(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about"
    Articles(_loaded_articles) -> "/articles"
    Article(article) -> "/article/" <> article.slug
    ArticleNotFound(_available_articles, slug) -> "/article/" <> slug
    ArticleEdit(article) ->
      "/article/" <> article_id.to_string(article.id) <> "/edit"
    ArticleEditNotFound(_available_articles, id) ->
      "/article/" <> article_id.to_string(id) <> "/edit"
    NotFound(uri) -> "/404?uri=" <> uri.to_string(uri)
  }
}
