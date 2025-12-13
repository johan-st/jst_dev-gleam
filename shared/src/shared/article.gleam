import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option, None, Some}

/// Canonical Article type shared between BEAM server and Lustre frontend.
/// Matches the JSON shape currently used by `jst_lustre/src/article.gleam`.
pub type Article {
  Article(
    id: String,
    slug: String,
    revision: Int,
    author: String,
    tags: List(String),
    published_at_ms: Option(Int),
    title: String,
    subtitle: String,
    leading: String,
    content: String,
  )
}

pub fn decoder() -> Decoder(Article) {
  use _version <- decode.optional_field("version", 0, decode.int)
  use id <- decode.field("id", decode.string)
  use author <- decode.field("author", decode.string)
  use tags <- decode.field(
    "tags",
    decode.one_of(decode.list(decode.string), [decode.success([])]),
  )

  use published_at_ms <- decode.field(
    "published_at",
    decode.int
      |> decode.map(fn(i) {
        case i {
          0 -> None
          _ -> Some(i)
        }
      }),
  )

  use slug <- decode.field("slug", decode.string)
  use revision <- decode.field("revision", decode.int)
  use title <- decode.field("title", decode.string)
  use leading <- decode.field("leading", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)
  use content <- decode.field("content", decode.string)

  decode.success(Article(
    id:,
    slug:,
    revision:,
    author:,
    tags:,
    published_at_ms: published_at_ms,
    title:,
    subtitle:,
    leading:,
    content:,
  ))
}

pub fn encoder(article: Article) -> json.Json {
  let published_at = case article.published_at_ms {
    Some(ms) -> json.int(ms)
    None -> json.int(0)
  }

  json.object([
    #("struct_version", json.int(1)),
    #("id", json.string(article.id)),
    #("revision", json.int(article.revision)),
    #("slug", json.string(article.slug)),
    #("title", json.string(article.title)),
    #("leading", json.string(article.leading)),
    #("subtitle", json.string(article.subtitle)),
    #("author", json.string(article.author)),
    #("published_at", published_at),
    #("tags", json.array(article.tags, json.string)),
    #("content", json.string(article.content)),
  ])
}
