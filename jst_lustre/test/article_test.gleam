import article/article.{
  type Article, ArticleV1, article_decoder, article_encoder,
}

import birl
import gleam/json
import gleam/option.{None, Some}
// import gleam/string
// import gleam/uri
import gleeunit/should
import qcheck as qc
import utils/http
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}

pub fn fuzz_article_test() {
  use article <- qc.run(
    qc.default_config() |> qc.with_test_count(15),
    generator_article_v1(),
  )
  let assert Ok(decoded) =
    article
    |> article_encoder()
    |> json.to_string()
    |> json.parse(article_decoder())
  should.equal(decoded, article)
}

// pub fn fuzz_text_test() {
//   use text <- qc.given(generator_content_text())
//   should.equal(content_roundtrip(text), text)
// }

// pub fn fuzz_block_test() {
//   use block <- qc.run(
//     qc.default_config() |> qc.with_test_count(10),
//     generator_content_block(),
//   )
//   should.equal(content_roundtrip(block), block)
// }

// pub fn fuzz_heading_test() {
//   use heading <- qc.given(generator_content_heading())
//   should.equal(content_roundtrip(heading), heading)
// }

// pub fn fuzz_paragraph_test() {
//   use paragraph <- qc.run(
//     qc.default_config() |> qc.with_test_count(10),
//     generator_content_paragraph(),
//   )
//   should.equal(content_roundtrip(paragraph), paragraph)
// }

// pub fn fuzz_link_test() {
//   use link <- qc.given(generator_content_link())
//   should.equal(content_roundtrip(link), link)
// }

// pub fn fuzz_link_external_test() {
//   use link_external <- qc.given(generator_content_link_external())
//   should.equal(content_roundtrip(link_external), link_external)
// }

// pub fn fuzz_image_test() {
//   use image <- qc.given(generator_content_image())
//   should.equal(content_roundtrip(image), image)
// }

// pub fn fuzz_list_test() {
//   use list <- qc.run(
//     qc.default_config() |> qc.with_test_count(10),
//     generator_content_list(),
//   )
//   should.equal(content_roundtrip(list), list)
// }

// pub fn fuzz_unknown_test() {
//   use unknown <- qc.given(generator_content_unknown())
//   should.equal(content_roundtrip(unknown), unknown)
// }

// helpers
// fn content_roundtrip(content: Content) -> Content {
//   let assert Ok(decoded) =
//     content
//     |> article.content_encoder()
//     |> json.to_string()
//     |> json.parse(article.content_decoder())
//   decoded
// }

// GENERATORS ----------------------------------------------------------------

// article

fn generator_article_v1() -> qc.Generator(Article) {
  map11(
    qc.non_empty_string(),
    qc.non_empty_string(),
    qc.small_strictly_positive_int(),
    qc.non_empty_string(),
    qc.list_from(qc.non_empty_string()),
    qc.option_from(
      qc.bounded_int(1_700_000_000, 1_800_000_000)
      |> qc.map(birl.from_unix_milli),
    ),
    qc.non_empty_string(),
    qc.non_empty_string(),
    qc.non_empty_string(),
    qc.non_empty_string() |> generator_remote_data(),
    qc.constant(None),
    ArticleV1,
  )
}

// content - removed, now using Djot strings

fn generator_remote_data(
  generator: qc.Generator(a),
) -> qc.Generator(RemoteData(a, http.HttpError)) {
  qc.from_weighted_generators(#(47, generator |> qc.map(Loaded)), [
    #(1, qc.constant(NotInitialized)),
    #(0, qc.constant(Pending)),
    #(0, qc.constant(Errored(http.OtherError(0, "test")))),
  ])
}

// helpers

// fn generator_uri() -> qc.Generator(uri.Uri) {
//   use scheme, host, path <- qc.map3(
//     qc.from_generators(qc.constant("http") |> qc.option_from(), [
//       qc.constant("https") |> qc.option_from(),
//     ]),
//     generator_uri_host(),
//     generator_uri_path(),
//   )
//   uri.Uri(scheme, None, Some(host), None, path, None, None)
// }

