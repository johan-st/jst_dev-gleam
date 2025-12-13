import gleam/dynamic/decode.{type Decoder}
import gleam/json

pub type Session {
  Session(subject: String, expires_at: Int, permissions: List(String))
}

pub fn session_decoder() -> Decoder(Session) {
  use subject <- decode.field("subject", decode.string)
  use expires_at <- decode.field("expiresAt", decode.int)
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(Session(subject:, expires_at:, permissions:))
}

pub fn session_encoder(session: Session) -> json.Json {
  json.object([
    #("subject", json.string(session.subject)),
    #("expiresAt", json.int(session.expires_at)),
    #("permissions", json.array(session.permissions, json.string)),
  ])
}

pub type UserFull {
  UserFull(
    id: String,
    revision: Int,
    username: String,
    email: String,
    permissions: List(String),
  )
}

pub fn user_full_decoder() -> Decoder(UserFull) {
  use id <- decode.field("id", decode.string)
  use revision <- decode.field("revision", decode.int)
  use username <- decode.field("username", decode.string)
  use email <- decode.field("email", decode.string)
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(UserFull(id:, revision:, username:, email:, permissions:))
}

pub fn user_full_encoder(user: UserFull) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("revision", json.int(user.revision)),
    #("username", json.string(user.username)),
    #("email", json.string(user.email)),
    #("permissions", json.array(user.permissions, json.string)),
  ])
}
