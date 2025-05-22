import article/content.{
  type Content, Block, Heading, Image, Link, LinkExternal, List, Paragraph, Text,
  Unknown,
}
import article/draft.{type Draft}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import utils/http.{type HttpError}
import utils/remote_data.{type RemoteData}

pub fn login(msg, username: String, password: String) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/api/auth")
    |> request.set_port(8080)
  // |> request.set_body(
  //   json.object([
  // #("username", json.string(username)),
  // #("password", json.string(password)),
  //   ])
  //   |> json.to_string,
  // )

  let expect =
    http.expect_text_response(
      fn(response) { Ok(response) },
      fn(error) { error },
      msg,
    )

  http.send(request, expect)
}
