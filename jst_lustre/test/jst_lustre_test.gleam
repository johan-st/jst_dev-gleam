// In test/yourapp_test.gleam
import article.{ArticleV1}

import birl
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

pub fn model_encoder_and_decoder_test() {
  let model_v0 = PersistentModelV0
  let model_v1 =
    PersistentModelV1(articles: [
      ArticleV1(
        id: "1",
        slug: "test",
        revision: 1,
        leading: "leading",
        title: "test",
        subtitle: "subtitle",
        content: Loaded("# test\n\ntest", birl.from_unix(0), birl.from_unix(0)),
        author: "author",
        published_at: None,
        tags: [],
        draft: None,
      ),
      ArticleV1(
        id: "2",
        slug: "test2",
        revision: 1,
        leading: "leading",
        title: "test2",
        subtitle: "subtitle",
        content: Errored(NotFound, birl.from_unix(0)),
        author: "author",
        published_at: None,
        tags: [],
        draft: None,
      ),
      ArticleV1(
        id: "3",
        slug: "test3",
        revision: 1,
        leading: "leading",
        title: "test3",
        subtitle: "subtitle",
        content: Pending(None, birl.from_unix(0)),
        author: "author",
        published_at: None,
        tags: [],
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
        author: "author",
        published_at: None,
        tags: [],
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
    PersistentModelV0 -> should.fail()
    PersistentModelV1(articles) -> {
      case articles {
        [a1, a2, a3, a4] -> {
          // Article 1 - Loaded content
          case a1 {
            ArticleV1(
              id:,
              slug:,
              revision:,
              author:,
              published_at:,
              tags:,
              title:,
              leading:,
              subtitle:,
              content:,
              draft:,
            ) -> {
              id |> should.equal("1")
              slug |> should.equal("test")
              revision |> should.equal(1)
              author |> should.equal("author")
              published_at |> should.equal(None)
              tags |> should.equal([])
              title |> should.equal("test")
              leading |> should.equal("leading")
              subtitle |> should.equal("subtitle")
              draft |> should.equal(None)
              case content {
                Loaded(loaded_content, _, _) -> {
                  loaded_content
                  |> should.equal("# test\n\ntest")
                }
                _ -> should.fail()
              }
            }
          }

          // Article 2 - Errored content
          case a2 {
            ArticleV1(
              author:,
              content:,
              draft:,
              id:,
              tags:,
              title:,
              published_at:,
              leading:,
              revision:,
              slug:,
              subtitle:,
            ) -> {
              id |> should.equal("2")
              slug |> should.equal("test2")
              revision |> should.equal(1)
              author |> should.equal("author")
              published_at |> should.equal(None)
              tags |> should.equal([])
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
              author:,
              content:,
              draft:,
              id:,
              tags:,
              title:,
              published_at:,
              leading:,
              revision:,
              slug:,
              subtitle:,
            ) -> {
              id |> should.equal("3")
              slug |> should.equal("test3")
              revision |> should.equal(1)
              author |> should.equal("author")
              published_at |> should.equal(None)
              tags |> should.equal([])
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
              author:,
              content:,
              draft:,
              id:,
              tags:,
              title:,
              published_at:,
              leading:,
              revision:,
              slug:,
              subtitle:,
            ) -> {
              id |> should.equal("4")
              slug |> should.equal("test4")
              revision |> should.equal(1)
              author |> should.equal("author")
              published_at |> should.equal(None)
              tags |> should.equal([])
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
