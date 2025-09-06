import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/effect.{type Effect}

import lustre_websocket.{type WebSocket} as ws

/// TODO: Get the public functions to use the Sync type instead of having different functions for each type.
pub opaque type Sync(value, key) {
  SyncSub(Subscription(value))
  SyncKV(KV(key, value))
}

pub type Subscription(value) {
  Subscription(
    id: String,
    state: SyncState,
    subject: String,
    revision: Int,
    data: List(value),
    message_count: Int,
    encoder_value: fn(value) -> Json,
    decoder_value: Decoder(value),
    error: Option(String),
  )
}

/// KV is a key-value store that is used to store data in the browser.
/// Some fields are still unused but planned for future use.
pub type KV(key, value) {
  KV(
    // Subscription
    id: String,
    state: SyncState,
    bucket: String,
    filter: Option(String),
    revision: Int,
    data: Dict(key, value),
    message_count: Int,
    // Encoders
    encoder_key: fn(key) -> Json,
    encoder_value: fn(value) -> Json,
    // Decoders
    decoder_key: Decoder(key),
    decoder_value: Decoder(value),
  )
}

pub type SyncState {
  NotInitialized
  Connecting
  CatchingUp
  InSync
  KVError(String)
}

// Shared public API

// SUBSCRIPTION PUBLIC API

pub fn sub_new(
  id id: String,
  subject subject: String,
  encoder_value encoder_value: fn(value) -> Json,
  decoder_value decoder_value: Decoder(value),
  start_revision start_revision: Int,
) -> Subscription(value) {
  Subscription(
    id:,
    state: NotInitialized,
    subject:,
    revision: start_revision,
    data: list.new(),
    message_count: 0,
    encoder_value:,
    decoder_value:,
    error: None,
  )
}

pub fn sub_set_data(
  subscription: Subscription(value),
  data: List(value),
) -> Subscription(value) {
  Subscription(..subscription, data: data)
}

// KV PUBLIC API

pub fn kv_new(
  id id: String,
  bucket bucket: String,
  filter filter: Option(String),
  encoder_key encoder_key: fn(key) -> Json,
  encoder_value encoder_value: fn(value) -> Json,
  decoder_key decoder_key: Decoder(key),
  decoder_value decoder_value: Decoder(value),
  start_revision start_revision: Int,
) -> KV(key, value) {
  KV(
    id:,
    state: NotInitialized,
    bucket:,
    filter:,
    revision: start_revision,
    data: dict.new(),
    message_count: 0,
    encoder_key:,
    encoder_value:,
    decoder_key:,
    decoder_value:,
  )
}

pub fn kv_set_data(kv: KV(key, value), data: Dict(key, value)) -> KV(key, value) {
  KV(..kv, data:)
}

// SUB SOCKET HANDLERS

pub fn sub_ws_text_message(
  sub: Subscription(value),
  body: Dynamic,
) -> Subscription(value) {
  case decode.run(body, sub.decoder_value) {
    Ok(value) -> {
      Subscription(
        ..sub,
        data: [value, ..sub.data],
        message_count: sub.message_count + 1,
        state: InSync,
      )
    }
    Error(errors) -> {
      echo errors
      sub
    }
  }
}

pub fn sub_ws_binary_message(
  sub: Subscription(value),
  binary: List(Int),
) -> #(Subscription(value), Effect(msg)) {
  todo as "handle sub_ws_binary_message"
}

pub fn sub_ws_close(
  sub: Subscription(value),
  reason: ws.WebSocketCloseReason,
) -> #(Subscription(value), Effect(msg)) {
  todo as "handle sub_ws_close"
}

pub fn sub_ws_open(
  sub: Subscription(value),
  soc: WebSocket,
) -> #(Subscription(value), Effect(msg)) {
  #(
    Subscription(..sub, state: Connecting),
    ws.send(soc, subject_sub_envelope(sub)),
  )
}

// KV SOCKET HANDLERS

pub fn kv_ws_text_message(
  kv: KV(key, value),
  body: Dynamic,
) -> #(KV(key, value), Effect(msg)) {
  case decode.run(body, decoder_kv_sub(kv.decoder_key, kv.decoder_value)) {
    Ok(KvPut(rev:, key:, value:)) -> {
      let data = dict.insert(kv.data, key, value)
      #(
        KV(
          ..kv,
          data:,
          revision: rev,
          state: case kv.state {
            InSync -> InSync
            _ -> CatchingUp
          },
          message_count: kv.message_count + 1,
        ),
        effect.none(),
      )
    }
    Ok(KvDel(rev:, key:)) -> {
      let data = dict.delete(kv.data, key)
      #(
        KV(
          ..kv,
          data:,
          revision: rev,
          state: case kv.state {
            InSync -> InSync
            _ -> CatchingUp
          },
          message_count: kv.message_count + 1,
        ),
        effect.none(),
      )
    }
    Ok(KvInSync(rev:)) -> {
      // currently revision is not set on in_sync messages. 
      #(
        KV(..kv, state: InSync, message_count: kv.message_count + 1),
        effect.none(),
      )
    }
    Ok(KvError(rev:, error:)) -> {
      echo "kv_msg: kv-error"
      echo error
      echo body
      #(
        KV(..kv, state: KVError(error), message_count: kv.message_count + 1),
        effect.none(),
      )
    }
    Error(errors) -> {
      echo "kv_msg: error"
      echo errors
      echo body
      #(
        KV(
          ..kv,
          state: KVError("parse error"),
          message_count: kv.message_count + 1,
        ),
        effect.none(),
      )
    }
  }
}

