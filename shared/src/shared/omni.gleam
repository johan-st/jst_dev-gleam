import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/result
import gleam/string

import shared/article.{type Article}
import shared/chat.{type ChatMessage, type ChatRoom}
import shared/short_url.{type ShortUrl}
import shared/user.{type Session}

pub type DecodeError {
  DecodeError(String)
}

pub type ClientMessage {
  ClientHello(token: String)
  Login(username: String, password: String)
  Logout

  SubscribeArticles
  SubscribeShortUrls
  SubscribeChatRooms
  SubscribeChatMessages(room_id: String)

  ArticleUpsert(Article)
  ArticleDelete(id: String)

  ShortUrlUpsert(ShortUrl)
  ShortUrlDelete(id: String)

  ChatRequestCreate
  ChatSendMessage(room_id: String, content: String)
}

pub type ServerMessage {
  AuthOk(session: Session, token: String)
  AuthFailed(reason: String)

  ArticlesSnapshot(List(Article))
  ArticleUpserted(Article)
  ArticleDeleted(id: String)

  ShortUrlsSnapshot(List(ShortUrl))
  ShortUrlUpserted(ShortUrl)
  ShortUrlDeleted(id: String)

  ChatRoomsSnapshot(List(ChatRoom))
  ChatRoomUpserted(ChatRoom)
  ChatRoomDeleted(id: String)

  ChatMessagesSnapshot(room_id: String, messages: List(ChatMessage))
  ChatMessageNew(ChatMessage)

  ChatRequestCreated(room_id: String)

  ServerError(message: String)
}

pub fn encode_client_message(msg: ClientMessage) -> String {
  client_message_encoder(msg)
  |> json.to_string
}

pub fn decode_client_message(
  encoded: String,
) -> Result(ClientMessage, DecodeError) {
  json.parse(from: encoded, using: client_message_decoder())
  |> result.map_error(fn(err) { DecodeError(string.inspect(err)) })
}

pub fn encode_server_message(msg: ServerMessage) -> String {
  server_message_encoder(msg)
  |> json.to_string
}

pub fn decode_server_message(
  encoded: String,
) -> Result(ServerMessage, DecodeError) {
  json.parse(from: encoded, using: server_message_decoder())
  |> result.map_error(fn(err) { DecodeError(string.inspect(err)) })
}

