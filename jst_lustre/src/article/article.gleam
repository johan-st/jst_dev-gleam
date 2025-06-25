import article/draft.{type Draft}
import gleam/dynamic/decode
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData, Loaded, NotInitialized}
import utils/session.{type Session}

pub type Article {
  ArticleV1(
    id: String,
    slug: String,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    content: RemoteData(String, HttpError),
    draft: Option(Draft),
  )
}

pub fn content(article) {
  case article {
    ArticleV1(
      id: _,
      slug: _,
      revision: _,
      title: _,
      leading: _,
      subtitle: _,
      content:,
      draft: _,
    ) -> content
  }
}

pub fn get_draft(article) -> Option(Draft) {
  case article {
    ArticleV1(
      id: _,
      slug: _,
      revision: _,
      title: _,
      leading: _,
      subtitle: _,
      content: _,
      draft:,
    ) -> draft
  }
}

pub fn to_draft(article: Article) -> Option(Draft) {
  case article {
    ArticleV1(
      id: _,
      slug:,
      revision: _,
      title:,
      leading:,
      subtitle:,
      content: remote_data.Loaded(content_loaded),
      draft: _,
    ) -> draft.new(slug, title, subtitle, leading, content_loaded) |> Some
    _ -> None
  }
}

pub fn can_edit(_article: Article, session: Session) {
  session
  |> session.permission_any(["post_edit_any"])
}

pub fn can_delete(_article: Article, session: Session) {
  session
  |> session.permission_any(["post_edit_any"])
}

pub fn can_publish(_article: Article, session: Session) {
  session
  |> session.permission_any(["post_edit_any"])
}

// HTTP -------------------------------------------------------------------------

pub fn article_get(msg, id: String, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> id)
    |> request.set_port(port)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_metadata_get(msg, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles")
    |> request.set_port(port)
  http.send(request, http.expect_json(metadata_decoder(), msg))
}

pub fn article_update(msg, article: Article, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Put)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> article.id)
    |> request.set_port(port)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_create(msg, article: Article, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles")
    |> request.set_port(port)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_update_(msg, article: Article, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Put)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> article.id)
    |> request.set_port(port)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_delete(msg, id: String, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Delete)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> id)
    |> request.set_port(port)
  http.send(request, http.expect_text(msg))
}

pub fn article_publish(msg, id: String, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> id <> "/publish")
    |> request.set_port(port)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_unpublish(msg, id: String, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path("/api/articles/" <> id <> "/unpublish")
    |> request.set_port(port)
  http.send(request, http.expect_json(article_decoder(), msg))
}

// DECODE ----------------------------------------------------------------------

fn metadata_decoder() -> decode.Decoder(List(Article)) {
  use articles <- decode.field("articles", decode.list(article_decoder()))
  decode.success(articles)
}

pub fn article_decoder() -> decode.Decoder(Article) {
  use _version <- decode.optional_field("version", 0, decode.int)
  use id <- decode.field("id", decode.string)
  use slug <- decode.field("slug", decode.string)
  use revision <- decode.field("revision", decode.int)
  use title <- decode.field("title", decode.string)
  use leading <- decode.field("leading", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)
  use content_string <- decode.optional_field("content", "", decode.string)

  let content = case content_string {
    "" -> NotInitialized
    _ -> Loaded(content_string)
  }

  decode.success(ArticleV1(
    id: id,
    slug: slug,
    revision: revision,
    title: title,
    leading: leading,
    subtitle: subtitle,
    content: content,
    draft: None,
  ))
}

// ENCODE ----------------------------------------------------------------------

pub fn article_encoder(article: Article) -> json.Json {
  case article {
    ArticleV1(
      id,
      slug,
      revision,
      title,
      leading,
      subtitle,
      remote_data_content,
      _draft,
    ) -> {
      let content = case remote_data_content {
        Loaded(content) -> json.string(content)
        _ -> json.string("")
      }
      json.object([
        #("version", json.int(1)),
        #("id", json.string(id)),
        #("revision", json.int(revision)),
        #("slug", json.string(slug)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("content", content),
        // #("draft", draft |> draft_encoder),
      ])
    }
  }
}

// Draft ------------------------------------------------------------------------

pub fn draft_update(article: Article, updater: fn(Draft) -> Draft) -> Article {
  case article {
    ArticleV1(_, _, _, _, _, _, _, Some(draft)) -> {
      ArticleV1(..article, draft: Some(updater(draft)))
    }
    ArticleV1(_, _, _, _, _, _, _, None) -> {
      echo "draft_update: not an article with draft"
      article
    }
  }
}

// Utils -----------------------------------------------------------------------

// pub fn list_to_dict(articles: List(Article)) -> Dict(ArticleId, Article) {
//   articles
//   |> list.map(fn(article) { #(article.id, article) })
//   |> dict.from_list
// }

// Loading ---------------------------------------------------------------------

pub fn loading_article() -> Article {
  ArticleV1(
    id: "-",
    slug: "placeholder_loading",
    revision: 0,
    title: "fetching articles..",
    subtitle: "articles have not been fetched yet",
    leading: "This is a placeholder article. At the moment, the articles are being fetched from the server.. please wait.",
    content: NotInitialized,
    draft: None,
  )
}
