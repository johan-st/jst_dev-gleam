import article/article.{
  type Article, ArticleV1, article_decoder, article_encoder,
}
import article/content.{
  type Content, Block, Heading, Image, Link, LinkExternal, List, Paragraph, Text,
  Unknown,
}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import gleeunit/should
import qcheck as qc
import qcheck/random.{type Seed, random_seed, seed}
import utils/http
import utils/remote_data.{
  type RemoteData, Errored, Loaded, NotInitialized, Pending,
}

pub fn fuzz_article_test() {
  use article <- qc.run(
    qc.default_config() |> qc.with_test_count(15),
    generator_article(),
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

fn generator_article() -> qc.Generator(Article) {
  map8(
    qc.non_empty_string(),
    qc.non_empty_string(),
    qc.small_strictly_positive_int(),
    qc.non_empty_string(),
    qc.non_empty_string(),
    qc.non_empty_string(),
    generator_content() |> generator_remote_data(),
    qc.constant(None),
    ArticleV1,
  )
}

// content

fn generator_content_text() -> qc.Generator(Content) {
  use text <- qc.map(qc.non_empty_string())
  Text(text)
}

fn generator_content_block() -> qc.Generator(Content) {
  generator_content()
  |> qc.map(Block)
}

fn generator_content_heading() -> qc.Generator(Content) {
  qc.string() |> qc.map(Heading)
}

fn generator_content_paragraph() -> qc.Generator(Content) {
  qc.list_from(generator_content_text())
  |> qc.map(Paragraph)
}

fn generator_content_link() -> qc.Generator(Content) {
  use uri, text <- qc.map2(generator_uri(), qc.non_empty_string())
  Link(uri, text)
}

fn generator_content_link_external() -> qc.Generator(Content) {
  use uri, text <- qc.map2(generator_uri(), qc.non_empty_string())
  LinkExternal(uri, text)
}

fn generator_content_image() -> qc.Generator(Content) {
  use uri, text <- qc.map2(generator_uri(), qc.non_empty_string())
  Image(uri, text)
}

fn generator_content_list() -> qc.Generator(Content) {
  generator_content()
  |> qc.map(content.List)
}

fn generator_content_unknown() -> qc.Generator(Content) {
  use text <- qc.map(qc.string())
  Unknown(text)
}

fn generator_content() -> qc.Generator(List(Content)) {
  qc.generic_list(
    elements_from: qc.from_generators(generator_content_text(), [
      //   generator_content_block(),
      generator_content_heading(),
      generator_content_image(),
      generator_content_link(),
      generator_content_link_external(),
      //   generator_content_list(),
      generator_content_text(),
      generator_content_paragraph(),
      generator_content_unknown(),
    ]),
    length_from: qc.small_strictly_positive_int(),
  )
}

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

fn generator_uri() -> qc.Generator(uri.Uri) {
  use scheme, host, path <- qc.map3(
    qc.from_generators(qc.constant("http") |> qc.option_from(), [
      qc.constant("https") |> qc.option_from(),
    ]),
    generator_uri_host(),
    generator_uri_path(),
  )
  uri.Uri(scheme, None, Some(host), None, path, None, None)
}

fn generator_uri_host() -> qc.Generator(String) {
  use domain, tld <- qc.map2(
    qc.non_empty_string_from(qc.alphanumeric_ascii_codepoint()),
    qc.from_generators(qc.constant("com"), [
      qc.fixed_length_string_from(qc.alphanumeric_ascii_codepoint(), 2),
      qc.fixed_length_string_from(qc.alphanumeric_ascii_codepoint(), 3),
    ]),
  )
  domain <> "." <> tld
}

fn generator_uri_path() -> qc.Generator(String) {
  qc.list_from(qc.string_from(qc.alphanumeric_ascii_codepoint()))
  |> qc.map(string.join(_, "/"))
  |> qc.map(fn(path) { "/" <> path })
}

pub fn map8(
  g1: qc.Generator(a),
  g2: qc.Generator(b),
  g3: qc.Generator(c),
  g4: qc.Generator(d),
  g5: qc.Generator(e),
  g6: qc.Generator(f),
  g7: qc.Generator(g),
  g8: qc.Generator(h),
  func: fn(a, b, c, d, e, f, g, h) -> i,
) -> qc.Generator(i) {
  qc.map2(
    qc.tuple4(g1, g2, g3, g4),
    qc.tuple4(g5, g6, g7, g8),
    fn(tuple1, tuple2) {
      let #(a, b, c, d) = tuple1
      let #(e, f, g, h) = tuple2
      func(a, b, c, d, e, f, g, h)
    },
  )
}
