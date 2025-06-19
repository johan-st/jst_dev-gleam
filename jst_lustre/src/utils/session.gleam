import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri.{type Uri}
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

pub fn login(msg, username: String, password: String, base_uri: Uri) -> Effect(msg) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }

  let body =
    json.object([
      #("username", json.string(username)),
      #("password", json.string(password)),
    ])
    |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_scheme(scheme)
  |> request.set_host(host)
  |> request.set_path("/api/auth")
  |> request.set_port(port)
  |> request.set_body(body)
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_check(msg, base_uri: Uri) -> Effect(msg) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }

  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_scheme(scheme)
  |> request.set_host(host)
  |> request.set_path("/api/auth")
  |> request.set_port(port)
  |> request.set_header("credentials", "include")
  |> http.send(http.expect_json(session_decoder(), msg))
}

pub fn auth_logout(msg, base_uri: Uri) -> Effect(a) {
  let scheme = case base_uri.scheme {
    Some("http") -> gleam_http.Http
    Some("https") -> gleam_http.Https
    _ -> gleam_http.Http
  }
  let host = case base_uri.host {
    Some(h) -> h
    None -> "localhost"
  }
  let port = case base_uri.port {
    Some(p) -> p
    None -> 8080
  }

  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_scheme(scheme)
  |> request.set_host(host)
  |> request.set_path("/api/auth/logout")
  |> request.set_port(port)
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
