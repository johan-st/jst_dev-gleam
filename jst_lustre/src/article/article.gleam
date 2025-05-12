import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import utils/http

pub type Article {
  ArticleSummary(
    id: Int,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
  )
  ArticleFull(
    id: Int,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    content: List(Content),
  )
  ArticleWithError(
    id: Int,
    revision: Int,
    title: String,
    leading: String,
    subtitle: String,
    error: String,
  )
}

// pub type Content {
//   Heading(List(Content))
//   Paragraph(List(Content))
//   Text(String)
//   Link(String)
//   Code(String)
//   Unknown(String)
// }

pub type Content {
  Block(List(Content))
  Heading(String)
  Paragraph(String)
  Unknown(String)
}


// VIEW ------------------------------------------------------------------------

pub fn view_article_content(
  view_h2: fn(String) -> Element(msg),
  view_h3: fn(String) -> Element(msg),
  view_h4: fn(String) -> Element(msg),
  view_paragraph: fn(String) -> Element(msg),
  view_unknown: fn(String) -> Element(msg),
  contents: List(Content),
) -> List(Element(msg)) {
  let view_block = fn(contents: List(Content), current_level: Int) -> List(
    Element(msg),
  ) {
    contents
    |> list.map(fn(content) {
      let view_heading = case current_level {
        0 -> view_h2
        1 -> view_h3
        2 -> view_h4
        _ -> view_h4
      }
      case content {
        Heading(text) -> view_heading(text)
        Paragraph(text) -> view_paragraph(text)
        Unknown(text) -> view_unknown(text)
        Block(_) -> view_unknown("Block")
      }
    })
  }
  view_block(contents, 0)
}

// Fetch ------------------------------------------------------------------------

pub fn get_article(msg, id: Int) -> Effect(a) {
  let url = "http://127.0.0.1:8080/api/article/" <> int.to_string(id)
  http.get(url, http.expect_json(article_decoder(), msg))
}

pub fn get_metadata_all(msg) -> Effect(a) {
  let url = "http://127.0.0.1:8080/api/articles"
  http.get(url, http.expect_json(metadata_decoder(), msg))
}

fn content_decoder() -> decode.Decoder(Content) {
  use content_type <- decode.field("type", decode.string)
  case content_type {
    "heading" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Heading(text))
    }
    "paragraph" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Paragraph(text))
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
  use id <- decode.field("id", decode.int)
  use revision <- decode.field("revision", decode.int)
  use title <- decode.field("title", decode.string)
  use leading <- decode.field("leading", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)

  let decode_full = fn() -> decode.Decoder(Article) {
    use content <- decode.field("content", decode.list(content_decoder()))
    decode.success(ArticleFull(
      id:,
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
      id:,
      revision:,
      title:,
      leading:,
      subtitle:,
      error:,
    ))
  }

  let decode_summary = fn() -> decode.Decoder(Article) {
    decode.success(ArticleSummary(id:, revision:, title:, leading:, subtitle:))
  }

  decode.one_of(decode_full(), [decode_error(), decode_summary()])
}

// ENCODE ----------------------------------------------------------------------

pub fn article_encoder(article: Article) -> json.Json {
  case article {
    ArticleSummary(id, revision, title, leading, subtitle) -> {
      json.object([
        #("type", json.string("metadata_v1")),
        #("revision", json.int(revision)),
        #("id", json.int(id)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
      ])
    }
    ArticleFull(id, revision, title, leading, subtitle, content) -> {
      json.object([
        #("type", json.string("article_v1")),
        #("revision", json.int(revision)),
        #("id", json.int(id)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("content", json.array(content, of: content_encoder)),
      ])
    }
    ArticleWithError(id, revision, title, leading, subtitle, error) -> {
      json.object([
        #("type", json.string("with_error_v1")),
        #("revision", json.int(revision)),
        #("id", json.int(id)),
        #("title", json.string(title)),
        #("leading", json.string(leading)),
        #("subtitle", json.string(subtitle)),
        #("error", json.string(error)),
      ])
    }
  }
}

pub fn content_encoder(content: Content) -> json.Json {
  case content {
    Block(contents) -> {
      json.object([
        #("type", json.string("block")),
        #("contents", json.array(contents, of: content_encoder)),
      ])
    }
    Heading(text) -> {
      json.object([
        #("type", json.string("heading")),
        #("text", json.string(text)),
      ])
    }
    Paragraph(text) -> {
      json.object([
        #("type", json.string("paragraph")),
        #("text", json.string(text)),
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

// Utils -----------------------------------------------------------------------

pub fn list_to_dict(articles: List(Article)) -> Dict(Int, Article) {
  articles
  |> list.map(fn(article) { #(article.id, article) })
  |> dict.from_list
}

// Loading ---------------------------------------------------------------------

pub fn loading_article() -> Article {
  ArticleWithError(
    revision: 0,
    id: 0,
    title: "fetching articles..",
    subtitle: "articles have not been fetched yet",
    leading: "This is a placeholder article. At the moment, the articles are being fetched from the server.. please wait.",
    error: "replace me with something that is not an article",
  )
}
