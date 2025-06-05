import article/article.{ArticleFull}
import article/content.{Heading, Paragraph, Text}
import article/id
import gleam/uri
import gleeunit
import gleeunit/should
import routes/routes
import utils/remote_data.{Loaded}

pub fn route_url_test() {
  let article_id = "test-id"
  let article =
    ArticleFull(
      id: id.from_string(article_id),
      slug: "test",
      revision: 12,
      leading: "l",
      title: "t",
      subtitle: "sub",
      content: [],
    )
  let route = routes.ArticleEdit(article)
  let url = routes.to_string(route)
  let assert Ok(parsed_url) = uri.parse(url)
  let parsed_route = routes.from_uri(parsed_url, Loaded([article]))

  parsed_route
  |> should.equal(route)
  url
  |> should.equal("/article/" <> article_id <> "/edit")
}


