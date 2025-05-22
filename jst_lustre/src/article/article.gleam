import article/content.{
  type Content, Block, Heading, Image, Link, LinkExternal, List, Paragraph, Text,
  Unknown,
}
import article/draft.{type Draft}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}

pub type Article {
  ArticleSummary(
    slug: String,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
  )
  ArticleFull(
    slug: String,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    content: List(Content),
  )
  ArticleWithError(
    slug: String,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    error: String,
  )
  ArticleFullWithDraft(
    slug: String,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    content: List(Content),
    draft: Draft,
  )
}

// Fetch ------------------------------------------------------------------------

pub fn article_get(msg, slug: String) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/api/article/" <> slug)
    |> request.set_port(8080)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_metadata_get(msg) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/api/article")
    |> request.set_port(8080)
  http.send(request, http.expect_json(metadata_decoder(), msg))
}

pub fn article_update(msg, article: Article) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Put)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/api/article/" <> article.slug)
    |> request.set_port(8080)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

pub fn article_create(msg, article: Article) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/api/article")
    |> request.set_port(8080)
    |> request.set_body(article_encoder(article) |> json.to_string)
  http.send(request, http.expect_json(article_decoder(), msg))
}

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
  use article_type <- decode.optional_field("type", "not_set", decode.string)
  use slug <- decode.field("slug", decode.string)
  use revision <- decode.field("revision", decode.int)
  use title <- decode.field("title", decode.string)
  use leading <- decode.field("leading", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)

  let decode_full = fn() -> decode.Decoder(Article) {
    use content <- decode.field("content", decode.list(content_decoder()))
    decode.success(ArticleFull(
      slug:,
      revision:,
      title:,
      leading:,
      subtitle:,
      content:,
    ))
  }

  let decode_error = fn() -> decode.Decoder(Article) {
    use error <- decode.field("error", decode.string)
    decode.success(ArticleWithError(
      slug:,
      revision:,
      title:,
      leading:,
      subtitle:,
      error:,
    ))
  }

  let decode_summary = fn() -> decode.Decoder(Article) {
    decode.success(ArticleSummary(slug:, revision:, title:, leading:, subtitle:))
  }

  decode.one_of(decode_full(), [decode_error(), decode_summary()])
}

// ENCODE ----------------------------------------------------------------------

pub fn article_encoder(article: Article) -> json.Json {
  case article {
    ArticleSummary(slug, revision, title, leading, subtitle) -> {
      json.object([
        #("type", json.string("metadata_v1")),
        #("revision", json.int(revision)),
        #("slug", json.string(slug)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
      ])
    }
    ArticleFull(slug, revision, title, leading, subtitle, content) -> {
      json.object([
        #("type", json.string("article_v1")),
        #("revision", json.int(revision)),
        #("slug", json.string(slug)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("content", json.array(content, of: content_encoder)),
      ])
    }
    ArticleWithError(slug, revision, title, leading, subtitle, error) -> {
      json.object([
        #("type", json.string("with_error_v1")),
        #("revision", json.int(revision)),
        #("slug", json.string(slug)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("error", json.string(error)),
      ])
    }
    ArticleFullWithDraft(
      slug,
      revision,
      title,
      leading,
      subtitle,
      content,
      _draft,
    ) -> {
      json.object([
        #("type", json.string("article_v1")),
        #("revision", json.int(revision)),
        #("slug", json.string(slug)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("content", json.array(content, of: content_encoder)),
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
    ArticleFullWithDraft(
      slug,
      revision,
      title,
      leading,
      subtitle,
      content,
      draft,
    ) -> {
      ArticleFullWithDraft(
        slug,
        revision,
        title,
        leading,
        subtitle,
        content,
        updater(draft),
      )
    }
    _ -> {
      echo "draft_update: not an article with draft"
      article
    }
  }
}

// Utils -----------------------------------------------------------------------

pub fn list_to_dict(articles: List(Article)) -> Dict(String, Article) {
  articles
  |> list.map(fn(article) { #(article.slug, article) })
  |> dict.from_list
}

// Loading ---------------------------------------------------------------------

pub fn loading_article() -> Article {
  ArticleWithError(
    revision: 0,
    slug: "placeholder",
    title: "fetching articles..",
    subtitle: "articles have not been fetched yet",
    leading: "This is a placeholder article. At the moment, the articles are being fetched from the server.. please wait.",
    error: "replace me with something that is not an article",
  )
}
