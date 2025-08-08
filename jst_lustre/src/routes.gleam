import gleam/list
import gleam/uri.{type Uri}

pub type Route {
  Index
  Articles
  Article(slug: String)
  ArticleEdit(id: String)
  About
  DjotDemo

  // URL SHORTENER 
  UrlShortIndex
  UrlShortInfo(String)

  // UI COMPONENTS
  UiComponents

  // NOTIFICATIONS
  Notifications

  // PROFILE
  Profile

  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

fn drop_trailing_empty(segs: List(String)) -> List(String) {
  case segs {
    [] -> []
    [""] -> []
    _ -> {
      let rev = list.reverse(segs)
      case rev {
        [last, ..rest] if last == "" -> list.reverse(rest)
        _ -> segs
      }
    }
  }
}

pub fn from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) |> drop_trailing_empty {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", slug] -> Article(slug)
    ["article", id, "edit"] -> ArticleEdit(id)
    ["about"] -> About
    ["djot-demo"] -> DjotDemo
    ["url"] -> UrlShortIndex
    ["url", uid] -> UrlShortInfo(uid)
    ["ui-components"] -> UiComponents
    ["notifications"] -> Notifications
    ["profile"] -> Profile
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
    DjotDemo -> "/djot-demo"
    UrlShortIndex -> "/url"
    UrlShortInfo(short) -> "/url/" <> short
    UiComponents -> "/ui-components"
    Notifications -> "/notifications"
    Profile -> "/profile"
    NotFound(uri) -> "/404?uri=" <> uri.to_string(uri)
  }
}

pub fn to_uri(route: Route) -> Uri {
  let assert Ok(uri) = route |> to_string |> uri.parse
  uri
}

pub fn is_sub(route route: Route, maybe_sub sub: Route) -> Bool {
  let route_segs = route |> to_string |> uri.path_segments
  let maybe_sub_segs = sub |> to_string |> uri.path_segments

  do_is_sub(route_segs, maybe_sub_segs)
}

fn do_is_sub(main, sub) {
  case main, sub {
    [], [] -> True
    [], _ -> False
    _, [] -> False
    [a, ..aa], [b, ..bb] -> {
      case a == b {
        True -> do_is_sub(aa, bb)
        False -> False
      }
    }
  }
}
