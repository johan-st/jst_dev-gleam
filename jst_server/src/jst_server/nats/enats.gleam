import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/string

pub type Conn {
  Conn(pid: Pid)
}

pub type ConnectError {
  ConnectError(reason: String)
}

pub type SubscriptionId =
  Int

pub type Watch {
  Watch(pid: Pid)
}

pub type RequestError {
  RequestError(reason: String)
}

pub type Reply {
  Reply(payload: BitArray, headers: List(#(String, String)))
}

pub type KvGetResult {
  KvFound(value: BitArray, rev: Int)
  KvDeleted
  KvNotFound
  KvError(reason: String)
}

/// A tiny hint used by `jst_server.main` to ensure the dependency is wired.
pub fn version_hint() -> String {
  "enats"
}

/// Connect to NATS.
///
/// For NGS (connect.ngs.global), set `tls_required` to `True` and supply `jwt`
/// and `nkey_seed` (matching the Go server).
pub fn connect(
  host host: String,
  port port: Int,
  tls_required tls_required: Bool,
  jwt jwt: String,
  nkey_seed nkey_seed: String,
) -> Result(Conn, ConnectError) {
  // Ensure enats OTP app is started before using it.
  let _ = ensure_all_started(atom.create("enats"))

  let opts =
    dynamic.properties([
      #(atom.create("verbose") |> atom.to_dynamic, dynamic.bool(False)),
      #(atom.create("headers") |> atom.to_dynamic, dynamic.bool(True)),
      #(atom.create("no_responders") |> atom.to_dynamic, dynamic.bool(True)),
      #(atom.create("auth_required") |> atom.to_dynamic, dynamic.bool(True)),
      #(atom.create("tls_required") |> atom.to_dynamic, dynamic.bool(tls_required)),
      #(atom.create("jwt") |> atom.to_dynamic, dynamic.string(jwt)),
      #(atom.create("nkey_seed") |> atom.to_dynamic, dynamic.string(nkey_seed)),
      // NOTE: For now we rely on defaults. For production we should supply
      // tls_opts that verify the server cert (see enats README).
    ])

  case decode.run(nats_connect3(host, port, opts), ok_pid_decoder()) {
    Ok(pid) -> Ok(Conn(pid))
    Error(errors) -> Error(ConnectError("connect failed: " <> string.inspect(errors)))
  }
}

pub fn publish(conn: Conn, subject: String, payload: String) -> Result(Nil, String) {
  case decode.run(nats_pub3(conn.pid, subject, payload), atom_ok_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("publish failed")
  }
}

pub fn sub(conn: Conn, subject: String) -> Result(SubscriptionId, String) {
  case decode.run(nats_sub2(conn.pid, subject), ok_int_decoder()) {
    Ok(sid) -> Ok(sid)
    Error(_) -> Error("subscribe failed")
  }
}

pub fn unsub(conn: Conn, sid: SubscriptionId) -> Result(Nil, String) {
  case decode.run(nats_unsub2(conn.pid, sid), ok_any_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("unsubscribe failed")
  }
}

pub fn kv_create_bucket(conn: Conn, bucket: String) -> Result(Nil, String) {
  case decode.run(nats_kv_create_bucket2(conn.pid, bucket), ok_any_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("kv create bucket failed")
  }
}

pub fn kv_put(conn: Conn, bucket: String, key: String, value: String) -> Result(Nil, String) {
  case decode.run(nats_kv_put4(conn.pid, bucket, key, value), ok_any_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("kv put failed")
  }
}

pub fn kv_put_bits(conn: Conn, bucket: String, key: String, value: BitArray) -> Result(Nil, String) {
  case decode.run(nats_kv_put4_bits(conn.pid, bucket, key, value), ok_any_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("kv put failed")
  }
}

pub fn kv_delete(conn: Conn, bucket: String, key: String) -> Result(Nil, String) {
  let opts = dynamic.properties([])
  case decode.run(nats_kv_delete4(conn.pid, bucket, key, opts), ok_any_decoder()) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("kv delete failed")
  }
}

pub fn kv_list_keys(conn: Conn, bucket: String) -> Result(List(String), String) {
  case decode.run(kv_list_keys2(conn.pid, bucket), kv_list_keys_decoder()) {
    Ok(keys) -> Ok(keys)
    Error(_) -> Error("kv list keys failed")
  }
}

pub fn kv_get_value(conn: Conn, bucket: String, key: String) -> KvGetResult {
  case decode.run(kv_get_value3(conn.pid, bucket, key), kv_get_value_decoder()) {
    Ok(result) -> result
    Error(errs) -> KvError("kv get failed: " <> string.inspect(errs))
  }
}

pub fn kv_history_values(conn: Conn, bucket: String, key: String) -> Result(List(BitArray), String) {
  case decode.run(kv_select_history3(conn.pid, bucket, key), kv_history_decoder()) {
    Ok(values) -> Ok(values)
    Error(_) -> Error("kv history failed")
  }
}

/// Start a JetStream KeyValue watcher for `bucket` and `keys` pattern.
///
/// Uses the enats default watcher callback, which sends messages to the owner
/// process in the form:
/// - `{init_done, WatchPid, ConnPid}`
/// - `{'WATCH', WatchPid, ConnPid, Msg}`
pub fn kv_watch(conn: Conn, bucket: String, keys: String) -> Result(Watch, String) {
  let watch_opts =
    dynamic.properties([
      #(atom.create("owner") |> atom.to_dynamic, pid_to_dynamic(process.self())),
      // Keep defaults: include history, headers_only, etc.
    ])

  let opts = dynamic.properties([])

  case decode.run(nats_kv_watch5(conn.pid, bucket, keys, watch_opts, opts), ok_pid_decoder()) {
    Ok(pid) -> Ok(Watch(pid))
    Error(_) -> Error("kv watch failed")
  }
}

pub fn request(
  conn: Conn,
  subject: String,
  payload: BitArray,
  timeout_ms: Int,
) -> Result(Reply, RequestError) {
  let opts =
    dynamic.properties([
      #(atom.create("timeout") |> atom.to_dynamic, dynamic.int(timeout_ms)),
    ])

  case decode.run(nats_request4(conn.pid, subject, payload, opts), ok_reply_decoder()) {
    Ok(reply) -> Ok(reply)
    Error(errs) -> Error(RequestError("request failed: " <> string.inspect(errs)))
  }
}

// --- Decoders -----------------------------------------------------------------

fn ok_pid_decoder() -> decode.Decoder(Pid) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], pid_decoder(), decode.success)
    _ -> decode.failure(process.self(), "expected {ok, pid}")
  }
}

