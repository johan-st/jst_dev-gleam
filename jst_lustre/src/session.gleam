import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

pub type Session {
  Pending
  Unauthenticated
  Authenticated(session: SessionAuthenticated)
}

pub opaque type SessionAuthenticated {
  SessionAuthenticated(subject: String, expiry: Int, permissions: List(String))
}

// API -------------------------------------------------------------------------

pub fn permissions(session: Session) -> List(String) {
  case session {
    Pending -> []
    Unauthenticated -> []
    Authenticated(SessionAuthenticated(_, _, permissions)) -> permissions
  }
}

pub fn permission_any(session: Session, any: List(String)) -> Bool {
  list.any(permissions(session), fn(has) {
    list.any(any, fn(want) { want == has })
  })
}

// EFFECTS ---------------------------------------------------------------------

pub fn login(
  msg,
  username: String,
  password: String,
  base_uri: Uri,
) -> Effect(msg) {
  let body =
    json.object([
      #("username", json.string(username)),
      #("password", json.string(password)),
    ])
    |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_path("/api/auth")
  |> request.set_body(body)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_check(msg, base_uri: Uri) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_path("/api/auth")
  |> request.set_header("credentials", "include")
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_logout(msg, base_uri: Uri) -> Effect(a) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_path("/api/auth/logout")
  |> request.set_header("credentials", "include")
  |> add_base_uri(base_uri)
  |> http.send(http.expect_text(msg))
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
