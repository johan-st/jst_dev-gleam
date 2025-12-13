import gleeunit
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/option.{None, Some}

import jst_server/env
import jst_server/nats/enats

pub fn main() {
  gleeunit.main()
}

pub fn nats_pubsub_spike_test() {
  // Env-gated so the test suite passes without a running NATS server.
  case env.get("JST_TEST_NATS_HOST") {
    None -> Nil
    Some(host) -> {
      let port =
        case env.get("JST_TEST_NATS_PORT") {
          Some(p) -> int_from_string(p, default: 4222)
          None -> 4222
        }

      let conn =
        enats.connect(
          host: host,
          port: port,
          tls_required: False,
          jwt: "",
          nkey_seed: "",
        )
        |> unwrap_ok

      let _sid = enats.sub(conn, "spike.test") |> unwrap_ok
      let _ = enats.publish(conn, "spike.test", "hello") |> unwrap_ok

      // enats delivers `{Conn, Sid, {msg, Subject, Body, Opts}}` to the mailbox
      // (see enats README). We just assert we got the expected body.
      let msg = recv_any(1000)
      let decoded = decode.run(msg, nats_msg_decoder())
      assert decoded == Ok(#("spike.test", "hello"))
    }
  }
}

pub fn nats_kv_watch_spike_test() {
  // Requires JetStream enabled.
  // Gate with JST_TEST_NATS_KV=1 to avoid flaky failures on environments
  // without JetStream.
  case env.get("JST_TEST_NATS_KV") {
    Some("1") -> {
      case env.get("JST_TEST_NATS_HOST") {
        None -> Nil
        Some(host) -> {
          let port =
            case env.get("JST_TEST_NATS_PORT") {
              Some(p) -> int_from_string(p, default: 4222)
              None -> 4222
            }

          let conn =
            enats.connect(
              host: host,
              port: port,
              tls_required: False,
              jwt: "",
              nkey_seed: "",
            )
            |> unwrap_ok

          // Create bucket if possible (ignore errors, it may already exist).
          let _ = enats.kv_create_bucket(conn, "spike_kv")

          let _watch = enats.kv_watch(conn, "spike_kv", ">") |> unwrap_ok
          let _ = enats.kv_put(conn, "spike_kv", "k1", "v1")

          // enats sends: `{'WATCH', WatchPid, ConnPid, {msg, Key, Value, Opts}}`
          // We only assert we see key/value.
          let msg = recv_any(2000)
          let decoded = decode.run(msg, kv_watch_decoder())
          assert decoded == Ok(#("k1", "v1"))
        }
      }
    }
    _ -> Nil
  }
}

fn int_from_string(s: String, default default_: Int) -> Int {
  case int.parse(s) {
    Ok(i) -> i
    Error(_) -> default_
  }
}

fn unwrap_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(_) -> panic
  }
}

fn recv_any(timeout_ms: Int) -> dynamic.Dynamic {
  recv_any_ffi(timeout_ms)
}

fn nats_msg_decoder() -> decode.Decoder(#(String, String)) {
  // {Conn, Sid, {msg, Subject, Body, _Opts}}
  use _ <- decode.subfield([0], decode.dynamic)
  use _ <- decode.subfield([1], decode.int)
  use tag <- decode.subfield([2, 0], atom.decoder())
  case atom.to_string(tag) {
    "msg" -> {
      use subject <- decode.subfield([2, 1], decode.string)
      use body <- decode.subfield([2, 2], decode.string)
      decode.success(#(subject, body))
    }
    _ -> decode.failure(#("", ""), "unexpected message tag")
  }
}

fn kv_watch_decoder() -> decode.Decoder(#(String, String)) {
  // {'WATCH', WatchPid, ConnPid, {msg, Key, Value, _Opts}}
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "WATCH" -> {
      use _ <- decode.subfield([1], decode.dynamic)
      use _ <- decode.subfield([2], decode.dynamic)
      use inner_tag <- decode.subfield([3, 0], atom.decoder())
      case atom.to_string(inner_tag) {
        "msg" -> {
          use key <- decode.subfield([3, 1], decode.string)
          use value <- decode.subfield([3, 2], decode.string)
          decode.success(#(key, value))
        }
        _ -> decode.failure(#("", ""), "unexpected kv msg tag")
      }
    }
    _ -> decode.failure(#("", ""), "unexpected watch tag")
  }
}

@external(erlang, "jst_server_ffi", "recv_any")
fn recv_any_ffi(timeout_ms: Int) -> dynamic.Dynamic