fn ok_int_decoder() -> decode.Decoder(Int) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.int, decode.success)
    _ -> decode.failure(0, "expected {ok, int}")
  }
}

fn ok_any_decoder() -> decode.Decoder(Nil) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.success(Nil)
    _ -> decode.failure(Nil, "expected {ok, _}")
  }
}

fn atom_ok_decoder() -> decode.Decoder(Nil) {
  decode.new_primitive_decoder("ok", fn(data) {
    case decode.run(data, atom.decoder()) {
      Ok(a) ->
        case atom.to_string(a) {
          "ok" -> Ok(Nil)
          _ -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

fn pid_decoder() -> decode.Decoder(Pid) {
  decode.new_primitive_decoder("Pid", fn(data) {
    case is_pid(data) {
      True -> Ok(pid_from_dynamic(data))
      False -> Error(process.self())
    }
  })
}

fn ok_reply_decoder() -> decode.Decoder(Reply) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> {
      use payload <- decode.subfield([1, 0], decode.bit_array)
      use msg_opts <- decode.subfield([1, 1], decode.dynamic)
      let headers = parse_headers_from_msg_opts(msg_opts)
      decode.success(Reply(payload: payload, headers: headers))
    }
    _ -> decode.failure(Reply(payload: <<>>, headers: []), "expected {ok, {payload, msg_opts}}")
  }
}

fn parse_headers_from_msg_opts(msg_opts: Dynamic) -> List(#(String, String)) {
  // `msg_opts` is a map. We only care about the `header` key (atom).
  // We delegate parsing to Erlang helper to avoid tricky dynamic map decoding.
  case decode.run(nats_headers_from_msg_opts(msg_opts), decode.list(header_pair_decoder())) {
    Ok(headers) -> headers
    Error(_) -> []
  }
}

fn header_pair_decoder() -> decode.Decoder(#(String, String)) {
  use k <- decode.subfield([0], decode.string)
  use v <- decode.subfield([1], decode.string)
  decode.success(#(k, v))
}

fn kv_list_keys_decoder() -> decode.Decoder(List(String)) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.list(decode.string), decode.success)
    _ -> decode.failure([], "expected {ok, [keys]}")
  }
}

fn kv_get_value_decoder() -> decode.Decoder(KvGetResult) {
  decode.one_of(kv_deleted_decoder(), or: [kv_not_found_decoder(), kv_ok_tuple_decoder()])
}

fn kv_deleted_decoder() -> decode.Decoder(KvGetResult) {
  decode.new_primitive_decoder("deleted", fn(data) {
    case decode.run(data, atom.decoder()) {
      Ok(a) ->
        case atom.to_string(a) {
          "deleted" -> Ok(KvDeleted)
          _ -> Error(KvError("not deleted"))
        }
      Error(_) -> Error(KvError("not deleted"))
    }
  })
}

fn kv_not_found_decoder() -> decode.Decoder(KvGetResult) {
  decode.new_primitive_decoder("not_found", fn(data) {
    case decode.run(data, atom.decoder()) {
      Ok(a) ->
        case atom.to_string(a) {
          "not_found" -> Ok(KvNotFound)
          _ -> Error(KvError("not not_found"))
        }
      Error(_) -> Error(KvError("not not_found"))
    }
  })
}

fn kv_ok_tuple_decoder() -> decode.Decoder(KvGetResult) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> {
      use value <- decode.subfield([1], decode.bit_array)
      use rev <- decode.subfield([2], decode.int)
      decode.success(KvFound(value: value, rev: rev))
    }
    _ -> decode.failure(KvError("not ok"), "expected {ok, value, rev}")
  }
}