pub fn kv_ws_binary_message(
  kv: KV(key, value),
  soc: WebSocket,
) -> #(KV(key, value), Effect(msg)) {
  todo as "handle ws_binary_message"
}

pub fn kv_ws_close(
  kv: KV(key, value),
  reason: ws.WebSocketCloseReason,
) -> #(KV(key, value), Effect(msg)) {
  case reason {
    ws.Normal -> #(
      KV(
        ..kv,
        state: KVError("Socket closed"),
        message_count: kv.message_count + 1,
      ),
      effect.none(),
    )
    ws.GoingAway -> #(
      KV(
        ..kv,
        state: KVError("Socket closed"),
        message_count: kv.message_count + 1,
      ),
      effect.none(),
    )
    _ -> {
      echo "ws_close reason"
      echo reason
      todo as "handle ws_close reason"
    }
  }
}

pub fn kv_ws_open(
  kv: KV(key, value),
  soc: WebSocket,
) -> #(KV(key, value), Effect(msg)) {
  #(KV(..kv, state: Connecting), ws.send(soc, kv_sub_envelope(kv)))
}

// PUBLIC HELPERS

pub fn sub_in_sync(sub: Subscription(value)) -> Bool {
  case sub.state {
    InSync -> True
    _ -> False
  }
}

pub fn kv_in_sync(kv: KV(key, value)) -> Bool {
  case kv.state {
    InSync -> True
    _ -> False
  }
}

// helpers

fn kv_sub_envelope(kv: KV(key, value)) -> String {
  json.object([
    #("op", json.string("kv_sub")),
    #("id", json.string(kv.id)),
    #("target", json.string(kv.bucket)),
    #("filter", json.string(kv.filter |> option.unwrap(""))),
  ])
  |> json.to_string
}

// TODO: naming...
fn subject_sub_envelope(sub: Subscription(value)) -> String {
  json.object([
    #("op", json.string("sub")),
    #("id", json.string(sub.id)),
    #("target", json.string(sub.subject)),
  ])
  |> json.to_string
}

pub type Envelope {
  Envelope(op: String, target: String, body: Dynamic)
}

pub type KvMsg(key, value) {
  KvPut(rev: Int, key: key, value: value)
  KvDel(rev: Int, key: key)
  // KvPurge(rev: Int)
  KvInSync(rev: Int)
  KvError(rev: Int, error: String)
}

pub fn decoder_envelope() -> Decoder(Envelope) {
  use op <- decode.field("op", decode.string)
  use target <- decode.field("target", decode.string)
  use body <- decode.field("data", decode.dynamic)
  decode.success(Envelope(op:, target:, body:))
}

fn decoder_kv_sub(
  decoder_key: Decoder(key),
  decoder_value: Decoder(value),
) -> Decoder(KvMsg(key, value)) {
  use op <- decode.field("op", decode.string)
  case op {
    "put" -> {
      use rev <- decode.field("rev", decode.int)
      use key <- decode.field("key", decoder_key)
      use value_string <- decode.field("value", decode.string)

      case json.parse(from: value_string, using: decoder_value) {
        Ok(value) -> decode.success(KvPut(rev:, key:, value:))
        Error(_) -> {
          use value <- decode.field("value", decoder_value)
          decode.failure(KvPut(rev:, key:, value:), "value_string parse error")
        }
      }
    }
    "delete" -> {
      use rev <- decode.field("rev", decode.int)
      use key <- decode.field("key", decoder_key)
      decode.success(KvDel(rev:, key:))
    }
    "in_sync" -> {
      use rev <- decode.field("rev", decode.int)
      decode.success(KvInSync(rev:))
    }
    "error" -> {
      use rev <- decode.field("rev", decode.int)
      use error <- decode.field("error", decode.string)
      decode.success(KvError(rev:, error:))
    }
    op -> {
      decode.failure(
        KvError(rev: 0, error: "unknown op: " <> op),
        "unknown op: " <> op,
      )
    }
  }
}

pub type SubMsg(value) {
  SubMsg(rev: Int, subject: String, data: value)
  SubInSync(rev: Int)
  SubError(rev: Int, error: String)
}

fn decoder_sub(decoder_value: Decoder(value)) -> Decoder(SubMsg(value)) {
  use op <- decode.field("op", decode.string)
  use subject <- decode.field("target", decode.string)
  use data <- decode.field("data", decoder_value)
  case op {
    "msg" -> decode.success(SubMsg(rev: 0, subject:, data:))
    "in_sync" -> decode.success(SubInSync(rev: 0))
    "error" -> decode.success(SubError(rev: 0, error: ""))
    op ->
      decode.failure(
        SubError(rev: 0, error: "unknown op: " <> op),
        "unknown op: " <> op,
      )
  }
}
