import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

pub type UserFull {
  UserFull(
    id: String,
    revision: Int,
    username: String,
    email: String,
    permissions: List(String),
  )
}

pub type UserUpdateResponse {
  UserUpdateResponse(
    id: String,
    revision: Int,
    username: String,
    email: String,
    password_changed: Bool,
  )
}

pub type UserUpdateMeRequest {
  UserUpdateMeRequest(
    username: String,
    email: String,
    password: option.Option(String),
    old_password: option.Option(String),
  )
}

fn user_full_decoder() -> Decoder(UserFull) {
  use id <- decode.field("id", decode.string)
  use revision <- decode.field("revision", decode.int)
  use username <- decode.field("username", decode.string)
  use email <- decode.field("email", decode.string)
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(UserFull(id, revision, username, email, permissions))
}

fn user_update_response_decoder() -> Decoder(UserUpdateResponse) {
  use id <- decode.field("id", decode.string)
  use revision <- decode.field("revision", decode.int)
  use username <- decode.field("username", decode.string)
  use email <- decode.field("email", decode.string)
  use password_changed <- decode.field("passwordChanged", decode.bool)
  decode.success(UserUpdateResponse(
    id,
    revision,
    username,
    email,
    password_changed,
  ))
}

fn encode_user_update_me_request(req: UserUpdateMeRequest) -> String {
  let fields = [
    #("username", json.string(req.username)),
    #("email", json.string(req.email)),
  ]
  let fields_with_pw = case req.password {
    option.Some(pw) -> [#("password", json.string(pw)), ..fields]
    option.None -> fields
  }
  let fields_with_old = case req.old_password {
    option.Some(pw) -> [#("oldPassword", json.string(pw)), ..fields_with_pw]
    option.None -> fields_with_pw
  }
  json.object(fields_with_old) |> json.to_string
}

pub fn user_get(msg, base_uri: Uri, id: String) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_path("/api/users/" <> id)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(user_full_decoder(), msg))
}

pub fn user_update(
  msg,
  base_uri: Uri,
  id: String,
  req: UserUpdateMeRequest,
) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Put)
  |> request.set_path("/api/users/" <> id)
  |> request.set_body(encode_user_update_me_request(req))
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(user_update_response_decoder(), msg))
}

fn add_base_uri(req, base_uri: Uri) {
  let req = case base_uri.scheme {
    Some("http") -> req |> request.set_scheme(gleam_http.Http)
    Some("https") -> req |> request.set_scheme(gleam_http.Https)
    _ -> req |> request.set_scheme(gleam_http.Https)
  }

  let req = case base_uri.host {
    Some(host) -> req |> request.set_host(host)
    None -> req
  }

  let req = case base_uri.port {
    Some(port) -> req |> request.set_port(port)
    None -> req
  }

  req
}
