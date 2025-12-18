import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option, None}

pub type Subscription(value) {
  Subscription(
    id: String,
    state: SyncState,
    subject: String,
    revision: Int,
    data: List(value),
    message_count: Int,
    encoder_value: fn(value) -> json.Json,
    decoder_value: Decoder(value),
    error: Option(String),
  )
}

/// KV is a key-value store that is used to store data in the browser.
pub type KV(key, value) {
  KV(
    id: String,
    state: SyncState,
    bucket: String,
    filter: Option(String),
    revision: Int,
    data: Dict(key, value),
    message_count: Int,
    encoder_key: fn(key) -> json.Json,
    encoder_value: fn(value) -> json.Json,
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

pub fn sub_new(
  id id: String,
  subject subject: String,
  encoder_value encoder_value: fn(value) -> json.Json,
  decoder_value decoder_value: Decoder(value),
  start_revision start_revision: Int,
) -> Subscription(value) {
  Subscription(
    id:,
    state: NotInitialized,
    subject:,
    revision: start_revision,
    data: [],
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

pub fn kv_new(
  id id: String,
  bucket bucket: String,
  filter filter: Option(String),
  encoder_key encoder_key: fn(key) -> json.Json,
  encoder_value encoder_value: fn(value) -> json.Json,
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
  KV(..kv, data: data)
}

pub fn sub_in_sync(sub: Subscription(value)) -> Bool {
  sub.state == InSync
}

pub fn kv_in_sync(kv: KV(key, value)) -> Bool {
  kv.state == InSync
}
