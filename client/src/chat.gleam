import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}
import sync
import utils/http

pub type Model {
  Model(
    rooms: sync.KV(String, ChatRoom),
    messages: sync.Subscription(ChatMessage),
    active_room_id: Option(String),
  )
}

/// Chat message model
pub type ChatMessage {
  ChatMessage(
    id: String,
    room_id: String,
    user_id: String,
    // username: String,
    content: String,
    timestamp_ms: Int,
  )
}

/// Chat room model
pub type ChatRoom {
  ChatRoom(id: String, users: List(String), public: Bool, name: String)
}

/// Chat message for API requests
pub type ChatMessageRequest {
  ChatMessageRequest(id: String, room: String, user: String, content: String)
}

/// Chat room creation request
pub type ChatRoomRequest {
  ChatRoomRequest(users: List(String), public: Bool, name: String)
}

// JSON DECODERS

pub fn chat_message_decoder() -> Decoder(ChatMessage) {
  use id <- decode.field("id", decode.string)
  use room_id <- decode.field("room", decode.string)
  use user_id <- decode.field("user", decode.string)
  // use username <- decode.field("username", decode.string)
  use content <- decode.field("content", decode.string)
  use timestamp <- decode.field("timestamp_ms", decode.string)

  case timestamp |> int.parse {
    Ok(ts) -> {
      decode.success(ChatMessage(
        id:,
        room_id:,
        user_id:,
        // username:,
        content:,
        timestamp_ms: ts,
      ))
    }
    Error(_) ->
      decode.failure(ChatMessage("", "", "", "", 0), "invalid timestamp_ms")
  }
}

pub fn chat_room_decoder() -> Decoder(ChatRoom) {
  use id <- decode.field("id", decode.string)
  use users <- decode.field("users", decode.list(decode.string))
  use public <- decode.field("public", decode.bool)
  use name <- decode.field("name", decode.string)
  decode.success(ChatRoom(id:, users:, public:, name:))
}

// JSON ENCODERS

pub fn chat_message_request_to_json(req: ChatMessageRequest) -> Json {
  json.object([
    #("id", json.string(req.id)),
    #("room", json.string(req.room)),
    #("user", json.string(req.user)),
    #("content", json.string(req.content)),
  ])
}

pub fn chat_room_request_to_json(req: ChatRoomRequest) -> Json {
  json.object([
    #("users", json.array(req.users, json.string)),
    #("public", json.bool(req.public)),
    #("name", json.string(req.name)),
  ])
}

// HELPER FUNCTIONS

pub fn init(
  rooms: sync.KV(String, ChatRoom),
  messages: sync.Subscription(ChatMessage),
) -> Model {
  Model(rooms:, messages:, active_room_id: None)
}

pub fn add_message(state: Model, message: ChatMessage) -> Model {
  Model(..state, messages: sync.sub_set_data(state.messages, [message]))
}

pub fn add_room(state: Model, room: ChatRoom) -> Model {
  Model(
    ..state,
    rooms: sync.kv_set_data(
      state.rooms,
      dict.insert(state.rooms.data, room.id, room),
    ),
  )
}

pub fn set_room_id(state: Model, room_id: String) -> Model {
  Model(..state, active_room_id: Some(room_id))
}

// ENCODE/DECODE

pub fn room_encoder(room: ChatRoom) -> Json {
  json.object([
    #("id", json.string(room.id)),
    #("users", json.array(room.users, json.string)),
    #("public", json.bool(room.public)),
  ])
}

pub fn room_decoder() -> Decoder(ChatRoom) {
  use id <- decode.field("id", decode.string)
  use users <- decode.field("users", decode.list(decode.string))
  use public <- decode.field("public", decode.bool)
  use name <- decode.field("name", decode.string)
  decode.success(ChatRoom(id:, users:, public:, name:))
}

pub fn message_encoder(message: ChatMessage) -> Json {
  json.object([
    #("id", json.string(message.id)),
    #("room", json.string(message.room_id)),
    #("user", json.string(message.user_id)),
    // #("username", json.string(message.username)),
    #("content", json.string(message.content)),
    #("timestamp_ms", json.int(message.timestamp_ms)),
  ])
}

pub fn message_decoder() -> Decoder(ChatMessage) {
  use id <- decode.field("id", decode.string)
  use room_id <- decode.field("room_id", decode.string)
  use user_id <- decode.field("user_id", decode.string)
  // use username <- decode.field("username", decode.string)
  use content <- decode.field("content", decode.string)
  use timestamp_ms <- decode.field("timestamp_ms", decode.int)
  decode.success(ChatMessage(
    id:,
    room_id:,
    user_id:,
    // username:,
    content:,
    timestamp_ms:,
  ))
}

// CHAT REQUEST LOGIC

pub type ChatRequestMsg {
  RequestChat
  ChatRequestCreated(room_id: String)
  ChatRequestFailed(String)
}

pub fn request_chat() -> Effect(ChatRequestMsg) {
  http.post(
    "/chat/request",
    json.object([]),
    http.expect_json(chat_request_response_decoder(), fn(result) {
      case result {
        Ok(room_id) -> ChatRequestCreated(room_id)
        Error(_) -> ChatRequestFailed("Failed to create chat request")
      }
    }),
  )
}

pub fn chat_request_response_decoder() -> Decoder(String) {
  use room_id <- decode.field("room_id", decode.string)
  decode.success(room_id)
}

//  MOVE TO OTHER FILE

pub type TimeMsg {
  TimeMsg(unix_milli: Int, fly_app_name: String, fly_region: String)
}

pub fn decoder_time_msg() -> Decoder(TimeMsg) {
  use unix_milli <- decode.field("unixMilli", decode.int)
  use fly_app_name <- decode.field("fly_app_name", decode.string)
  use fly_region <- decode.field("fly_region", decode.string)
  decode.success(TimeMsg(unix_milli:, fly_app_name:, fly_region:))
}

pub fn encoder_time_msg(time_msg: TimeMsg) -> Json {
  case time_msg {
    TimeMsg(unix_milli, fly_app_name, fly_region) -> {
      json.object([
        #("unixMilli", json.int(unix_milli)),
        #("fly_app_name", json.string(fly_app_name)),
        #("fly_region", json.string(fly_region)),
      ])
    }
  }
}
