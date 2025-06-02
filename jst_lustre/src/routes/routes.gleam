import article/article.{type Article}
import article/id.{type ArticleId} as article_id
import gleam/list
import gleam/uri.{type Uri}

pub type Route {
  Index
  Articles
  Article(article: Article)
  ArticleEdit(article: Article)
  // ArticleEdit(article: Article, editor: Editor)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

pub fn from_uri(uri: Uri, articles: List(Article)) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", slug] -> {
      case list.find(articles, fn(article) { article.slug == slug }) {
        Ok(article) -> Article(article)
        Error(_) -> NotFound(uri:)
      }
    }
    ["article", id, "edit"] -> {
      case
        echo list.find(articles, fn(article) {
          echo "article.id: " <> article_id.to_string(article.id)
          echo "id: " <> id
          article.id == article_id.from_string(id)
        })
      {
        Ok(article) -> ArticleEdit(article)
        Error(_) -> NotFound(uri:)
      }
    }
    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

pub fn to_string(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about/"
    Articles -> "/articles/"
    Article(article) -> "/article/" <> article.slug <> "/"
    ArticleEdit(article) ->
      "/article/" <> article_id.to_string(article.id) <> "/edit"
    NotFound(_) -> "/404"
  }
}
