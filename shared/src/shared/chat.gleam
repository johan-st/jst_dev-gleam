import gleam/dynamic/decode.{type Decoder}
import gleam/json

pub type ChatRoom {
  ChatRoom(id: String, name: String, public: Bool, users: List(String))
}

pub fn room_decoder() -> Decoder(ChatRoom) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use public <- decode.field("public", decode.bool)
  use users <- decode.field("users", decode.list(decode.string))
  decode.success(ChatRoom(id:, name:, public:, users:))
}

pub fn room_encoder(room: ChatRoom) -> json.Json {
  json.object([
    #("id", json.string(room.id)),
    #("name", json.string(room.name)),
    #("public", json.bool(room.public)),
    #("users", json.array(room.users, json.string)),
  ])
}

pub type ChatMessage {
  ChatMessage(
    id: String,
    user_id: String,
    room_id: String,
    content: String,
    timestamp_ms: Int,
  )
}

pub fn message_decoder() -> Decoder(ChatMessage) {
  use id <- decode.field("id", decode.string)
  use user_id <- decode.field("user_id", decode.string)
  use room_id <- decode.field("room_id", decode.string)
  use content <- decode.field("content", decode.string)
  use timestamp_ms <- decode.field("timestamp_ms", decode.int)
  decode.success(ChatMessage(id:, user_id:, room_id:, content:, timestamp_ms:))
}

pub fn message_encoder(message: ChatMessage) -> json.Json {
  json.object([
    #("id", json.string(message.id)),
    #("user_id", json.string(message.user_id)),
    #("room_id", json.string(message.room_id)),
    #("content", json.string(message.content)),
    #("timestamp_ms", json.int(message.timestamp_ms)),
  ])
}
