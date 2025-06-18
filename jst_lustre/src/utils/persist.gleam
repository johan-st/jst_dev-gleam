import article/article.{type Article}
import gleam/dynamic/decode.{type Decoder, type Dynamic}
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre/effect

pub const model_localstorage_key = "jst_lustre_state"

pub type PersistentModel {
  PersistentModelV0(version: Int)
  PersistentModelV1(version: Int, articles: List(Article))
}

pub fn encode(model: PersistentModel) -> String {
  let json_value = case model {
    PersistentModelV0(_version) -> {
      json.object([#("version", json.int(0))])
    }
    PersistentModelV1(_version, articles:) -> {
      json.object([
        #("version", json.int(1)),
        #("articles", json.array(articles, article.article_encoder)),
      ])
    }
  }
  json.to_string(json_value)
}

pub fn decoder() -> Decoder(PersistentModel) {
  use version <- decode.field("version", decode.int)
  case version {
    0 -> decode.success(PersistentModelV0(version: 0))
    1 -> {
      use articles <- decode.field(
        "articles",
        decode.list(article.article_decoder()),
      )
      decode.success(PersistentModelV1(version: 1, articles: articles))
    }
    _ ->
      decode.failure(PersistentModelV0(version: 0), "Unsupported model version")
  }
}

pub fn localstorage_get(
  key: String,
  decoder: Decoder(a),
  msg: fn(Option(a)) -> b,
) {
  use dispatch <- effect.from()
  case localstorage_get_external(key) {
    Ok(value) -> {
      case decode.run(string_to_dynamic(value), decoder) {
        Ok(value) -> dispatch(msg(Some(value)))
        Error(_) -> dispatch(msg(None))
      }
    }
    Error(_) -> dispatch(msg(None))
  }
}

@external(javascript, "../app.ffi.mjs", "localstorage_set")
pub fn localstorage_set(key: String, value: String) -> Nil

@external(javascript, "../app.ffi.mjs", "localstorage_get")
fn localstorage_get_external(key: String) -> Result(String, Nil)

@external(javascript, "../app.ffi.mjs", "string_to_dynamic")
pub fn string_to_dynamic(value: String) -> Dynamic
