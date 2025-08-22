import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import lustre/effect.{type Effect}

import lustre_websocket.{type WebSocket} as ws

/// KV is a key-value store that is used to store data in the browser.
/// Some fields are still unused but planned for future use.
pub type KV(key, value) {
  KV(
    // Subscription
    id: String,
    state: KVState,
    bucket: String,
    filter: Option(String),
    revision: Int,
    data: Dict(key, value),
    // Encoders
    encoder_key: fn(key) -> Json,
    encoder_value: fn(value) -> Json,
    // Decoders
    decoder_key: Decoder(key),
    decoder_value: Decoder(value),
  )
}

pub type KVState {
  NotInitialized
  Connecting
  CatchingUp
  InSync
  KVError(String)
}

// KV PUBLIC API

pub fn new_kv(
  id id: String,
  bucket bucket: String,
  filter filter: Option(String),
  encoder_key encoder_key: fn(key) -> Json,
  encoder_value encoder_value: fn(value) -> Json,
  decoder_key decoder_key: Decoder(key),
  decoder_value decoder_value: Decoder(value),
  start_revision start_revision: Int,
) -> KV(key, value) {
  let kv =
    KV(
      id:,
      state: NotInitialized,
      bucket:,
      filter:,
      revision: start_revision,
      data: dict.new(),
      encoder_key:,
      encoder_value:,
      decoder_key:,
      decoder_value:,
    )
}

pub fn set_data(kv: KV(key, value), data: Dict(key, value)) -> KV(key, value) {
  KV(..kv, data:)
}

// KV SOCKET HANDLERS

pub fn ws_text_message(
  kv: KV(key, value),
  text: String,
) -> #(KV(key, value), Effect(msg)) {
  case
    json.parse(
      from: text,
      using: decoder_envelope(kv.decoder_key, kv.decoder_value),
    )
  {
    Ok(Envelope(op:, target:, data:)) -> {
      case target == kv.bucket {
        True -> {
          case op {
            "kv_msg" -> {
              case data {
                KvPut(rev:, key:, value:) -> {
                  let data = dict.insert(kv.data, key, value)
                  #(
                    KV(..kv, data:, revision: rev, state: case kv.state {
                      InSync -> InSync
                      _ -> CatchingUp
                    }),
                    effect.none(),
                  )
                }
                KvDel(rev:, key:) -> {
                  let data = dict.delete(kv.data, key)
                  #(
                    KV(..kv, data:, revision: rev, state: case kv.state {
                      InSync -> InSync
                      _ -> CatchingUp
                    }),
                    effect.none(),
                  )
                }
                KvInSync(rev:) -> {
                  // currently revision is not set on in_sync messages. 
                  #(KV(..kv, state: InSync), effect.none())
                }
                KvError(rev:, error:) -> {
                  echo "kv_msg: error"
                  echo "error: " <> error
                  #(KV(..kv, state: KVError(error)), effect.none())
                }
              }
            }
            op -> {
              echo "op: " <> op
              echo "kv.id: " <> kv.id
              echo "kv.bucket: " <> kv.bucket
              echo "kv.filter: " <> kv.filter |> option.unwrap("")
              #(kv, effect.none())
            }
          }
        }
        False -> {
          echo "ws_text_message: target mismatch"
          echo "target: " <> target
          echo "kv.bucket: " <> kv.bucket
          #(kv, effect.none())
        }
      }
    }
    Error(errors) -> {
      echo errors
      #(kv, effect.none())
    }
  }
}

pub fn ws_binary_message(
  kv: KV(key, value),
  soc: WebSocket,
) -> #(KV(key, value), Effect(msg)) {
  todo as "handle ws_binary_message"
}

pub fn ws_close(
  kv: KV(key, value),
  reason: ws.WebSocketCloseReason,
) -> #(KV(key, value), Effect(msg)) {
  case reason {
    ws.Normal -> #(KV(..kv, state: KVError("Socket closed")), effect.none())
    ws.GoingAway -> #(KV(..kv, state: KVError("Socket closed")), effect.none())
    _ -> {
      echo "ws_close reason"
      echo reason
      todo as "handle ws_close reason"
    }
  }
}

pub fn ws_open(
  kv: KV(key, value),
  soc: WebSocket,
) -> #(KV(key, value), Effect(msg)) {
  #(KV(..kv, state: Connecting), ws.send(soc, sub_envelope(kv)))
}

// PUBLIC HELPERS
pub fn in_sync(kv: KV(key, value)) -> Bool {
  case kv.state {
    InSync -> True
    _ -> False
  }
}

// helpers

fn sub_envelope(kv: KV(key, value)) -> String {
  json.object([
    #("op", json.string("kv_sub")),
    #("id", json.string(kv.id)),
    #("target", json.string(kv.bucket)),
    #("filter", json.string(kv.filter |> option.unwrap(""))),
  ])
  |> json.to_string
}

pub type Envelope(key, value) {
  Envelope(op: String, target: String, data: KvMsg(key, value))
}

pub type KvMsg(key, value) {
  KvPut(rev: Int, key: key, value: value)
  KvDel(rev: Int, key: key)
  // KvPurge(rev: Int)
  KvInSync(rev: Int)
  KvError(rev: Int, error: String)
}

fn decoder_envelope(
  decoder_key: Decoder(key),
  decoder_value: Decoder(value),
) -> Decoder(Envelope(key, value)) {
  use op <- decode.field("op", decode.string)
  use target <- decode.field("target", decode.string)
  use data <- decode.field("data", decoder_kv_sub(decoder_key, decoder_value))
  echo Envelope(op:, target:, data:)
  decode.success(Envelope(op:, target:, data:))
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
