import article/article
import article/id.{type ArticleId} as article_id
import gleam/list
import gleam/uri.{type Uri}
import utils/http.{type HttpError}
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}

pub type Route {
  Index
  Articles
  Article(slug: String)
  ArticleEdit(id: String)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

pub fn from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", slug] -> {
      Article(slug)
    }
    ["article", id, "edit"] -> {
      ArticleEdit(id)
    }
    ["about"] -> About
    _ -> NotFound(uri)
  }
}

pub fn to_string(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about"
    Articles -> "/articles"
    Article(slug) -> "/article/" <> slug
    ArticleEdit(id) -> "/article/" <> id <> "/edit"
    NotFound(uri) -> "/404?uri=" <> uri.to_string(uri)
  }
}
