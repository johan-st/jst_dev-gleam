import article/article.{ArticleV1}
import article/content.{Heading, Paragraph, Text}
import article/id
import gleam/uri
import gleeunit
import gleeunit/should
import routes/routes
import utils/remote_data.{Loaded}
import gleam/option.{None}

pub fn route_url_test() {
  let article_id = "test-id"
  let article =
    ArticleV1(
      id: id.from_string(article_id),
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


