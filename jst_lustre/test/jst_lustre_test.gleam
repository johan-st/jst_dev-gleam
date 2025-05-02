// In test/yourapp_test.gleam
import article/article.{
  ArticleFull, ArticleSummary, ArticleWithError, Heading, Paragraph,
}
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode.{type Decoder, run}
import gleeunit
import gleeunit/should
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> should.equal(1)
}

pub fn test_model_endoder_and_decoder() {
  let model_v1 =
    PersistentModelV1(version: 1, articles: [
      ArticleFull(
        id: 1,
        revision: 1,
        leading: "leading",
        title: "test",
        subtitle: "subtitle",
        content: [Heading("test"), Paragraph("test")],
      ),
      ArticleSummary(
        id: 2,
        revision: 1,
        leading: "leading",
        title: "test2",
        subtitle: "subtitle",
      ),
      ArticleWithError(
        id: 3,
        revision: 1,
        leading: "leading",
        title: "test3",
        subtitle: "subtitle",
        error: "error",
      ),
    ])
  let model_v0 = PersistentModelV0(version: 0)
  let encoded_v1 = persist.encoder(model_v1)
  let decoded_v1 = decode.run(dynamic.from(encoded_v1), persist.decoder())
  should.be_ok(decoded_v1)
  case decoded_v1 {
    Ok(model) -> {
      model
      |> should.equal(model_v1)
    }
    Error(_) -> {
      Nil
    }
  }
}
