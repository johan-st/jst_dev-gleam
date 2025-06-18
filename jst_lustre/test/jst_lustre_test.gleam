// In test/yourapp_test.gleam
import article/article.{ArticleV1}
import article/content.{Heading, Paragraph, Text}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/option.{None}
import gleeunit
import gleeunit/should
import utils/http.{NotFound}
import utils/persist.{PersistentModelV0, PersistentModelV1}
import utils/remote_data.{Errored, Loaded, NotInitialized, Pending}

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> should.equal(1)
}

pub fn article_encoder_and_decoder_test() {
  let a_loaded =
    ArticleV1(
      id: "1",
      slug: "test",
      revision: 1,
      leading: "leading",
      title: "test",
      subtitle: "subtitle",
      content: Loaded([Heading("test"), Paragraph([Text("test")])]),
      draft: None,
    )
  let a_errored =
    ArticleV1(
      id: "2",
      slug: "test2",
      revision: 1,
      leading: "leading",
      title: "test2",
      subtitle: "subtitle",
      content: Errored(NotFound),
      draft: None,
    )
  let a_pending =
    ArticleV1(
      id: "3",
      slug: "test3",
      revision: 1,
      leading: "leading",
      title: "test3",
      subtitle: "subtitle",
      content: Pending,
      draft: None,
    )
  let a_not_initialized =
    ArticleV1(
      id: "4",
      slug: "test4",
      revision: 1,
      leading: "leading",
      title: "test4",
      subtitle: "subtitle",
      content: NotInitialized,
      draft: None,
    )

  let enc_loaded = article.article_encoder(a_loaded)
  let enc_errored = article.article_encoder(a_errored)
  let enc_pending = article.article_encoder(a_pending)
  let enc_not_initialized = article.article_encoder(a_not_initialized)

  let decoded_loaded =
    decode.run(dynamic.from(enc_loaded), article.article_decoder())
  let decoded_errored =
    decode.run(dynamic.from(enc_errored), article.article_decoder())
  let decoded_pending =
    decode.run(dynamic.from(enc_pending), article.article_decoder())
  let decoded_not_initialized =
    decode.run(dynamic.from(enc_not_initialized), article.article_decoder())

  let ok_loaded = should.be_ok(decoded_loaded)
  let ok_errored = should.be_ok(decoded_errored)
  let ok_pending = should.be_ok(decoded_pending)
  let ok_not_initialized = should.be_ok(decoded_not_initialized)

  // For loaded content
  case ok_loaded {
    ArticleV1(id, slug, revision, title, leading, subtitle, content, draft) -> {
      id |> should.equal(a_loaded.id)
      slug |> should.equal(a_loaded.slug)
      revision |> should.equal(a_loaded.revision)
      title |> should.equal(a_loaded.title)
      leading |> should.equal(a_loaded.leading)
      subtitle |> should.equal(a_loaded.subtitle)
      draft |> should.equal(a_loaded.draft)
      case content {
        Loaded(loaded_content) -> {
          loaded_content
          |> should.equal([Heading("test"), Paragraph([Text("test")])])
        }
        _ -> should.fail()
      }
    }
  }

  // For errored content
  case ok_errored {
    ArticleV1(id, slug, revision, title, leading, subtitle, content, draft) -> {
      id |> should.equal(a_errored.id)
      slug |> should.equal(a_errored.slug)
      revision |> should.equal(a_errored.revision)
      title |> should.equal(a_errored.title)
      leading |> should.equal(a_errored.leading)
      subtitle |> should.equal(a_errored.subtitle)
      draft |> should.equal(a_errored.draft)
      case content {
        NotInitialized -> should.equal(True, True)
        _ -> should.fail()
      }
    }
  }

  // For pending content
  case ok_pending {
    ArticleV1(id, slug, revision, title, leading, subtitle, content, draft) -> {
      id |> should.equal(a_pending.id)
      slug |> should.equal(a_pending.slug)
      revision |> should.equal(a_pending.revision)
      title |> should.equal(a_pending.title)
      leading |> should.equal(a_pending.leading)
      subtitle |> should.equal(a_pending.subtitle)
      draft |> should.equal(a_pending.draft)
      case content {
        NotInitialized -> should.equal(True, True)
        _ -> should.fail()
      }
    }
  }

  // For not initialized content
  case ok_not_initialized {
    ArticleV1(id, slug, revision, title, leading, subtitle, content, draft) -> {
      id |> should.equal(a_not_initialized.id)
      slug |> should.equal(a_not_initialized.slug)
      revision |> should.equal(a_not_initialized.revision)
      title |> should.equal(a_not_initialized.title)
      leading |> should.equal(a_not_initialized.leading)
      subtitle |> should.equal(a_not_initialized.subtitle)
      draft |> should.equal(a_not_initialized.draft)
      case content {
        NotInitialized -> should.equal(True, True)
        _ -> should.fail()
      }
    }
  }
}