fn client_message_encoder(msg: ClientMessage) -> json.Json {
  case msg {
    ClientHello(token) ->
      json.object([
        #("type", json.string("client_hello")),
        #("token", json.string(token)),
      ])

    Login(username, password) ->
      json.object([
        #("type", json.string("login")),
        #("username", json.string(username)),
        #("password", json.string(password)),
      ])

    Logout -> json.object([#("type", json.string("logout"))])

    SubscribeArticles -> json.object([#("type", json.string("sub_articles"))])
    SubscribeShortUrls ->
      json.object([#("type", json.string("sub_short_urls"))])
    SubscribeChatRooms ->
      json.object([#("type", json.string("sub_chat_rooms"))])
    SubscribeChatMessages(room_id) ->
      json.object([
        #("type", json.string("sub_chat_messages")),
        #("room_id", json.string(room_id)),
      ])

    ArticleUpsert(article_value) ->
      json.object([
        #("type", json.string("article_upsert")),
        #("article", article.encoder(article_value)),
      ])

    ArticleDelete(id) ->
      json.object([
        #("type", json.string("article_delete")),
        #("id", json.string(id)),
      ])

    ShortUrlUpsert(url) ->
      json.object([
        #("type", json.string("short_url_upsert")),
        #("short_url", short_url.encoder(url)),
      ])

    ShortUrlDelete(id) ->
      json.object([
        #("type", json.string("short_url_delete")),
        #("id", json.string(id)),
      ])

    ChatRequestCreate -> json.object([#("type", json.string("chat_request"))])

    ChatSendMessage(room_id, content) ->
      json.object([
        #("type", json.string("chat_send")),
        #("room_id", json.string(room_id)),
        #("content", json.string(content)),
      ])
  }
}

fn server_message_encoder(msg: ServerMessage) -> json.Json {
  case msg {
    AuthOk(session, token) ->
      json.object([
        #("type", json.string("auth_ok")),
        #("session", user.session_encoder(session)),
        #("token", json.string(token)),
      ])
    AuthFailed(reason) ->
      json.object([
        #("type", json.string("auth_failed")),
        #("reason", json.string(reason)),
      ])

    ArticlesSnapshot(articles) ->
      json.object([
        #("type", json.string("articles_snapshot")),
        #("articles", json.array(articles, article.encoder)),
      ])

    ArticleUpserted(article_value) ->
      json.object([
        #("type", json.string("article_upserted")),
        #("article", article.encoder(article_value)),
      ])

    ArticleDeleted(id) ->
      json.object([
        #("type", json.string("article_deleted")),
        #("id", json.string(id)),
      ])

    ShortUrlsSnapshot(urls) ->
      json.object([
        #("type", json.string("short_urls_snapshot")),
        #("short_urls", json.array(urls, short_url.encoder)),
      ])
    ShortUrlUpserted(url) ->
      json.object([
        #("type", json.string("short_url_upserted")),
        #("short_url", short_url.encoder(url)),
      ])
    ShortUrlDeleted(id) ->
      json.object([
        #("type", json.string("short_url_deleted")),
        #("id", json.string(id)),
      ])

    ChatRoomsSnapshot(rooms) ->
      json.object([
        #("type", json.string("chat_rooms_snapshot")),
        #("rooms", json.array(rooms, chat.room_encoder)),
      ])
    ChatRoomUpserted(room) ->
      json.object([
        #("type", json.string("chat_room_upserted")),
        #("room", chat.room_encoder(room)),
      ])
    ChatRoomDeleted(id) ->
      json.object([
        #("type", json.string("chat_room_deleted")),
        #("id", json.string(id)),
      ])

    ChatMessagesSnapshot(room_id, messages) ->
      json.object([
        #("type", json.string("chat_messages_snapshot")),
        #("room_id", json.string(room_id)),
        #("messages", json.array(messages, chat.message_encoder)),
      ])

    ChatMessageNew(message) ->
      json.object([
        #("type", json.string("chat_message_new")),
        #("message", chat.message_encoder(message)),
      ])

    ChatRequestCreated(room_id) ->
      json.object([
        #("type", json.string("chat_request_created")),
        #("room_id", json.string(room_id)),
      ])

    ServerError(message) ->
      json.object([
        #("type", json.string("server_error")),
        #("message", json.string(message)),
      ])
  }
}

fn client_message_decoder() -> Decoder(ClientMessage) {
  use t <- decode.field("type", decode.string)
  case t {
    "client_hello" -> {
      use token <- decode.field("token", decode.string)
      decode.success(ClientHello(token))
    }
    "login" -> {
      use username <- decode.field("username", decode.string)
      use password <- decode.field("password", decode.string)
      decode.success(Login(username, password))
    }
    "logout" -> decode.success(Logout)

    "sub_articles" -> decode.success(SubscribeArticles)
    "sub_short_urls" -> decode.success(SubscribeShortUrls)
    "sub_chat_rooms" -> decode.success(SubscribeChatRooms)
    "sub_chat_messages" -> {
      use room_id <- decode.field("room_id", decode.string)
      decode.success(SubscribeChatMessages(room_id))
    }

    "article_upsert" -> {
      use article <- decode.field("article", article.decoder())
      decode.success(ArticleUpsert(article))
    }
    "article_delete" -> {
      use id <- decode.field("id", decode.string)
      decode.success(ArticleDelete(id))
    }

    "short_url_upsert" -> {
      use url <- decode.field("short_url", short_url.decoder())
      decode.success(ShortUrlUpsert(url))
    }
    "short_url_delete" -> {
      use id <- decode.field("id", decode.string)
      decode.success(ShortUrlDelete(id))
    }

    "chat_request" -> decode.success(ChatRequestCreate)

    "chat_send" -> {
      use room_id <- decode.field("room_id", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(ChatSendMessage(room_id, content))
    }

    other -> decode.failure(Logout, "unknown client message type: " <> other)
  }
}

fn server_message_decoder() -> Decoder(ServerMessage) {
  use t <- decode.field("type", decode.string)
  case t {
    "auth_ok" -> {
      use session <- decode.field("session", user.session_decoder())
      use token <- decode.field("token", decode.string)
      decode.success(AuthOk(session, token))
    }
    "auth_failed" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(AuthFailed(reason))
    }

    "articles_snapshot" -> {
      use articles <- decode.field("articles", decode.list(article.decoder()))
      decode.success(ArticlesSnapshot(articles))
    }
    "article_upserted" -> {
      use article <- decode.field("article", article.decoder())
      decode.success(ArticleUpserted(article))
    }
    "article_deleted" -> {
      use id <- decode.field("id", decode.string)
      decode.success(ArticleDeleted(id))
    }

    "short_urls_snapshot" -> {
      use urls <- decode.field("short_urls", decode.list(short_url.decoder()))
      decode.success(ShortUrlsSnapshot(urls))
    }
    "short_url_upserted" -> {
      use url <- decode.field("short_url", short_url.decoder())
      decode.success(ShortUrlUpserted(url))
    }
    "short_url_deleted" -> {
      use id <- decode.field("id", decode.string)
      decode.success(ShortUrlDeleted(id))
    }

    "chat_rooms_snapshot" -> {
      use rooms <- decode.field("rooms", decode.list(chat.room_decoder()))
      decode.success(ChatRoomsSnapshot(rooms))
    }
    "chat_room_upserted" -> {
      use room <- decode.field("room", chat.room_decoder())
      decode.success(ChatRoomUpserted(room))
    }
    "chat_room_deleted" -> {
      use id <- decode.field("id", decode.string)
      decode.success(ChatRoomDeleted(id))
    }

    "chat_messages_snapshot" -> {
      use room_id <- decode.field("room_id", decode.string)
      use messages <- decode.field(
        "messages",
        decode.list(chat.message_decoder()),
      )
      decode.success(ChatMessagesSnapshot(room_id, messages))
    }
    "chat_message_new" -> {
      use message <- decode.field("message", chat.message_decoder())
      decode.success(ChatMessageNew(message))
    }

    "chat_request_created" -> {
      use room_id <- decode.field("room_id", decode.string)
      decode.success(ChatRequestCreated(room_id))
    }

    "server_error" -> {
      use message <- decode.field("message", decode.string)
      decode.success(ServerError(message))
    }

    other ->
      decode.failure(ServerError(""), "unknown server message type: " <> other)
  }
}
