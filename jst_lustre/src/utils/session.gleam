import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import lustre/effect.{type Effect}
import utils/http

pub type Session {
  Unauthenticated
  Authenticated(session: SessionAuthenticated)
}

pub opaque type SessionAuthenticated {
  SessionAuthenticated(subject: String, expiry: Int, permissions: List(String))
}

// API -------------------------------------------------------------------------

pub fn permissions(session: Session) -> List(String) {
  case session {
    Authenticated(SessionAuthenticated(_, _, permissions)) -> permissions
    Unauthenticated -> []
  }
}

pub fn permission_any(session: Session, any: List(String)) -> Bool {
  list.any(permissions(session), fn(has) {
    list.any(any, fn(want) { want == has })
  })
}

// EFFECTS ---------------------------------------------------------------------

pub fn login(msg, username: String, password: String) -> Effect(msg) {
  let body =
    json.object([
      #("username", json.string(username)),
      #("password", json.string(password)),
    ])
    |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_scheme(gleam_http.Http)
  |> request.set_host("localhost")
  |> request.set_path("/api/auth")
  |> request.set_port(8080)
  |> request.set_body(body)
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_check(msg) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_scheme(gleam_http.Http)
  |> request.set_host("localhost")
  |> request.set_path("/api/auth")
  |> request.set_port(8080)
  |> request.set_header("credentials", "include")
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_logout(msg) -> Effect(a) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_scheme(gleam_http.Http)
  |> request.set_host("localhost")
  |> request.set_path("/api/auth/logout")
  |> request.set_port(8080)
  |> request.set_header("credentials", "include")
  |> http.send(http.expect_text(msg))
}

// DECODERS --------------------------------------------------------------------

pub fn auth_logout_decoder() -> Decoder(String) {
  use result <- decode.field("result", decode.string)
  decode.success(result)
}

pub fn session_decoder() -> Decoder(Session) {
  authenticated_decoder()
  |> decode.then(fn(sess) { decode.success(Authenticated(sess)) })
}

pub fn authenticated_decoder() -> Decoder(SessionAuthenticated) {
  use subject <- decode.field("subject", decode.string)
  use expires_at <- decode.field("expiresAt", decode.int)
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(SessionAuthenticated(subject, expires_at, permissions))
}
