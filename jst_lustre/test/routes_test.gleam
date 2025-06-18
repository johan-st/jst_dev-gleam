import article/article.{ArticleV1}
import article/content.{Heading, Paragraph, Text}
import gleam/option.{None}
import gleam/uri
import gleeunit/should
import routes/routes
import utils/remote_data.{Loaded}

pub fn route_url_test() {
  let article_id = "test-id"
  let article =
    ArticleV1(
      id: article_id,
      slug: "test",
      revision: 12,
      leading: "l",
      title: "t",
      subtitle: "sub",
      content: Loaded([]),
      draft: None,
    )
  let route = routes.ArticleEdit(article_id)
  let url = routes.to_string(route)
  let assert Ok(parsed_url) = uri.parse(url)
  let parsed_route = routes.from_uri(parsed_url)

  parsed_route
  |> should.equal(route)
  url
  |> should.equal("/article/" <> article_id <> "/edit")
}
