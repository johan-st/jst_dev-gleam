import gleam/uri
import gleeunit/should
import routes

pub fn route_url_test() {
  let article_id = "test-id"
  let route = routes.ArticleEdit(article_id)
  let url = routes.to_string(route)
  let assert Ok(parsed_url) = uri.parse(url)
  let parsed_route = routes.from_uri(parsed_url)

  parsed_route
  |> should.equal(route)
  url
  |> should.equal("/article/" <> article_id <> "/edit")
}
