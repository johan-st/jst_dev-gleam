import article/article
import article/content.{
  type Content,
  Block,
  Heading,
  Image,
  Link,
  LinkExternal,
  List,
  Paragraph,
  Text,
}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/uri
import gleeunit/should
import utils/remote_data.{Loaded}

pub fn content_encode_decode_test() {
  let assert Ok(test_uri) = uri.parse("https://example.com")
  
  let test_cases = [
    // Simple content types
    Text("Hello, world!"),
    Heading("Test Heading"),
    
    // Nested content types
    Block([Text("Block text"), Heading("Block heading")]),
    Paragraph([Text("Paragraph text"), Text("More text")]),
    List([Text("List item 1"), Text("List item 2")]),
    
    // URI-based content types
    Link(test_uri, "Test Link"),
    LinkExternal(test_uri, "External Link"),
    Image(test_uri, "Image Alt Text"),
  ]

  // Test each case
  list.each(test_cases, fn(content) {
    // Create an article with this content
    let article = article.ArticleV1(
      id: "test",
      slug: "test",
      revision: 1,
      title: "test",
      leading: "test",
      subtitle: "test",
      content: Loaded([content]),
      draft: None,
    )
    
    // Encode to JSON
    let encoded = article.article_encoder(article)
    
    // Decode back from JSON
    let decoded = decode.run(
      dynamic.from(encoded),
      article.article_decoder(),
    )
    
    // Verify decoded content matches original
    case decoded |> should.be_ok {
      article.ArticleV1(id: _, slug: _, revision: _, title: _, leading: _, subtitle: _, content: Loaded(content_list), draft: _) -> {
        case content_list {
          [content_item] -> content_item |> should.equal(content)
          _ -> should.fail()
        }
      }
      _ -> should.fail()
    }
  })
}

// Test complex nested structures
pub fn complex_content_encode_decode_test() {
  let assert Ok(test_uri) = uri.parse("https://example.com")
  
  let complex_content = Block([
    Heading("Main Heading"),
    Paragraph([
      Text("First paragraph with "),
      Link(test_uri, "an internal link"),
      Text(" and "),
      LinkExternal(test_uri, "an external link"),
    ]),
    List([
      Text("List item with "),
      Image(test_uri, "embedded image"),
    ]),
    Block([
      Heading("Nested heading"),
      Text("Nested text"),
    ]),
  ])

  // Create an article with this content
  let article = article.ArticleV1(
    id: "test",
    slug: "test",
    revision: 1,
    title: "test",
    leading: "test",
    subtitle: "test",
    content: Loaded([complex_content]),
    draft: None,
  )

  // Encode to JSON
  let encoded = article.article_encoder(article)
  
  // Decode back from JSON
  let decoded = decode.run(
    dynamic.from(encoded),
    article.article_decoder(),
  )
  
  // Verify decoded content matches original
  case decoded |> should.be_ok {
    article.ArticleV1(id: _, slug: _, revision: _, title: _, leading: _, subtitle: _, content: Loaded(content_list), draft: _) -> {
      case content_list {
        [content_item] -> content_item |> should.equal(complex_content)
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

// Test edge cases
pub fn edge_cases_content_encode_decode_test() {
  // Empty content structures
  let empty_cases = [
    Block([]),
    Paragraph([]),
    List([]),
    Text(""),
  ]

  list.each(empty_cases, fn(content) {
    // Create an article with this content
    let article = article.ArticleV1(
      id: "test",
      slug: "test",
      revision: 1,
      title: "test",
      leading: "test",
      subtitle: "test",
      content: Loaded([content]),
      draft: None,
    )

    let encoded = article.article_encoder(article)
    
    // Decode back from JSON
    let decoded = decode.run(
      dynamic.from(encoded),
      article.article_decoder(),
    )
    
    // Verify decoded content matches original
    case decoded |> should.be_ok {
      article.ArticleV1(id: _, slug: _, revision: _, title: _, leading: _, subtitle: _, content: Loaded(content_list), draft: _) -> {
        case content_list {
          [content_item] -> content_item |> should.equal(content)
          _ -> should.fail()
        }
      }
      _ -> should.fail()
    }
  })

  // Test deeply nested content
  let assert Ok(test_uri) = uri.parse("https://example.com")
  let deep_nesting =
    Block([
      Block([
        Block([
          Block([Text("Very deeply nested text")]),
          Link(test_uri, "Deep link"),
        ]),
      ]),
    ])

  // Create an article with this content
  let article = article.ArticleV1(
    id: "test",
    slug: "test",
    revision: 1,
    title: "test",
    leading: "test",
    subtitle: "test",
    content: Loaded([deep_nesting]),
    draft: None,
  )

  let encoded = article.article_encoder(article)
  
  // Decode back from JSON
  let decoded = decode.run(
    dynamic.from(encoded),
    article.article_decoder(),
  )
  
  // Verify decoded content matches original
  case decoded |> should.be_ok {
    article.ArticleV1(id: _, slug: _, revision: _, title: _, leading: _, subtitle: _, content: Loaded(content_list), draft: _) -> {
      case content_list {
        [content_item] -> content_item |> should.equal(deep_nesting)
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
} 