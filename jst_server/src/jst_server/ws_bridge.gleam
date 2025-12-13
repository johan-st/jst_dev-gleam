import ewe
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/result

import jst_server/json
import jst_server/nats/enats

pub fn handle_ws(req: ewe.Request, nc: enats.Conn, jwt_secret: BitArray) -> ewe.Response {
  // NOTE: Capability gating is implemented in Go; we'll restore it here next.
  // For now we allow the same subjects/buckets as authorizeInitial in Go.
  let _ = jwt_secret

  ewe.upgrade_websocket(
    req,
    on_init: fn(_conn, selector) {
      let events = process.new_subject()
      let selector = selector |> process.select(events)

      let worker =
        process.spawn_unlinked(fn() {
          worker_loop(nc, events)
        })

      #(State(events: events, worker: worker), selector)
    },
    handler: fn(conn, state, msg) {
      case msg {
        ewe.Text(text) -> {
          // Parse client command and send it to worker.
          let cmd = parse_client_cmd(text)
          case cmd {
            Ok(c) -> {
              let _ = send_any(state.worker, c)
              ewe.websocket_continue(state)
            }
            Error(_) -> {
              let _ = ewe.send_text_frame(conn, "{\"op\":\"error\",\"data\":{\"reason\":\"bad json\"}}")
              ewe.websocket_continue(state)
            }
          }
        }
        ewe.User(outgoing_json) -> {
          let _ = ewe.send_text_frame(conn, outgoing_json)
          ewe.websocket_continue(state)
        }
        _ -> ewe.websocket_continue(state)
      }
    },
    on_close: fn(_conn, state) {
      // Stop worker (best-effort).
      process.kill(state.worker)
      Nil
    },
  )
}

type State {
  State(events: process.Subject(String), worker: process.Pid)
}

// Worker receives:
// - cmd tuples from websocket process
// - NATS messages from enats subscriptions
// - KV watch messages
fn worker_loop(nc: enats.Conn, events: process.Subject(String)) -> Nil {
  worker_loop_inner(nc, events, [], [])
}

type Sub {
  Sub(subject: String, sid: Int)
}

type Watch {
  Watch(bucket: String, pid: process.Pid)
}

fn worker_loop_inner(nc: enats.Conn, events: process.Subject(String), subs: List(Sub), kv: List(Watch)) -> Nil {
  case recv_any(50) {
    Error(_) -> worker_loop_inner(nc, events, subs, kv)
    Ok(msg) -> {
      case decode.run(msg, cmd_decoder()) {
        Ok(cmd) -> {
          let #(subs2, kv2) = handle_cmd(nc, events, cmd, subs, kv)
          worker_loop_inner(nc, events, subs2, kv2)
        }
        Error(_) -> {
          // NATS sub message?
          case decode.run(msg, nats_msg_decoder()) {
            Ok(#(subject, payload)) -> {
              let out =
                server_msg(
                  "sub_msg",
                  subject,
                  dynamic.bit_array(payload),
                )
              process.send(events, out)
              worker_loop_inner(nc, events, subs, kv)
            }
            Error(_) -> {
              // KV watch message?
              case decode.run(msg, kv_event_decoder()) {
                Ok(KvInitDone(pid)) -> {
                  case bucket_for_watch(kv, pid) {
                    Ok(bucket) -> process.send(events, kv_in_sync_msg(bucket))
                    Error(_) -> Nil
                  }
                  worker_loop_inner(nc, events, subs, kv)
                }
                Ok(KvPut(pid, key, value)) -> {
                  case bucket_for_watch(kv, pid) {
                    Ok(bucket) -> process.send(events, kv_put_msg(bucket, key, value))
                    Error(_) -> Nil
                  }
                  worker_loop_inner(nc, events, subs, kv)
                }
                Error(_) -> worker_loop_inner(nc, events, subs, kv)
              }
            }
          }
        }
      }
    }
  }
}

type Cmd {
  Cmd(op: String, target: String, data: dynamic.Dynamic)
}

fn handle_cmd(
  nc: enats.Conn,
  events: process.Subject(String),
  cmd: Cmd,
  subs: List(Sub),
  kv: List(Watch),
) -> #(List(Sub), List(Watch)) {
  let _ = events
  case cmd.op {
    "sub" -> {
      let subject = cmd.target
      case list.any(subs, fn(s) { s.subject == subject }) {
        True -> #(subs, kv)
        False ->
          case enats.sub(nc, subject) {
            Ok(sid) -> #([Sub(subject: subject, sid: sid), ..subs], kv)
            Error(_) -> #(subs, kv)
          }
      }
    }
    "unsub" -> {
      let target = cmd.target
      let subs2 =
        subs
        |> list.filter(fn(s) {
          case s.subject == target {
            True -> {
              let _ = enats.unsub(nc, s.sid)
              False
            }
            False -> True
          }
        })

      let kv2 =
        kv
        |> list.filter(fn(w) {
          case w.bucket == target {
            True -> {
              process.kill(w.pid)
              False
            }
            False -> True
          }
        })

      #(subs2, kv2)
    }
    "kv_sub" -> {
      let bucket = cmd.target
      let pattern =
        decode.run(cmd.data, decode.optional_field("pattern", "", decode.string, decode.success))
        |> result.unwrap("")

      let filter =
        decode.run(cmd.data, decode.optional_field("filter", "", decode.string, decode.success))
        |> result.unwrap("")

      let keys = case pattern == "" { True -> filter False -> pattern }
      let keys = case keys == "" { True -> ">" False -> keys }

      case enats.kv_watch(nc, bucket, keys) {
        Ok(enats.Watch(pid)) -> {
          // init_done will produce in_sync for this bucket via KvInitDone(pid).
          #(subs, [Watch(bucket: bucket, pid: pid), ..kv])
        }
        Error(_) -> #(subs, kv)
      }
    }
    _ -> #(subs, kv)
  }
}

