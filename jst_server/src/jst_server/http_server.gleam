import ewe
import gleam/http/request
import gleam/http/response
import gleam/http
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http/cookie
import gluid

import jst_server/auth/jwt
import jst_server/json
import jst_server/nats/enats
import jst_server/ws_bridge
 
pub fn handler(req: ewe.Request, static_dir: String, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {

  let method = req.method
  let path = req.path
  let segments = request.path_segments(req)

  // Static assets (Phase 1: serve built Lustre output)
  case method, path, segments {
    // Current Lustre build emits `jst_lustre.min.mjs` + `jst_lustre.min.css`
    // into `../build/` (no index.html), so we serve a small HTML wrapper here.
    http.Get, "/", _ -> serve_index_html()
    http.Get, "/favicon.ico", _ -> serve_file(static_dir <> "/favicon.ico")
    http.Get, _, ["static", ..rest] -> {
      let rel = rest |> string.join(with: "/")
      serve_file(static_dir <> "/static/" <> rel)
    }
    http.Get, _, ["build", ..rest] -> {
      let rel = rest |> string.join(with: "/")
      serve_file(static_dir <> "/" <> rel)
    }
    http.Get, "/jst_lustre.min.mjs", _ -> serve_file(static_dir <> "/jst_lustre.min.mjs")
    http.Get, "/jst_lustre.min.css", _ -> serve_file(static_dir <> "/jst_lustre.min.css")

    http.Get, "/ws", _ -> handle_ws(req, nc, jwt_secret)

    // --- API routes (Phase 1) ---
    http.Options, _, _ -> cors_preflight(req)

    http.Post, "/api/auth", _ -> handle_auth(req, nc, jwt_secret)
    http.Post, "/api/auth/refresh", _ -> handle_auth_refresh(req, nc, jwt_secret)
    http.Get, "/api/auth/logout", _ -> handle_auth_logout(req)
    http.Get, "/api/auth", _ -> handle_auth_check(req, jwt_secret)

    http.Get, _, ["api", "users", id] -> handle_user_get(req, nc, jwt_secret, id)
    http.Put, _, ["api", "users", id] -> handle_user_update(req, nc, jwt_secret, id)

    // articles
    http.Get, "/api/article", _ -> handle_article_list(req, nc)
    http.Post, "/api/article", _ -> handle_article_new(req, nc, jwt_secret)
    http.Get, _, ["api", "article", id] -> handle_article_get(req, nc, id)
    http.Put, _, ["api", "article", id] -> handle_article_update(req, nc, jwt_secret, id)
    http.Delete, _, ["api", "article", id] -> handle_article_delete(req, nc, jwt_secret, id)
    http.Get, _, ["api", "article", id, "revisions"] -> handle_article_revisions(req, nc, id)
    http.Get, _, ["api", "article", id, "revisions", _rev] -> handle_article_revision(req, nc, id)

    // short urls
    http.Get, "/api/url", _ -> handle_short_url_list(req, nc)
    http.Post, "/api/url", _ -> handle_short_url_create(req, nc, jwt_secret)
    http.Get, _, ["api", "url", id] -> handle_short_url_get(req, nc, id)
    http.Put, _, ["api", "url", id] -> handle_short_url_update(req, nc, jwt_secret, id)
    http.Delete, _, ["api", "url", id] -> handle_short_url_delete(req, nc, jwt_secret, id)
    http.Get, _, ["u", short_code] -> handle_short_url_redirect(req, nc, short_code)

    // notifications
    http.Post, "/api/notifications", _ -> handle_notification_send(req, nc, jwt_secret)

    // chat request (anonymous)
    http.Post, "/api/chat/request", _ -> handle_chat_request(req, nc)

    _, _, _ -> response.new(404) |> response.set_body(ewe.TextData("not found"))
  }
}

fn new(code: Int) -> ewe.Response {
  response.new(code)
  |> response.set_body(ewe.Empty)
}

fn serve_file(path: String) -> ewe.Response {
  ewe.file(path, offset: None, limit: None)
  |> result.map(fn(body) { new(200) |> response.set_body(body) })
  |> result.unwrap(or: new(404) |> response.set_body(ewe.TextData("not found")))
}

fn serve_index_html() -> ewe.Response {
  new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(ewe.TextData(
    "<!doctype html>\n"
    <> "<html lang=\"en\">\n"
    <> "<head>\n"
    <> "  <meta charset=\"utf-8\" />\n"
    <> "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
    <> "  <title>jst</title>\n"
    <> "  <link rel=\"stylesheet\" href=\"/jst_lustre.min.css\" />\n"
    <> "</head>\n"
    <> "<body>\n"
    <> "  <div id=\"app\"></div>\n"
    <> "  <script type=\"module\" src=\"/jst_lustre.min.mjs\"></script>\n"
    <> "</body>\n"
    <> "</html>\n",
  ))
}

// --- CORS ---------------------------------------------------------------------

fn allowed_origins() -> List(String) {
  [
    "https://jst.dev",
    "https://jst-dev.fly.dev",
    "https://jst-dev-preview.fly.dev",
    "https://server-small-dream-1266.fly.dev",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "http://localhost:1234",
    "http://127.0.0.1:1234",
  ]
}

fn handle_ws(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  let origin = request.get_header(req, "origin") |> result.unwrap("")
  case list.any(allowed_origins(), fn(o) { o == origin }) {
    True -> ws_bridge.handle_ws(req, nc, jwt_secret)
    False -> new(403) |> response.set_body(ewe.TextData("forbidden"))
  }
}

fn with_cors_headers(req: ewe.Request, resp: ewe.Response) -> ewe.Response {
  let origin = request.get_header(req, "origin") |> result.unwrap("")
  let resp =
    resp
    |> response.set_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> response.set_header("access-control-allow-headers", "Content-Type, Authorization")
    |> response.set_header("access-control-allow-credentials", "true")

  case list.any(allowed_origins(), fn(o) { o == origin }) {
    True -> response.set_header(resp, "access-control-allow-origin", origin)
    False -> resp
  }
}

fn cors(req: ewe.Request) -> fn(ewe.Response) -> ewe.Response {
  fn(resp) { with_cors_headers(req, resp) }
}

fn cors_preflight(req: ewe.Request) -> ewe.Response {
  new(200)
  |> cors(req)
  |> response.set_body(ewe.TextData(""))
}

// --- Auth ---------------------------------------------------------------------

const cookie_auth = "jst_dev_who"
const audience = "jst_dev.who"
fn handle_auth(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  // Read raw body (JSON), forward to who service, set cookie, return verified subject/perm.
  case ewe.read_body(req, 1024 * 1024) {
    Error(_) ->
      new(400)
      |> cors(req)
      |> response.set_body(ewe.TextData("Invalid request body"))

    Ok(req2) -> {
      let body = req2.body
      case enats.request(nc, "svc.who.auth.login", body, 4_000) {
        Error(e) ->
          respond_req_error(req, e.reason, timeout_message: "gateway timeout while requesting auth", generic_message: "error requesting auth")

        Ok(reply) -> {
          case header_get(reply.headers, "Nats-Service-Error") {
            Some(_) ->
              new(502)
              |> cors(req)
              |> response.set_body(ewe.TextData(bit_array.to_string(reply.payload) |> result.unwrap("")))
            None -> {
          case json.decode_bits(reply.payload) {
            Error(_) ->
              new(500)
              |> cors(req)
              |> response.set_body(ewe.TextData("error unmarshalling auth response"))

            Ok(obj) ->
              case decode.run(obj, auth_response_decoder()) {
                Error(_) ->
                  new(500)
                  |> cors(req)
                  |> response.set_body(ewe.TextData("error unmarshalling auth response"))
                Ok(ar) ->
                  case jwt.verify_hs512(jwt_secret, audience, ar.token) {
                    Error(_) ->
                      new(500)
                      |> cors(req)
                      |> response.set_body(ewe.TextData("error verifying jwt"))
                    Ok(claims) -> {
                      let expires_at = unix_seconds() + 30 * 60
                      let set_cookie =
                        cookie.set_header(
                          cookie_auth,
                          ar.token,
                          cookie.Attributes(
                            max_age: Some(30 * 60),
                            domain: None,
                            path: Some("/"),
                            secure: True,
                            http_only: True,
                            same_site: Some(cookie.Strict),
                          ),
                        )

                      new(200)
                      |> cors(req)
                      |> response.set_header("set-cookie", set_cookie)
                      |> json_response(
                        dynamic.properties([
                          #(dynamic.string("subject"), dynamic.string(claims.subject)),
                          #(dynamic.string("expiresAt"), dynamic.int(expires_at)),
                          #(dynamic.string("permissions"), dynamic.list(claims.permissions |> list.map(dynamic.string))),
                        ]),
                        _,
                      )
                    }
                  }
              }
          }
            }
          }
        }
      }
    }
  }
}

type AuthReply {
  AuthReply(token: String)
}

fn auth_response_decoder() -> decode.Decoder(AuthReply) {
  use token <- decode.field("token", decode.string)
  decode.success(AuthReply(token: token))
}

fn handle_auth_refresh(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  let cookie_val = get_cookie(req, cookie_auth)
  case cookie_val {
    None ->
      new(401)
      |> cors(req)
      |> response.set_body(ewe.TextData("unauthorized"))

    Some(token) ->
      case jwt.verify_hs512(jwt_secret, audience, token) {
        Error(_) ->
          new(401)
          |> cors(req)
          |> response.set_body(ewe.TextData("unauthorized"))

        Ok(claims) -> {
          let payload =
            dynamic.properties([
              #(dynamic.string("subject"), dynamic.string(claims.subject)),
            ])
            |> json.encode_dynamic

          case payload {
            Error(_) ->
              new(500)
              |> cors(req)
              |> response.set_body(ewe.TextData("error marshalling request"))

            Ok(bits) ->
              case enats.request(nc, "svc.who.auth.refresh", bits, 4_000) {
                Error(e) ->
                  respond_req_error(req, e.reason, timeout_message: "gateway timeout while refreshing auth", generic_message: "error requesting auth refresh")

                Ok(reply) ->
                  case header_get(reply.headers, "Nats-Service-Error") {
                    Some(_) ->
                      new(502)
                      |> cors(req)
                      |> response.set_body(ewe.TextData(bit_array.to_string(reply.payload) |> result.unwrap("")))
                    None ->
                  case json.decode_bits(reply.payload) {
                    Error(_) ->
                      new(500)
                      |> cors(req)
                      |> response.set_body(ewe.TextData("error unmarshalling refresh response"))
                    Ok(obj) ->
                      case decode.run(obj, auth_response_decoder()) {
                        Error(_) ->
                          new(500)
                          |> cors(req)
                          |> response.set_body(ewe.TextData("error unmarshalling refresh response"))
                        Ok(ar) ->
                          case jwt.verify_hs512(jwt_secret, audience, ar.token) {
                            Error(_) ->
                              new(500)
                              |> cors(req)
                              |> response.set_body(ewe.TextData("error verifying jwt"))
                            Ok(claims2) -> {
                              let expires_at = unix_seconds() + 30 * 60
                              let set_cookie =
                                cookie.set_header(
                                  cookie_auth,
                                  ar.token,
                                  cookie.Attributes(
                                    max_age: Some(30 * 60),
                                    domain: None,
                                    path: Some("/"),
                                    secure: True,
                                    http_only: True,
                                    same_site: Some(cookie.Strict),
                                  ),
                                )
                              new(200)
                              |> cors(req)
                              |> response.set_header("set-cookie", set_cookie)
                              |> json_response(
                                dynamic.properties([
                                  #(dynamic.string("subject"), dynamic.string(claims2.subject)),
                                  #(dynamic.string("expiresAt"), dynamic.int(expires_at)),
                                  #(dynamic.string("permissions"), dynamic.list(claims2.permissions |> list.map(dynamic.string))),
                                ]),
                                _,
                              )
                            }
                          }
                      }
                  }
                  }
              }
          }
        }
      }
  }
}

fn handle_auth_logout(req: ewe.Request) -> ewe.Response {
  // Equivalent to Go: Set cookie with MaxAge=-1 and return empty 200.
  let set_cookie =
    cookie.set_header(
      cookie_auth,
      "",
      cookie.Attributes(
        max_age: Some(-1),
        domain: None,
        path: Some("/"),
        secure: True,
        http_only: True,
        same_site: Some(cookie.Strict),
      ),
    )

  new(200)
  |> cors(req)
  |> response.set_header("set-cookie", set_cookie)
  |> response.set_body(ewe.TextData(""))
}

fn handle_auth_check(req: ewe.Request, jwt_secret: BitArray) -> ewe.Response {
  case get_cookie(req, cookie_auth) {
    None ->
      new(401)
      |> cors(req)
      |> json_response(
        dynamic.properties([
          #(dynamic.string("subject"), dynamic.string("")),
          #(dynamic.string("expiresAt"), dynamic.int(0)),
          #(dynamic.string("permissions"), dynamic.nil()),
        ]),
        _,
      )
    Some(token) ->
      case jwt.verify_hs512(jwt_secret, audience, token) {
        Error(_) ->
          new(401)
          |> cors(req)
          |> json_response(
            dynamic.properties([
              #(dynamic.string("subject"), dynamic.string("")),
              #(dynamic.string("expiresAt"), dynamic.int(0)),
              #(dynamic.string("permissions"), dynamic.nil()),
            ]),
            _,
          )
        Ok(claims) -> {
          let expires_at = unix_seconds() + 30 * 60
          new(200)
          |> cors(req)
          |> json_response(
            dynamic.properties([
              #(dynamic.string("subject"), dynamic.string(claims.subject)),
              #(dynamic.string("expiresAt"), dynamic.int(expires_at)),
              #(dynamic.string("permissions"), dynamic.list(claims.permissions |> list.map(dynamic.string))),
            ]),
            _,
          )
        }
      }
  }
}

fn get_cookie(req: ewe.Request, name: String) -> Option(String) {
  case request.get_header(req, "cookie") {
    Error(_) -> None
    Ok(raw) -> {
      let cookies = cookie.parse(raw)
      case list.find(cookies, fn(pair) { pair.0 == name }) {
        Ok(pair) -> Some(pair.1)
        Error(_) -> None
      }
    }
  }
}

fn json_response(body: dynamic.Dynamic, resp: ewe.Response) -> ewe.Response {
  case json.encode_dynamic(body) {
    Error(_) -> resp |> response.set_body(ewe.TextData("failed to marshal json"))
    Ok(bits) ->
      resp
      |> response.set_header("content-type", "application/json")
      |> response.set_body(ewe.BitsData(bits))
  }
}

// --- Users --------------------------------------------------------------------

fn handle_user_get(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case id == "" {
    True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid id"))
    False ->
      case require_auth_subject(req, jwt_secret, id) {
        Error(resp) -> resp
        Ok(_) -> {
          let payload =
            dynamic.properties([#(dynamic.string("id"), dynamic.string(id))])
            |> json.encode_dynamic

          case payload {
            Error(_) ->
              new(500)
              |> cors(req)
              |> response.set_body(ewe.TextData("server error"))
            Ok(bits) ->
              case enats.request(nc, "svc.who.users.get", bits, 4_000) {
                Error(_) ->
                  new(504)
                  |> cors(req)
                  |> response.set_body(ewe.TextData("gateway timeout while requesting who"))
                Ok(reply) ->
                  new(200)
                  |> cors(req)
                  |> response.set_header("content-type", "application/json")
                  |> response.set_body(ewe.BitsData(reply.payload))
              }
          }
        }
      }
  }
}

fn handle_user_update(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case id == "" {
    True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid id"))
    False ->
      case require_auth_subject(req, jwt_secret, id) {
        Error(resp) -> resp
        Ok(_) ->
          case ewe.read_body(req, 1024 * 1024) {
            Error(_) ->
              new(400)
              |> cors(req)
              |> response.set_body(ewe.TextData("invalid request"))
            Ok(req2) ->
              case json.decode_bits(req2.body) {
                Error(_) ->
                  new(400)
                  |> cors(req)
                  |> response.set_body(ewe.TextData("invalid request"))
                Ok(obj) ->
                  case decode.run(obj, user_update_decoder()) {
                    Error(_) ->
                      new(400)
                      |> cors(req)
                      |> response.set_body(ewe.TextData("invalid request"))
                    Ok(update) -> {
                      let payload =
                        dynamic.properties([
                          #(dynamic.string("id"), dynamic.string(id)),
                          #(dynamic.string("username"), maybe_string(update.username)),
                          #(dynamic.string("email"), maybe_string(update.email)),
                          #(dynamic.string("password"), maybe_string(update.password)),
                          #(dynamic.string("oldPassword"), maybe_string(update.old_password)),
                        ])
                        |> json.encode_dynamic

                      case payload {
                        Error(_) ->
                          new(500)
                          |> cors(req)
                          |> response.set_body(ewe.TextData("server error"))
                        Ok(bits) ->
                          case enats.request(nc, "svc.who.users.update", bits, 4_000) {
                            Error(_) ->
                              new(504)
                              |> cors(req)
                              |> response.set_body(ewe.TextData("gateway timeout while requesting who"))
                            Ok(reply) ->
                              new(200)
                              |> cors(req)
                              |> response.set_header("content-type", "application/json")
                              |> response.set_body(ewe.BitsData(reply.payload))
                          }
                      }
                    }
                  }
              }
          }
      }
  }
}

type UserUpdateBody {
  UserUpdateBody(
    username: Option(String),
    email: Option(String),
    password: Option(String),
    old_password: Option(String),
  )
}

fn user_update_decoder() -> decode.Decoder(UserUpdateBody) {
  use username <- decode.optional_field("username", None, decode.optional(decode.string))
  use email <- decode.optional_field("email", None, decode.optional(decode.string))
  use password <- decode.optional_field("password", None, decode.optional(decode.string))
  use old_password <- decode.optional_field("oldPassword", None, decode.optional(decode.string))
  decode.success(UserUpdateBody(
    username: username,
    email: email,
    password: password,
    old_password: old_password,
  ))
}

fn maybe_string(v: Option(String)) -> dynamic.Dynamic {
  case v {
    None -> dynamic.nil()
    Some(s) -> dynamic.string(s)
  }
}

fn require_auth_subject(req: ewe.Request, jwt_secret: BitArray, expected_subject: String) -> Result(Nil, ewe.Response) {
  case get_cookie(req, cookie_auth) {
    None ->
      Error(new(401) |> cors(req) |> response.set_body(ewe.TextData("not authorized")))
    Some(token) ->
      case jwt.verify_hs512(jwt_secret, audience, token) {
        Error(_) ->
          Error(new(401) |> cors(req) |> response.set_body(ewe.TextData("not authorized")))
        Ok(claims) ->
          case claims.subject == expected_subject {
            True -> Ok(Nil)
            False -> Error(new(403) |> cors(req) |> response.set_body(ewe.TextData("forbidden")))
          }
      }
  }
}

fn respond_req_error(
  req: ewe.Request,
  reason: String,
  timeout_message timeout_message: String,
  generic_message generic_message: String,
) -> ewe.Response {
  case string.contains(reason, "timeout") {
    True -> new(504) |> cors(req) |> response.set_body(ewe.TextData(timeout_message))
    False -> new(500) |> cors(req) |> response.set_body(ewe.TextData(generic_message))
  }
}

fn header_get(headers: List(#(String, String)), key: String) -> Option(String) {
  case list.find(headers, fn(h) { h.0 == key }) {
    Ok(h) -> Some(h.1)
    Error(_) -> None
  }
}

@external(erlang, "jst_server_ffi", "unix_seconds")
fn unix_seconds() -> Int

// --- Helpers: auth -------------------------------------------------------------

const perm_post_edit_any = "post_edit_any"

fn auth_claims(req: ewe.Request, jwt_secret: BitArray) -> Option(jwt.Claims) {
  case get_cookie(req, cookie_auth) {
    None -> None
    Some(token) ->
      case jwt.verify_hs512(jwt_secret, audience, token) {
        Ok(c) -> Some(c)
        Error(_) -> None
      }
  }
}

fn has_permission(claims: jwt.Claims, perm: String) -> Bool {
  list.any(claims.permissions, fn(p) { p == perm })
}

fn require_auth(req: ewe.Request, jwt_secret: BitArray) -> Result(jwt.Claims, ewe.Response) {
  case auth_claims(req, jwt_secret) {
    None -> Error(new(401) |> cors(req) |> response.set_body(ewe.TextData("unauthorized")))
    Some(c) -> Ok(c)
  }
}

fn require_permission(req: ewe.Request, jwt_secret: BitArray, perm: String) -> Result(jwt.Claims, ewe.Response) {
  case require_auth(req, jwt_secret) {
    Error(r) -> Error(r)
    Ok(c) ->
      case has_permission(c, perm) {
        True -> Ok(c)
        False -> Error(new(403) |> cors(req) |> response.set_body(ewe.TextData("forbidden")))
      }
  }
}

fn is_uuidish(s: String) -> Bool {
  // good enough to match Go's uuid.Parse failures for obviously-bad input
  string.length(s) == 36
}

// --- Articles -----------------------------------------------------------------

const kv_article = "article"

fn handle_article_list(req: ewe.Request, nc: enats.Conn) -> ewe.Response {
  case enats.kv_list_keys(nc, kv_article) {
    Error(_) ->
      new(500)
      |> cors(req)
      |> response.set_body(ewe.TextData("failed to get all articles"))
    Ok(keys) -> {
      let articles =
        keys
        |> list.filter_map(fn(k) {
          case enats.kv_get_value(nc, kv_article, k) {
            enats.KvFound(value: v, rev: _) ->
              case json.decode_bits(v) {
                Ok(obj) -> Ok(obj)
                Error(_) -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        })

      new(200)
      |> cors(req)
      |> json_response(dynamic.properties([#(dynamic.string("articles"), dynamic.list(articles))]), _)
    }
  }
}

fn handle_article_get(req: ewe.Request, nc: enats.Conn, id: String) -> ewe.Response {
  case is_uuidish(id) {
    False -> new(400) |> cors(req) |> response.set_body(ewe.TextData("failed to parse id"))
    True ->
      case enats.kv_get_value(nc, kv_article, id) {
        enats.KvFound(value: v, rev: _) ->
          new(200)
          |> cors(req)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(ewe.BitsData(v))
        enats.KvNotFound ->
          new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
        enats.KvDeleted ->
          new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
        enats.KvError(_) ->
          new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to get article"))
      }
  }
}

fn handle_article_new(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  case require_permission(req, jwt_secret, perm_post_edit_any) {
    Error(r) -> r
    Ok(claims) -> {
      // get full user (username)
      let who_req =
        dynamic.properties([#(dynamic.string("id"), dynamic.string(claims.subject))])
        |> json.encode_dynamic

      case who_req {
        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to marshal user request"))
        Ok(bits) ->
          case enats.request(nc, "svc.who.users.get", bits, 4_000) {
            Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to get user data"))
            Ok(reply) ->
              case json.decode_bits(reply.payload) {
                Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to unmarshal user data"))
                Ok(user_obj) ->
                  case decode.run(user_obj, decode.field("username", decode.string, decode.success)) {
                    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to unmarshal user data"))
                    Ok(username) -> {
                      let id = gluid.guidv4()
                      let art =
                        dynamic.properties([
                          #(dynamic.string("struct_version"), dynamic.int(0)),
                          #(dynamic.string("id"), dynamic.string(id)),
                          #(dynamic.string("slug"), dynamic.string(id)),
                          #(dynamic.string("title"), dynamic.string("new article")),
                          #(dynamic.string("subtitle"), dynamic.string("")),
                          #(dynamic.string("leading"), dynamic.string("One paragraph summary/ eyecatching synopsis.")),
                          #(dynamic.string("author"), dynamic.string(username)),
                          #(dynamic.string("published_at"), dynamic.int(0)),
                          #(dynamic.string("tags"), dynamic.list([dynamic.string("new")])),
                          #(dynamic.string("content"), dynamic.string("no content yet")),
                        ])

                      case json.encode_dynamic(art) {
                        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to Create new article in repo"))
                        Ok(art_bits) ->
                          case enats.kv_put_bits(nc, kv_article, id, art_bits) {
                            Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to Create new article in repo"))
                            Ok(_) ->
                              new(200)
                              |> cors(req)
                              |> response.set_header("content-type", "application/json")
                              |> response.set_body(ewe.BitsData(art_bits))
                          }
                      }
                    }
                  }
              }
          }
      }
    }
  }
}

type ArticleUpdateBody {
  ArticleUpdateBody(
    revision: Int,
    slug: String,
    title: String,
    subtitle: String,
    leading: String,
    author: String,
    published_at: Int,
    tags: List(String),
    content: String,
  )
}

fn article_update_decoder() -> decode.Decoder(ArticleUpdateBody) {
  use rev <- decode.optional_field("revision", 0, decode.int)
  use slug <- decode.field("slug", decode.string)
  use title <- decode.field("title", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)
  use leading <- decode.field("leading", decode.string)
  use author <- decode.field("author", decode.string)
  use published_at <- decode.field("published_at", decode.int)
  use tags <- decode.field("tags", decode.list(decode.string))
  use content <- decode.optional_field("content", "", decode.string)
  decode.success(ArticleUpdateBody(
    revision: rev,
    slug: slug,
    title: title,
    subtitle: subtitle,
    leading: leading,
    author: author,
    published_at: published_at,
    tags: tags,
    content: content,
  ))
}

fn handle_article_update(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case is_uuidish(id) {
    False -> new(400) |> cors(req) |> response.set_body(ewe.TextData("failed to parse id"))
    True ->
      case require_permission(req, jwt_secret, perm_post_edit_any) {
        Error(r) -> r
        Ok(_) ->
          case enats.kv_get_value(nc, kv_article, id) {
            enats.KvNotFound -> new(404) |> cors(req) |> response.set_body(ewe.TextData("article not found"))
            enats.KvDeleted -> new(404) |> cors(req) |> response.set_body(ewe.TextData("article not found"))
            enats.KvError(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to get current article"))
            enats.KvFound(value: _, rev: _) -> {
              case ewe.read_body(req, 1024 * 1024) {
                Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("Invalid request body"))
                Ok(req2) ->
                  case json.decode_bits(req2.body) {
                    Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("Invalid request body"))
                    Ok(obj) ->
                      case decode.run(obj, article_update_decoder()) {
                        Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("Invalid request body"))
                        Ok(a) -> {
                          let out =
                            dynamic.properties([
                              #(dynamic.string("struct_version"), dynamic.int(1)),
                              #(dynamic.string("id"), dynamic.string(id)),
                              #(dynamic.string("revision"), dynamic.int(a.revision)),
                              #(dynamic.string("slug"), dynamic.string(a.slug)),
                              #(dynamic.string("title"), dynamic.string(a.title)),
                              #(dynamic.string("subtitle"), dynamic.string(a.subtitle)),
                              #(dynamic.string("leading"), dynamic.string(a.leading)),
                              #(dynamic.string("author"), dynamic.string(a.author)),
                              #(dynamic.string("published_at"), dynamic.int(a.published_at)),
                              #(dynamic.string("tags"), dynamic.list(a.tags |> list.map(dynamic.string))),
                              #(dynamic.string("content"), dynamic.string(a.content)),
                            ])

                          case json.encode_dynamic(out) {
                            Error(_) ->
                              new(500)
                              |> cors(req)
                              |> response.set_body(ewe.TextData("failed to save article in repo"))
                            Ok(bits) ->
                              case enats.kv_put_bits(nc, kv_article, id, bits) {
                                Error(e) ->
                                  new(500)
                                  |> cors(req)
                                  |> response.set_body(ewe.TextData("failed to save article in repo: " <> e))
                                Ok(_) ->
                                  new(200)
                                  |> cors(req)
                                  |> response.set_header("content-type", "application/json")
                                  |> response.set_body(ewe.BitsData(bits))
                              }
                          }
                        }
                      }
                  }
              }
            }
          }
      }
  }
}

fn handle_article_delete(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case is_uuidish(id) {
    False -> new(400) |> cors(req) |> response.set_body(ewe.TextData("failed to parse id"))
    True ->
      case require_permission(req, jwt_secret, perm_post_edit_any) {
        Error(r) -> r
        Ok(_) ->
          case enats.kv_delete(nc, kv_article, id) {
            Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to delete article"))
            Ok(_) ->
              new(200)
              |> cors(req)
              |> response.set_header("content-type", "application/json")
              |> response.set_body(ewe.TextData("\"deleted\""))
          }
      }
  }
}

fn handle_article_revisions(req: ewe.Request, nc: enats.Conn, id: String) -> ewe.Response {
  case is_uuidish(id) {
    False -> new(400) |> cors(req) |> response.set_body(ewe.TextData("failed to parse id"))
    True ->
      case enats.kv_history_values(nc, kv_article, id) {
        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to get article revisions"))
        Ok(values) -> {
          let decoded =
            values
            |> list.filter_map(fn(v) {
              case json.decode_bits(v) {
                Ok(obj) -> Ok(obj)
                Error(_) -> Error(Nil)
              }
            })
          new(200)
          |> cors(req)
          |> json_response(dynamic.list(decoded), _)
        }
      }
  }
}

fn handle_article_revision(req: ewe.Request, nc: enats.Conn, id: String) -> ewe.Response {
  // Matches Go bug: ignores revision param, returns latest.
  handle_article_get(req, nc, id)
}

// --- Short URLs ---------------------------------------------------------------

const subj_shorturl_group = "svc.shorturl.urls"

fn handle_short_url_list(req: ewe.Request, nc: enats.Conn) -> ewe.Response {
  let query = request.get_query(req) |> result.unwrap([])
  let created_by = query_get(query, "createdBy") |> option.unwrap("")
  let limit = query_get(query, "limit") |> option.map(parse_int_default(_, 50)) |> option.unwrap(50)
  let offset = query_get(query, "offset") |> option.map(parse_int_default(_, 0)) |> option.unwrap(0)

  let payload =
    dynamic.properties([
      #(dynamic.string("createdBy"), dynamic.string(created_by)),
      #(dynamic.string("limit"), dynamic.int(limit)),
      #(dynamic.string("offset"), dynamic.int(offset)),
    ])
    |> json.encode_dynamic

  case payload {
    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
    Ok(bits) ->
      case enats.request(nc, subj_shorturl_group <> ".list", bits, 4_000) {
        Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while requesting short urls"))
        Ok(reply) ->
          new(200)
          |> cors(req)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(ewe.BitsData(reply.payload))
      }
  }
}

fn handle_short_url_create(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  case ewe.read_body(req, 1024 * 1024) {
    Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
    Ok(req2) ->
      case json.decode_bits(req2.body) {
        Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
        Ok(obj) ->
          case decode.run(obj, short_url_create_decoder()) {
            Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
            Ok(body) -> {
              case body.target_url == "" {
                True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("target URL is required"))
                False -> {
                  let created_by =
                    case auth_claims(req, jwt_secret) {
                      Some(c) -> c.subject
                      None -> ""
                    }

                  let out =
                    dynamic.properties([
                      #(dynamic.string("shortCode"), dynamic.string(body.short_code)),
                      #(dynamic.string("targetUrl"), dynamic.string(body.target_url)),
                      #(dynamic.string("createdBy"), dynamic.string(created_by)),
                    ])
                    |> json.encode_dynamic

                  case out {
                    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
                    Ok(bits) ->
                      case enats.request(nc, subj_shorturl_group <> ".create", bits, 4_000) {
                        Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while creating short url"))
                        Ok(reply) ->
                          case header_get(reply.headers, "Nats-Service-Error") {
                            Some(_) -> {
                              let code = header_get(reply.headers, "Nats-Service-Error-Code") |> option.unwrap("")
                              case code {
                                "SHORT_CODE_TAKEN" -> new(409) |> cors(req) |> response.set_body(ewe.TextData("short code already exists"))
                                "INVALID_REQUEST" -> new(400) |> cors(req) |> response.set_body(ewe.TextData(bit_array.to_string(reply.payload) |> result.unwrap("")))
                                _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("service error"))
                              }
                            }
                            None ->
                              new(201)
                              |> cors(req)
                              |> response.set_header("content-type", "application/json")
                              |> response.set_body(ewe.BitsData(reply.payload))
                          }
                      }
                  }
                }
              }
            }
          }
      }
  }
}

type ShortUrlCreateBody {
  ShortUrlCreateBody(short_code: String, target_url: String)
}

fn short_url_create_decoder() -> decode.Decoder(ShortUrlCreateBody) {
  use short_code <- decode.optional_field("shortCode", "", decode.string)
  use target_url <- decode.optional_field("targetUrl", "", decode.string)
  decode.success(ShortUrlCreateBody(short_code: short_code, target_url: target_url))
}

fn handle_short_url_get(req: ewe.Request, nc: enats.Conn, id: String) -> ewe.Response {
  case id == "" {
    True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("id is required"))
    False -> {
      let out =
        dynamic.properties([#(dynamic.string("id"), dynamic.string(id))])
        |> json.encode_dynamic
      case out {
        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
        Ok(bits) ->
          case enats.request(nc, subj_shorturl_group <> ".get", bits, 4_000) {
            Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while fetching short url"))
            Ok(reply) ->
              case header_get(reply.headers, "Nats-Service-Error") {
                Some(_) ->
                  case header_get(reply.headers, "Nats-Service-Error-Code") {
                    Some("NOT_FOUND") -> new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
                    _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("service error"))
                  }
                None ->
                  new(200)
                  |> cors(req)
                  |> response.set_header("content-type", "application/json")
                  |> response.set_body(ewe.BitsData(reply.payload))
              }
          }
      }
    }
  }
}

type ShortUrlUpdateBody {
  ShortUrlUpdateBody(short_code: Option(String), target_url: Option(String), is_active: Option(Bool))
}

fn short_url_update_decoder() -> decode.Decoder(ShortUrlUpdateBody) {
  use short_code <- decode.optional_field("shortCode", None, decode.optional(decode.string))
  use target_url <- decode.optional_field("targetUrl", None, decode.optional(decode.string))
  use is_active <- decode.optional_field("isActive", None, decode.optional(decode.bool))
  decode.success(ShortUrlUpdateBody(short_code: short_code, target_url: target_url, is_active: is_active))
}

fn handle_short_url_update(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case require_auth(req, jwt_secret) {
    Error(r) -> r
    Ok(_) ->
      case id == "" {
        True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("id is required"))
        False ->
          case ewe.read_body(req, 1024 * 1024) {
            Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
            Ok(req2) ->
              case json.decode_bits(req2.body) {
                Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
                Ok(obj) ->
                  case decode.run(obj, short_url_update_decoder()) {
                    Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
                    Ok(body) -> {
                      let out =
                        dynamic.properties([
                          #(dynamic.string("id"), dynamic.string(id)),
                          #(dynamic.string("shortCode"), maybe_string(body.short_code)),
                          #(dynamic.string("targetUrl"), maybe_string(body.target_url)),
                          #(dynamic.string("isActive"), maybe_bool(body.is_active)),
                        ])
                        |> json.encode_dynamic

                      case out {
                        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
                        Ok(bits) ->
                          case enats.request(nc, subj_shorturl_group <> ".update", bits, 4_000) {
                            Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while updating short url"))
                            Ok(reply) ->
                              case header_get(reply.headers, "Nats-Service-Error") {
                                Some(_) ->
                                  case header_get(reply.headers, "Nats-Service-Error-Code") {
                                    Some("NOT_FOUND") -> new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
                                    Some("SHORT_CODE_TAKEN") -> new(409) |> cors(req) |> response.set_body(ewe.TextData("short code already exists"))
                                    Some("INVALID_REQUEST") -> new(400) |> cors(req) |> response.set_body(ewe.TextData(bit_array.to_string(reply.payload) |> result.unwrap("")))
                                    _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("service error"))
                                  }
                                None ->
                                  new(200)
                                  |> cors(req)
                                  |> response.set_header("content-type", "application/json")
                                  |> response.set_body(ewe.BitsData(reply.payload))
                              }
                          }
                      }
                    }
                  }
              }
          }
      }
  }
}

fn handle_short_url_delete(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray, id: String) -> ewe.Response {
  case require_auth(req, jwt_secret) {
    Error(r) -> r
    Ok(_) ->
      case id == "" {
        True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("id is required"))
        False -> {
          let out = dynamic.properties([#(dynamic.string("id"), dynamic.string(id))]) |> json.encode_dynamic
          case out {
            Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
            Ok(bits) ->
              case enats.request(nc, subj_shorturl_group <> ".delete", bits, 4_000) {
                Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while deleting short url"))
                Ok(reply) ->
                  case header_get(reply.headers, "Nats-Service-Error") {
                    Some(_) ->
                      case header_get(reply.headers, "Nats-Service-Error-Code") {
                        Some("NOT_FOUND") -> new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
                        _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("service error"))
                      }
                    None ->
                      new(200)
                      |> cors(req)
                      |> response.set_header("content-type", "application/json")
                      |> response.set_body(ewe.BitsData(reply.payload))
                  }
              }
          }
        }
      }
  }
}

fn handle_short_url_redirect(req: ewe.Request, nc: enats.Conn, short_code: String) -> ewe.Response {
  case short_code == "" {
    True -> new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
    False -> {
      let out = dynamic.properties([#(dynamic.string("shortCode"), dynamic.string(short_code))]) |> json.encode_dynamic
      case out {
        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
        Ok(bits) ->
          case enats.request(nc, subj_shorturl_group <> ".get", bits, 4_000) {
            Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while fetching short url"))
            Ok(reply) ->
              case header_get(reply.headers, "Nats-Service-Error") {
                Some(_) ->
                  case header_get(reply.headers, "Nats-Service-Error-Code") {
                    Some("NOT_FOUND") -> new(404) |> cors(req) |> response.set_body(ewe.TextData("not found"))
                    _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("service error"))
                  }
                None -> {
                  case json.decode_bits(reply.payload) {
                    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to parse response"))
                    Ok(obj) ->
                      case decode.run(obj, decode.field("targetUrl", decode.string, decode.success)) {
                        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to parse response"))
                        Ok(target_url) ->
                          case decode.run(obj, decode.field("isActive", decode.bool, decode.success)) {
                            Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to parse response"))
                            Ok(is_active) ->
                              case is_active {
                                False -> new(410) |> cors(req) |> response.set_body(ewe.TextData("short URL is inactive"))
                                True -> {
                                  // fire-and-forget access tracking
                                  // Best-effort: we don't block the redirect on access tracking.
                                  // (In Go this is done in a goroutine.)
                                  let _ =
                                    case json.encode_dynamic(dynamic.properties([#(dynamic.string("shortCode"), dynamic.string(short_code))])) {
                                      Ok(b) -> enats.request(nc, subj_shorturl_group <> ".access", b, 4_000)
                                      Error(_) -> Error(enats.RequestError(reason: "encode"))
                                    }

                                  new(301)
                                  |> cors(req)
                                  |> response.set_header("location", target_url)
                                  |> response.set_body(ewe.TextData(""))
                                }
                              }
                          }
                      }
                  }
                }
              }
          }
      }
    }
  }
}

fn parse_int_default(s: String, default: Int) -> Int {
  case int.parse(s) {
    Ok(i) -> i
    Error(_) -> default
  }
}

fn query_get(query: List(#(String, String)), key: String) -> Option(String) {
  case list.find(query, fn(p) { p.0 == key }) {
    Ok(p) -> Some(p.1)
    Error(_) -> None
  }
}

fn maybe_bool(v: Option(Bool)) -> dynamic.Dynamic {
  case v {
    None -> dynamic.nil()
    Some(b) -> dynamic.bool(b)
  }
}

// --- Notifications ------------------------------------------------------------

fn handle_notification_send(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  case ewe.read_body(req, 1024 * 1024) {
    Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
    Ok(req2) ->
      case json.decode_bits(req2.body) {
        Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
        Ok(obj) ->
          case decode.run(obj, decode.field("message", decode.string, decode.success)) {
            Error(_) -> new(400) |> cors(req) |> response.set_body(ewe.TextData("invalid request body"))
            Ok(message) ->
              case message == "" {
                True -> new(400) |> cors(req) |> response.set_body(ewe.TextData("message is required"))
                False -> {
                  // user defaults
                  let #(user_id, username) =
                    case auth_claims(req, jwt_secret) {
                      None -> #("-", "guest")
                      Some(c) -> #(c.subject, "guest")
                    }

                  // If authenticated, fetch username from who
                  let #(user_id2, username2) =
                    case user_id == "-" {
                      True -> #(user_id, username)
                      False ->
                        case json.encode_dynamic(dynamic.properties([#(dynamic.string("id"), dynamic.string(user_id))])) {
                          Error(_) -> #(user_id, username)
                          Ok(bits) ->
                            case enats.request(nc, "svc.who.users.get", bits, 4_000) {
                              Error(_) -> #(user_id, username)
                              Ok(reply) ->
                                case json.decode_bits(reply.payload) {
                                  Error(_) -> #(user_id, username)
                                  Ok(uobj) ->
                                    case decode.run(uobj, decode.field("username", decode.string, decode.success)) {
                                      Ok(u) -> #(user_id, u)
                                      Error(_) -> #(user_id, username)
                                    }
                                }
                            }
                        }
                    }

                  let notification_id = gluid.guidv4()
                  let notification =
                    dynamic.properties([
                      #(dynamic.string("id"), dynamic.string(notification_id)),
                      #(dynamic.string("user_id"), dynamic.string(user_id2)),
                      #(dynamic.string("title"), dynamic.string(username2 <> "@jst.dev")),
                      #(dynamic.string("message"), dynamic.string(message)),
                      #(dynamic.string("category"), dynamic.string("jst.dev")),
                      #(dynamic.string("priority"), dynamic.string("normal")),
                      #(dynamic.string("ntfy_topic"), dynamic.string("jst")),
                      #(dynamic.string("data"), dynamic.properties([])),
                    ])

                  case json.encode_dynamic(notification) {
                    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("internal server error"))
                    Ok(bits) ->
                      case enats.request(nc, "ntfy.notification", bits, 4_000) {
                        Error(_) -> new(504) |> cors(req) |> response.set_body(ewe.TextData("gateway timeout while sending notification"))
                        Ok(reply) ->
                          case header_get(reply.headers, "Nats-Service-Error") {
                            Some(_) ->
                              case header_get(reply.headers, "Nats-Service-Error-Code") {
                                Some("400") -> new(400) |> cors(req) |> response.set_body(ewe.TextData(bit_array.to_string(reply.payload) |> result.unwrap("")))
                                _ -> new(500) |> cors(req) |> response.set_body(ewe.TextData("notification service error"))
                              }
                            None ->
                              new(200)
                              |> cors(req)
                              |> json_response(
                                dynamic.properties([
                                  #(dynamic.string("status"), dynamic.string("success")),
                                  #(dynamic.string("message"), dynamic.string("Notification sent successfully")),
                                  #(dynamic.string("id"), dynamic.string(notification_id)),
                                ]),
                                _,
                              )
                          }
                      }
                  }
                }
              }
          }
      }
  }
}

// --- Chat request -------------------------------------------------------------

const kv_convo_room = "convo_room"

fn handle_chat_request(req: ewe.Request, nc: enats.Conn) -> ewe.Response {
  let room_id = gluid.guidv4()
  let room =
    dynamic.properties([
      #(dynamic.string("id"), dynamic.string(room_id)),
      #(dynamic.string("name"), dynamic.string("Chat Request")),
      #(dynamic.string("public"), dynamic.bool(True)),
      #(dynamic.string("users"), dynamic.list([])),
    ])

  case json.encode_dynamic(room) {
    Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to create room"))
    Ok(room_bits) ->
      case enats.kv_put_bits(nc, kv_convo_room, room_id, room_bits) {
        Error(_) -> new(500) |> cors(req) |> response.set_body(ewe.TextData("failed to create room"))
        Ok(_) -> {
          let notification_id = gluid.guidv4()
          let notification =
            dynamic.properties([
              #(dynamic.string("id"), dynamic.string(notification_id)),
              #(dynamic.string("user_id"), dynamic.string("")),
              #(dynamic.string("title"), dynamic.string("New Chat Request")),
              #(dynamic.string("message"), dynamic.string("New chat request: https://jst.dev/chat/" <> room_id)),
              #(dynamic.string("category"), dynamic.string("jst.dev")),
              #(dynamic.string("priority"), dynamic.string("high")),
              #(dynamic.string("ntfy_topic"), dynamic.string("jst")),
              #(dynamic.string("data"), dynamic.properties([#(dynamic.string("room_id"), dynamic.string(room_id))])),
            ])

          let _ =
            case json.encode_dynamic(notification) {
              Ok(bits) -> enats.request(nc, "ntfy.notification", bits, 4_000)
              Error(_) -> Error(enats.RequestError(reason: "encode"))
            }

          new(200)
          |> cors(req)
          |> json_response(dynamic.properties([#(dynamic.string("room_id"), dynamic.string(room_id))]), _)
        }
      }
  }
}