pub fn model_encoder_and_decoder_test() {
  let model_v0 = PersistentModelV0(version: 0)
  let model_v1 =
    PersistentModelV1(version: 1, articles: [
      ArticleV1(
        id: "1",
        slug: "test",
        revision: 1,
        leading: "leading",
        title: "test",
        subtitle: "subtitle",
        content: Loaded([Heading("test"), Paragraph([Text("test")])]),
        draft: None,
      ),
      ArticleV1(
        id: "2",
        slug: "test2",
        revision: 1,
        leading: "leading",
        title: "test2",
        subtitle: "subtitle",
        content: Errored(NotFound),
        draft: None,
      ),
      ArticleV1(
        id: "3",
        slug: "test3",
        revision: 1,
        leading: "leading",
        title: "test3",
        subtitle: "subtitle",
        content: Pending,
        draft: None,
      ),
      ArticleV1(
        id: "4",
        slug: "test4",
        revision: 1,
        leading: "leading",
        title: "test4",
        subtitle: "subtitle",
        content: NotInitialized,
        draft: None,
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

  // Compare each article in the model separately to handle content states correctly
  case dec_v1 {
    PersistentModelV0(_) -> should.fail()
    PersistentModelV1(version, articles) -> {
      version |> should.equal(1)
      case articles {
        [a1, a2, a3, a4] -> {
          // Article 1 - Loaded content
          case a1 {
            ArticleV1(
              id,
              slug,
              revision,
              title,
              leading,
              subtitle,
              content,
              draft,
            ) -> {
              id |> should.equal("1")
              slug |> should.equal("test")
              revision |> should.equal(1)
              title |> should.equal("test")
              leading |> should.equal("leading")
              subtitle |> should.equal("subtitle")
              draft |> should.equal(None)
              case content {
                Loaded(loaded_content) -> {
                  loaded_content
                  |> should.equal([Heading("test"), Paragraph([Text("test")])])
                }
                _ -> should.fail()
              }
            }
          }

          // Article 2 - Errored content
          case a2 {
            ArticleV1(
              id,
              slug,
              revision,
              title,
              leading,
              subtitle,
              content,
              draft,
            ) -> {
              id |> should.equal("2")
              slug |> should.equal("test2")
              revision |> should.equal(1)
              title |> should.equal("test2")
              leading |> should.equal("leading")
              subtitle |> should.equal("subtitle")
              draft |> should.equal(None)
              content |> should.equal(NotInitialized)
            }
          }

          // Article 3 - Pending content
          case a3 {
            ArticleV1(
              id,
              slug,
              revision,
              title,
              leading,
              subtitle,
              content,
              draft,
            ) -> {
              id |> should.equal("3")
              slug |> should.equal("test3")
              revision |> should.equal(1)
              title |> should.equal("test3")
              leading |> should.equal("leading")
              subtitle |> should.equal("subtitle")
              draft |> should.equal(None)
              content |> should.equal(NotInitialized)
            }
          }

          // Article 4 - NotInitialized content
          case a4 {
            ArticleV1(
              id,
              slug,
              revision,
              title,
              leading,
              subtitle,
              content,
              draft,
            ) -> {
              id |> should.equal("4")
              slug |> should.equal("test4")
              revision |> should.equal(1)
              title |> should.equal("test4")
              leading |> should.equal("leading")
              subtitle |> should.equal("subtitle")
              draft |> should.equal(None)
              content |> should.equal(NotInitialized)
            }
          }
        }
        _ -> should.fail()
      }
    }
  }
}