fn parse_client_cmd(text: String) -> Result(dynamic.Dynamic, Nil) {
  json.decode_bits(bit_array.from_string(text))
  |> result.map_error(fn(_) { Nil })
}

fn cmd_decoder() -> decode.Decoder(Cmd) {
  use op <- decode.field("op", decode.string)
  use target <- decode.field("target", decode.string)
  use data <- decode.optional_field("data", dynamic.properties([]), decode.dynamic)
  decode.success(Cmd(op: op, target: target, data: data))
}

fn server_msg(op: String, target: String, data: dynamic.Dynamic) -> String {
  let body =
    dynamic.properties([
      #(dynamic.string("op"), dynamic.string(op)),
      #(dynamic.string("target"), dynamic.string(target)),
      #(dynamic.string("data"), data),
    ])

  case json.encode_dynamic(body) {
    Ok(bits) -> bit_array.to_string(bits) |> result.unwrap("{}")
    Error(_) -> "{}"
  }
}

fn kv_put_msg(bucket: String, key: String, value: String) -> String {
  let inner =
    dynamic.properties([
      #(dynamic.string("op"), dynamic.string("put")),
      #(dynamic.string("rev"), dynamic.int(0)),
      #(dynamic.string("key"), dynamic.string(key)),
      #(dynamic.string("value"), dynamic.string(value)),
    ])
  server_msg("kv_msg", bucket, inner)
}

fn kv_in_sync_msg(bucket: String) -> String {
  let inner =
    dynamic.properties([
      #(dynamic.string("op"), dynamic.string("in_sync")),
      #(dynamic.string("rev"), dynamic.int(0)),
    ])
  server_msg("kv_msg", bucket, inner)
}

fn nats_msg_decoder() -> decode.Decoder(#(String, BitArray)) {
  // {ConnPid, Sid, {msg, Subject, Body, _Opts}}
  use _ <- decode.subfield([0], decode.dynamic)
  use _ <- decode.subfield([1], decode.int)
  use tag <- decode.subfield([2, 0], atom.decoder())
  case atom.to_string(tag) {
    "msg" -> {
      use subject <- decode.subfield([2, 1], decode.string)
      use body <- decode.subfield([2, 2], decode.bit_array)
      decode.success(#(subject, body))
    }
    _ -> decode.failure(#("", <<>>), "unexpected message tag")
  }
}

type KvEvent {
  KvInitDone(process.Pid)
  KvPut(process.Pid, String, String)
}

fn kv_event_decoder() -> decode.Decoder(KvEvent) {
  // {init_done, WatchPid, ConnPid} OR {'WATCH', WatchPid, ConnPid, {msg, Key, Value, Opts}}
  decode.one_of(kv_init_done_decoder(), or: [kv_watch_msg_decoder()])
}

fn kv_init_done_decoder() -> decode.Decoder(KvEvent) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "init_done" -> {
      use pid <- decode.subfield([1], pid_decoder())
      decode.success(KvInitDone(pid))
    }
    _ -> decode.failure(KvInitDone(process.self()), "not init_done")
  }
}

fn kv_watch_msg_decoder() -> decode.Decoder(KvEvent) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "WATCH" -> {
      use pid <- decode.subfield([1], pid_decoder())
      use _ <- decode.subfield([2], decode.dynamic)
      use inner_tag <- decode.subfield([3, 0], atom.decoder())
      case atom.to_string(inner_tag) {
        "msg" -> {
          use key <- decode.subfield([3, 1], decode.string)
          // Value is often a string; decode as string best-effort.
          use value <- decode.subfield([3, 2], decode.string)
          decode.success(KvPut(pid, key, value))
        }
        _ -> decode.failure(KvInitDone(process.self()), "unexpected kv msg tag")
      }
    }
    _ -> decode.failure(KvInitDone(process.self()), "unexpected watch tag")
  }
}

fn bucket_for_watch(kv: List(Watch), pid: process.Pid) -> Result(String, Nil) {
  case list.find(kv, fn(w) { w.pid == pid }) {
    Ok(w) -> Ok(w.bucket)
    Error(_) -> Error(Nil)
  }
}

fn pid_decoder() -> decode.Decoder(process.Pid) {
  decode.new_primitive_decoder("Pid", fn(data) {
    case is_pid(data) {
      True -> Ok(pid_from_dynamic(data))
      False -> Error(process.self())
    }
  })
}

@external(erlang, "jst_server_ffi", "recv_any")
fn recv_any(timeout_ms: Int) -> Result(dynamic.Dynamic, Nil)

@external(erlang, "jst_server_ffi", "send_any")
fn send_any(pid: process.Pid, msg: dynamic.Dynamic) -> Nil

@external(erlang, "erlang", "is_pid")
fn is_pid(data: dynamic.Dynamic) -> Bool

@external(erlang, "gleam_erlang_ffi", "identity")
fn pid_from_dynamic(data: dynamic.Dynamic) -> process.Pid

