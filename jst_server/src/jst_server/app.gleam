import ewe
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/int
import gleam/bit_array
import gleam/option.{None, Some}

import jst_server/env
import jst_server/http_server
import jst_server/nats/enats

pub fn start() -> Nil {
  let port =
    case env.get("PORT") {
      Some(p) -> parse_int(p, default: 8080)
      None -> 8080
    }

  let static_dir =
    case env.get("JST_STATIC_DIR") {
      Some(dir) -> dir
      None ->
        case decode.run(find_static_dir(), decode.string) {
          Ok(dir) -> dir
          Error(_) -> "./build"
        }
    }
  io.println("static_dir=" <> static_dir)

  let nats_jwt = env_required("NATS_JWT")
  let nats_nkey = env_required("NATS_NKEY")
  let jwt_secret = env_required("JWT_SECRET")

  let nc =
    case enats.connect(
      host: "connect.ngs.global",
      port: 4222,
      tls_required: True,
      jwt: nats_jwt,
      nkey_seed: nats_nkey,
    ) {
      Ok(conn) -> conn
      Error(e) -> crash("NATS connect failed: " <> e.reason)
    }

  let builder =
    ewe.new(fn(req) {
      http_server.handler(req, static_dir, nc, bit_array.from_string(jwt_secret))
    })
    |> ewe.bind_all()
    |> ewe.listening(port)

  // Start server (supervisor) and keep the main process alive.
  let _started = ewe.start(builder)
  process.sleep_forever()
}

fn env_required(key: String) -> String {
  case env.get(key) {
    Some(v) -> v
    None -> crash("missing env var: " <> key)
  }
}

fn parse_int(s: String, default default_: Int) -> Int {
  case int.parse(s) {
    Ok(i) -> i
    Error(_) -> default_
  }
}

@external(erlang, "jst_server_ffi", "find_static_dir")
fn find_static_dir() -> dynamic.Dynamic

@external(erlang, "jst_server_ffi", "crash")
fn crash(message: String) -> a


