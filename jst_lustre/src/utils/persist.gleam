import article/article.{type Article}
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder, type Dynamic}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/effect.{type Effect}

const model_localstorage_key = "jst_lustre_state"

pub type PersistentModel {
  PersistentModelV0(version: Int)
  PersistentModelV1(version: Int, articles: List(Article))
}

pub fn localstorage_set_model(model: PersistentModel) {
  echo "localstorage_set_model"
  localstorage_set(model_localstorage_key, encoder(model))
}

pub fn localstorage_get_model(
  msg: fn(Option(PersistentModel)) -> b,
) -> Effect(b) {
  localstorage_get(model_localstorage_key, decoder(), msg)
}

pub fn encoder(model: PersistentModel) -> String {
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
  let v0_decoder = {
    use version <- decode.field("version", decode.int)
    case version {
      0 -> decode.success(PersistentModelV0(version: 0))
      _ ->
        decode.failure(
          PersistentModelV0(version: 0),
          "Unsupported model version",
        )
    }
  }
  let v1_decoder = {
    use articles <- decode.field(
      "articles",
      decode.list(article.article_decoder()),
    )
    decode.success(PersistentModelV1(version: 1, articles: articles))
  }

  use version <- decode.field("version", decode.int)
  case version {
    0 -> v0_decoder
    1 -> v1_decoder
    _ ->
      decode.failure(PersistentModelV0(version: 0), "Unsupported model version")
  }
}

fn localstorage_get(key: String, decoder: Decoder(a), msg: fn(Option(a)) -> b) {
  echo "localstorage_get"
  use dispatch <- effect.from()
  let result = localstorage_get_external(key)
  case result {
    Ok(value) -> {
      echo value
      let result = decode.run(value, decoder)
      case result {
        Ok(value) -> dispatch(msg(Some(value)))
        Error(_) -> dispatch(msg(None))
      }
    }
    Error(_) -> dispatch(msg(None))
  }
}

@external(javascript, "../app.ffi.mjs", "localstorage_set")
fn localstorage_set(key: String, value: String) -> Nil

@external(javascript, "../app.ffi.mjs", "localstorage_get")
fn localstorage_get_external(key: String) -> Result(Dynamic, Nil)
