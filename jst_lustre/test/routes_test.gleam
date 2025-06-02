import article/article.{ArticleFull}
import article/content.{Heading, Paragraph, Text}
import article/id
import gleam/uri
import gleeunit
import gleeunit/should
import routes/routes

pub fn route_url_test() {
  let article_id = "test-id"
  let article =
    ArticleFull(
      id: id.from_string(article_id),
      slug: "test",
      revision: 12,
      leading: "leading",
      title: "test",
      subtitle: "subtitle",
      content: [Heading("test"), Paragraph([Text("test")])],
    )
  let route = routes.ArticleEdit(article)
  let url = routes.to_string(route)
  let assert Ok(parsed_url) = uri.parse(url)
  let parsed_url = routes.from_uri(parsed_url, [article])

  route
  |> should.equal(parsed_url)
  url
  |> should.equal("/article/" <> article_id <> "/edit")
}
