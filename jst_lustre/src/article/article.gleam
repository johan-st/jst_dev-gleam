import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import utils/http

pub type Article {
  Article(
    id: Int,
    title: String,
    leading: String,
    subtitle: String,
    content: Option(List(Content)),
  )
}

pub type Content {
  Block(List(Content))
  Heading(String)
  Subtitle(String)
  Paragraph(String)
  Unknown(String)
}

// VIEW ------------------------------------------------------------------------

pub fn view_article_content(
  view_subtitle: fn(String) -> Element(msg),
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
        Subtitle(text) -> view_subtitle(text)
        Heading(text) -> view_heading(text)
        // Leading(text) -> view_leading(text)
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
  let url =
    "http://127.0.0.1:1234/priv/static/article_" <> int.to_string(id) <> ".json"
  http.get(url, http.expect_json(article_decoder(), msg))
}

pub fn get_metadata_all(msg) -> Effect(a) {
  let url = "http://127.0.0.1:1234/priv/static/articles.json"
  http.get(url, http.expect_json(decode.list(article_decoder()), msg))
}

fn content_decoder() -> decode.Decoder(Content) {
  use content_type <- decode.field("type", decode.string)
  case content_type {
    "subtitle" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Subtitle(text))
    }
    "heading" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Heading(text))
    }
    // "leading" -> {
    //   use text <- decode.field("text", decode.string)
    //   decode.success(Leading(text))
    // }
    "paragraph" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Paragraph(text))
    }
    _ -> {
      decode.success(Unknown(content_type))
    }
    // _ -> {
    //   let msg = "failed to decode content with type: " <> content_type
    //   decode.failure(Paragraph(msg), msg)
    // }
  }
}

fn article_decoder() -> decode.Decoder(Article) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use leading <- decode.field("leading", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)
  // use content <- decode.field(
  //   "content",
  //   decode.optional(decode.list(content_decoder())),
  // )
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.list(content_decoder())),
  )
  echo content
  let content = case content {
    Some([]) -> None
    _ -> content
  }
  echo content
  decode.success(Article(id:, title:, leading:, subtitle:, content:))
}
