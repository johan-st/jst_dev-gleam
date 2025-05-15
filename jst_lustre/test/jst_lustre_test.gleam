// In test/yourapp_test.gleam
import article/article.{
  ArticleFull, ArticleSummary, ArticleWithError, Heading, Paragraph,
}
import gleam/dynamic
import gleam/dynamic/decode
import gleeunit
import gleeunit/should
import utils/persist.{PersistentModelV0, PersistentModelV1}

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> should.equal(1)
}

pub fn article_encoder_and_decoder_test() {
  let a_full =
    ArticleFull(
      slug: "test",
      revision: 1,
      leading: "leading",
      title: "test",
      subtitle: "subtitle",
      content: [Heading("test"), Paragraph("test")],
    )
  let a_sum =
    ArticleSummary(
      slug: "test2",
      revision: 1,
      leading: "leading",
      title: "test2",
      subtitle: "subtitle",
    )
  let a_err =
    ArticleWithError(
      slug: "test3",
      revision: 1,
      leading: "leading",
      title: "test3",
      subtitle: "subtitle",
      error: "error",
    )

  let enc_full = article.article_encoder(a_full)
  let enc_sum = article.article_encoder(a_sum)
  let enc_err = article.article_encoder(a_err)

  let decoded_full =
    decode.run(dynamic.from(enc_full), article.article_decoder())
  let decoded_sum = decode.run(dynamic.from(enc_sum), article.article_decoder())
  let decoded_err = decode.run(dynamic.from(enc_err), article.article_decoder())

  let ok_full = should.be_ok(decoded_full)
  let ok_sum = should.be_ok(decoded_sum)
  let ok_err = should.be_ok(decoded_err)

  ok_full
  |> should.equal(a_full)
  ok_sum
  |> should.equal(a_sum)
  ok_err
  |> should.equal(a_err)
}

pub fn model_encoder_and_decoder_test() {
  let model_v0 = PersistentModelV0(version: 0)
  let model_v1 =
    PersistentModelV1(version: 1, articles: [
      ArticleFull(
        slug: "test",
        revision: 1,
        leading: "leading",
        title: "test",
        subtitle: "subtitle",
        content: [Heading("test"), Paragraph("test")],
      ),
      ArticleSummary(
        slug: "test2",
        revision: 1,
        leading: "leading",
        title: "test2",
        subtitle: "subtitle",
      ),
      ArticleWithError(
        slug: "test3",
        revision: 1,
        leading: "leading",
        title: "test3",
        subtitle: "subtitle",
        error: "error",
      ),
    ])

  let encoded_v0 = persist.encode(model_v0)
  let encoded_v1 = persist.encode(model_v1)

  let decoded_v0 =
    decode.run(
      dynamic.from(persist.string_to_dynamic(encoded_v0)),
      persist.decoder(),
    )
  let decoded_v1 =
    decode.run(
      dynamic.from(persist.string_to_dynamic(encoded_v1)),
      persist.decoder(),
    )

  let dec_v0 = should.be_ok(decoded_v0)
  let dec_v1 = should.be_ok(decoded_v1)

  dec_v0
  |> should.equal(model_v0)
  dec_v1
  |> should.equal(model_v1)
}
