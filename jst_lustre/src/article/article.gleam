import article/content.{
  type Content, Block, Heading, Image, Link, LinkExternal, List, Paragraph, Text,
  Unknown,
}
import article/draft.{type Draft}
import gleam/dynamic/decode
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/uri
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
    content: RemoteData(List(Content), HttpError),
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

pub fn to_draft(article: Article) -> Draft {
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
    ) -> draft.new(slug, title, subtitle, leading, content_loaded)
    _ -> todo as "trying to create a draft from article with no loaded content"
  }
}

pub fn can_edit(_article: Article, session: Session) {
  session
  |> session.permission_any(["post_edit_any"])
}

// Fetch ------------------------------------------------------------------------

pub fn article_get(msg, id: String) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/article/" <> id <> "/")
    |> request.set_port(8080)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_metadata_get(msg) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/article/")
    |> request.set_port(8080)
  http.send(request, http.expect_json(metadata_decoder(), msg))
}

pub fn article_update(msg, article: Article) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Put)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/article/" <> article.id <> "/")
    |> request.set_port(8080)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_create(msg, article: Article) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/article/")
    |> request.set_port(8080)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

// DECODE ----------------------------------------------------------------------

fn content_decoder() -> decode.Decoder(Content) {
  use content_type <- decode.field("type", decode.string)
  case content_type {
    "heading" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Heading(text))
    }
    "paragraph" -> {
      use contents <- decode.field("content", decode.list(content_decoder()))
      decode.success(Paragraph(contents))
    }
    "block" -> {
      use contents <- decode.field("content", decode.list(content_decoder()))
      decode.success(Block(contents))
    }
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Text(text))
    }
    "link" -> {
      let assert Ok(fail_uri) = uri.parse("/")
      use url <- decode.field("url", decode.string)
      use text <- decode.field("text", decode.string)
      case url, text {
        "", _ -> {
          decode.failure(Link(fail_uri, text), "empty link")
        }
        _, "" -> {
          decode.failure(Link(fail_uri, text), "empty link text")
        }
        _, _ -> {
          case uri.parse(url) {
            Ok(u) -> {
              decode.success(Link(u, text))
            }
            Error(e) -> {
              echo e
              decode.failure(Link(fail_uri, text), "invalid link")
            }
          }
        }
      }
    }
    "link_external" -> {
      let assert Ok(fail_uri) = uri.parse("/")
      use url <- decode.field("url", decode.string)
      use text <- decode.field("text", decode.string)
      case url, text {
        "", _ -> {
          decode.failure(LinkExternal(fail_uri, text), "empty link")
        }
        _, "" -> {
          decode.failure(LinkExternal(fail_uri, text), "empty link text")
        }
        _, _ -> {
          case uri.parse(url) {
            Ok(u) -> {
              decode.success(LinkExternal(u, text))
            }
            Error(e) -> {
              echo e
              decode.failure(LinkExternal(fail_uri, text), "invalid link")
            }
          }
        }
      }
    }
    "list" -> {
      use contents <- decode.field("content", decode.list(content_decoder()))
      decode.success(List(contents))
    }
    _ -> {
      decode.success(Unknown(content_type))
    }
  }
}

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
  use content_list <- decode.optional_field(
    "content",
    [],
    decode.list(content_decoder()),
  )

  let content = case content_list {
    [] -> NotInitialized
    _ -> Loaded(content_list)
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
        Loaded(content) -> json.array(content, of: content_encoder)
        _ -> json.array([], of: content_encoder)
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

pub fn content_encoder(content: Content) -> json.Json {
  case content {
    Block(contents) -> {
      json.object([
        #("type", json.string("block")),
        #("content", json.array(contents, of: content_encoder)),
      ])
    }
    Heading(text) -> {
      json.object([
        #("type", json.string("heading")),
        #("text", json.string(text)),
      ])
    }
    Paragraph(contents) -> {
      json.object([
        #("type", json.string("paragraph")),
        #("content", json.array(contents, of: content_encoder)),
      ])
    }
    Text(text) -> {
      json.object([#("type", json.string("text")), #("text", json.string(text))])
    }
    Link(url, title) -> {
      json.object([
        #("type", json.string("link")),
        #("url", json.string(uri.to_string(url))),
        #("title", json.string(title)),
      ])
    }
    LinkExternal(url, title) -> {
      json.object([
        #("type", json.string("link_external")),
        #("url", json.string(uri.to_string(url))),
        #("title", json.string(title)),
      ])
    }
    Image(url, alt) -> {
      json.object([
        #("type", json.string("image")),
        #("url", json.string(uri.to_string(url))),
        #("alt", json.string(alt)),
      ])
    }
    List(contents) -> {
      json.object([
        #("type", json.string("list")),
        #("content", json.array(contents, of: content_encoder)),
      ])
    }
    Unknown(text) -> {
      json.object([
        #("type", json.string("unknown")),
        #("text", json.string(text)),
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