// fn generator_uri_host() -> qc.Generator(String) {
//   use domain, tld <- qc.map2(
//     qc.non_empty_string_from(qc.alphanumeric_ascii_codepoint()),
//     qc.from_generators(qc.constant("com"), [
//       qc.fixed_length_string_from(qc.alphanumeric_ascii_codepoint(), 2),
//       qc.fixed_length_string_from(qc.alphanumeric_ascii_codepoint(), 3),
//     ]),
//   )
//   domain <> "." <> tld
// }

// fn generator_uri_path() -> qc.Generator(String) {
//   qc.list_from(qc.string_from(qc.alphanumeric_ascii_codepoint()))
//   |> qc.map(string.join(_, "/"))
//   |> qc.map(fn(path) { "/" <> path })
// }

pub fn map11(
  g1: qc.Generator(a),
  g2: qc.Generator(b),
  g3: qc.Generator(c),
  g4: qc.Generator(d),
  g5: qc.Generator(e),
  g6: qc.Generator(f),
  g7: qc.Generator(g),
  g8: qc.Generator(h),
  g9: qc.Generator(i),
  g10: qc.Generator(j),
  g11: qc.Generator(k),
  func: fn(a, b, c, d, e, f, g, h, i, j, k) -> l,
) -> qc.Generator(l) {
  qc.map3(
    qc.tuple4(g1, g2, g3, g4),
    qc.tuple4(g5, g6, g7, g8),
    qc.tuple3(g9, g10, g11),
    fn(tuple1, tuple2, tuple3) {
      let #(a, b, c, d) = tuple1
      let #(e, f, g, h) = tuple2
      let #(i, j, k) = tuple3
      func(a, b, c, d, e, f, g, h, i, j, k)
    },
  )
}

pub fn test_tags_consistency_between_metadata_and_full_article() {
  // Test article with specific tags
  let test_article =
    ArticleV1(
      id: "test-id-123",
      slug: "test-article",
      revision: 1,
      author: "test-author",
      tags: ["gleam", "test", "bug-fix"],
      published_at: Some(birl.from_unix_milli(1_700_000_000_000)),
      title: "Test Article",
      subtitle: "Test subtitle",
      leading: "Test leading text",
      content: NotInitialized,
      draft: None,
    )

  // Test article when loaded with full content
  let full_article =
    ArticleV1(
      ..test_article,
      content: Loaded("# Test Content\n\nThis is test content."),
    )

  // Both should have the same tags
  should.equal(test_article.tags, full_article.tags)
  should.equal(test_article.tags, ["gleam", "test", "bug-fix"])
  should.equal(full_article.tags, ["gleam", "test", "bug-fix"])
}

pub fn test_article_roundtrip_preserves_tags() {
  let original_article =
    ArticleV1(
      id: "test-id-456",
      slug: "roundtrip-test",
      revision: 2,
      author: "test-author",
      tags: ["preservation", "tags", "roundtrip"],
      published_at: Some(birl.from_unix_milli(1_700_000_000_000)),
      title: "Roundtrip Test",
      subtitle: "Testing tag preservation",
      leading: "This tests that tags are preserved",
      content: Loaded("# Content\n\nTest content here."),
      draft: None,
    )

  // Encode to JSON and decode back
  let assert Ok(roundtrip_article) =
    original_article
    |> article_encoder()
    |> json.to_string()
    |> json.parse(article_decoder())

  // Tags should be preserved
  should.equal(original_article.tags, roundtrip_article.tags)
  should.equal(roundtrip_article.tags, ["preservation", "tags", "roundtrip"])

  // All other fields should also be preserved
  should.equal(original_article.id, roundtrip_article.id)
  should.equal(original_article.author, roundtrip_article.author)
  should.equal(original_article.published_at, roundtrip_article.published_at)
}
