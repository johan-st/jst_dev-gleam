import gleam/bytes_tree
import gleam/erlang/atom
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import gleam/string

import jst_server/config.{type Config}
import jst_server/db
import jst_server/pubsub.{type PubSub}
import jst_server/ws

import mist
import sqlight.{type Connection}

const static_dir = "priv/static"

pub fn start(conn: Connection, pubsub: PubSub, conf: Config) {
  let handler = fn(req: request.Request(mist.Connection)) -> response.Response(
    mist.ResponseData,
  ) {
    case request.path_segments(req) {
      // WebSocket endpoint
      ["omni-ws"] -> ws.websocket(conn, pubsub, req, conf)

      // Short URL redirect
      ["u", short_code] -> redirect_short_url(conn, short_code)

      // Static files under /priv/static/
      ["priv", "static", ..rest] -> serve_static(rest)

      // Favicon at root
      ["favicon.svg"] -> serve_file("favicon.svg")
      ["favicon.ico"] -> serve_file("favicon.ico")

      // SPA: serve index.html for all other routes
      _ -> serve_file("index.html")
    }
  }

  let assert Ok(_) =
    handler
    |> mist.new
    |> mist.port(conf.port)
    |> mist.bind("0.0.0.0")
    |> mist.start
}

fn serve_static(path_parts: List(String)) -> response.Response(mist.ResponseData) {
  let filename = string.join(path_parts, "/")
  serve_file(filename)
}

fn serve_file(filename: String) -> response.Response(mist.ResponseData) {
  let path = static_dir <> "/" <> filename

  case read_file(path) {
    Ok(contents) -> {
      let content_type = get_content_type(filename)
      response.new(200)
      |> response.prepend_header("content-type", content_type)
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(contents)))
    }
    Error(_) -> not_found()
  }
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
}

fn get_content_type(filename: String) -> String {
  let ext =
    filename
    |> string.split(".")
    |> list.last
    |> result.unwrap("")
    |> string.lowercase

  case ext {
    "html" -> "text/html; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "js" -> "application/javascript; charset=utf-8"
    "mjs" -> "application/javascript; charset=utf-8"
    "json" -> "application/json; charset=utf-8"
    "svg" -> "image/svg+xml"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "ico" -> "image/x-icon"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    _ -> "application/octet-stream"
  }
}

fn redirect_short_url(
  conn: Connection,
  short_code: String,
) -> response.Response(mist.ResponseData) {
  let now = now_unix_seconds()

  case db.get_short_url_by_code(conn, short_code) {
    Ok(option.Some(url)) -> {
      let _ = db.increment_short_url_access(conn, url.id, now)
      response.new(302)
      |> response.set_header("location", url.target_url)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    _ -> not_found()
  }
}

fn now_unix_seconds() -> Int {
  system_time(atom.create("second"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int

@external(erlang, "jst_server_file_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)
