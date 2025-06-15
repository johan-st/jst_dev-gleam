import birl
import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import lustre/effect.{type Effect}
import utils/http

pub type Session {
  Unauthenticated
  Authenticated(session: SessionAuthenticated)
}

pub opaque type SessionAuthenticated {
  SessionAuthenticated(subject: String, token: String, expiry: Int)
}

// EFFECTS ---------------------------------------------------------------------

pub fn login(msg, username: String, password: String) -> Effect(msg) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Post)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/auth")
    |> request.set_port(8080)
    |> request.set_body(
      json.object([
        #("username", json.string(username)),
        #("password", json.string(password)),
      ])
      |> json.to_string
      |> echo,
    )

  let expect =
    http.expect_text_response(
      fn(response) { Ok(response) },
      fn(error) { error },
      msg,
    )

  http.send(request, expect)
}

pub fn auth_check(msg) -> Effect(msg) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/auth")
    |> request.set_port(8080)
    |> request.set_header("credentials", "include")
  http.send(request, http.expect_json(auth_check_decoder(), msg))
}

pub fn auth_logout(msg) -> Effect(a) {
  let request =
    request.new()
    |> request.set_method(gleam_http.Get)
    |> request.set_scheme(gleam_http.Http)
    |> request.set_host("localhost")
    |> request.set_path("/api/auth/logout")
    |> request.set_port(8080)
    |> request.set_header("credentials", "include")
  http.send(
    request,
    http.expect_text_response(
      fn(response) { Ok(response) },
      fn(error) { error },
      msg,
    ),
  )
}

// DECODERS --------------------------------------------------------------------

pub fn auth_check_decoder() -> Decoder(#(Bool, String, List(String))) {
  use valid <- decode.field("valid", decode.bool)
  use subject <- decode.field("subject", decode.string)
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(#(valid, subject, permissions))
}

pub fn auth_logout_decoder() -> Decoder(String) {
  use result <- decode.field("result", decode.string)
  decode.success(result)
}

pub fn session_decoder() -> Decoder(SessionAuthenticated) {
  use subject <- decode.field("subject", decode.string)
  use token <- decode.field("token", decode.string)
  use expiry <- decode.field("expiry", decode.int)
  decode.success(SessionAuthenticated(subject, token, expiry))
}