fn kv_history_decoder() -> decode.Decoder(List(BitArray)) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.list(decode.bit_array), decode.success)
    _ -> decode.failure([], "expected {ok, [values]}")
  }
}

// --- Erlang interop ------------------------------------------------------------

@external(erlang, "nats", "connect")
fn nats_connect3(host: String, port: Int, opts: Dynamic) -> Dynamic

@external(erlang, "nats", "pub")
fn nats_pub3(conn: Pid, subject: String, payload: String) -> Dynamic

@external(erlang, "nats", "sub")
fn nats_sub2(conn: Pid, subject: String) -> Dynamic

@external(erlang, "nats", "unsub")
fn nats_unsub2(conn: Pid, sid: Int) -> Dynamic

@external(erlang, "nats_kv", "watch")
fn nats_kv_watch5(conn: Pid, bucket: String, keys: String, watch_opts: Dynamic, opts: Dynamic) ->
  Dynamic

@external(erlang, "nats_kv", "create_bucket")
fn nats_kv_create_bucket2(conn: Pid, bucket: String) -> Dynamic

@external(erlang, "nats_kv", "put")
fn nats_kv_put4(conn: Pid, bucket: String, key: String, value: String) -> Dynamic

@external(erlang, "nats_kv", "put")
fn nats_kv_put4_bits(conn: Pid, bucket: String, key: String, value: BitArray) -> Dynamic

@external(erlang, "nats_kv", "delete")
fn nats_kv_delete4(conn: Pid, bucket: String, key: String, opts: Dynamic) -> Dynamic

@external(erlang, "nats", "request")
fn nats_request4(conn: Pid, subject: String, payload: BitArray, opts: Dynamic) -> Dynamic

@external(erlang, "erlang", "is_pid")
fn is_pid(data: Dynamic) -> Bool

@external(erlang, "gleam_erlang_ffi", "identity")
fn pid_from_dynamic(data: Dynamic) -> Pid

@external(erlang, "gleam_erlang_ffi", "identity")
fn pid_to_dynamic(pid: Pid) -> Dynamic

@external(erlang, "application", "ensure_all_started")
fn ensure_all_started(app: atom.Atom) -> Dynamic

@external(erlang, "jst_server_ffi", "nats_headers_from_msg_opts")
fn nats_headers_from_msg_opts(msg_opts: Dynamic) -> Dynamic

@external(erlang, "jst_server_ffi", "kv_list_keys")
fn kv_list_keys2(conn: Pid, bucket: String) -> Dynamic

@external(erlang, "jst_server_ffi", "kv_get_value")
fn kv_get_value3(conn: Pid, bucket: String, key: String) -> Dynamic

@external(erlang, "jst_server_ffi", "kv_select_history")
fn kv_select_history3(conn: Pid, bucket: String, key: String) -> Dynamic


