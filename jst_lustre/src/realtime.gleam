import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import lustre/effect.{type Effect}
import lustre_websocket as ws

@external(javascript, "./app.ffi.mjs", "set_timeout")
fn set_timeout(callback: fn() -> Nil, delay: Int) -> Nil

// ---------- Types ----------

/// Elm-style child model: no knowledge of parent message type.
pub opaque type Model {
  Model(
    path: String,
    socket: Option(ws.WebSocket),
    retries: Int,
    subjects: set.Set(String),
    kv_buckets: set.Set(String),
  )
}

/// Elm-style child message: parent wraps this (e.g. RealtimeMsg) and handles it.
pub opaque type Msg {
  Connect
  Connected(ws.WebSocket)
  Disconnected(ws.WebSocketCloseReason)
  WsText(String)
  Subscribe(String)
  Unsubscribe(String)
  KvSubscribe(String)
  Incoming(String, String)
  // Article operations
  ArticleList
  ArticleGet(String)
  ArticleCreate(ArticleCreateRequest)
  ArticleUpdate(String, ArticleUpdateRequest)
  ArticleDelete(String)
  ArticleHistory(String)
  ArticleRevision(String, Int)
  // Article real-time updates
  ArticleUpdated(String, ArticleResponse)
  // id, article
  ArticleCreated(String, ArticleResponse)
  // id, article
  ArticleDeleted(String)
  // id
  // target, raw json
  Noop
}

/// Article creation request
pub type ArticleCreateRequest {
  ArticleCreateRequest(
    title: String,
    subtitle: String,
    leading: String,
    content: String,
    tags: List(String),
    published_at: Int,
  )
}

/// Article update request
pub type ArticleUpdateRequest {
  ArticleUpdateRequest(
    title: Option(String),
    subtitle: Option(String),
    leading: Option(String),
    content: Option(String),
    tags: Option(List(String)),
    published_at: Option(Int),
  )
}

/// Article response from server
pub type ArticleResponse {
  ArticleResponse(
    id: String,
    slug: String,
    title: String,
    subtitle: String,
    leading: String,
    author: String,
    published_at: Int,
    tags: List(String),
    content: Option(String),
    revision: Int,
    struct_version: Int,
  )
}

/// Article list response
pub type ArticleListResponse {
  ArticleListResponse(articles: List(ArticleResponse))
}

/// Article history response
pub type ArticleHistoryResponse {
  ArticleHistoryResponse(revisions: List(ArticleResponse))
}

// ---------- Public API ----------

pub fn init(path: String) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      path: path,
      socket: None,
      retries: 0,
      subjects: set.new(),
      kv_buckets: set.new(),
    )
  #(model, ws.init(path, handle_ws_event))
}

/// Inspect a message and return the incoming event if present.
pub fn incoming_of(m: Msg) -> Option(#(String, String)) {
  case m {
    Incoming(target, raw) -> Some(#(target, raw))
    _ -> None
  }
}

/// Expose connection state for debug UI
pub fn is_connected(model: Model) -> Bool {
  case model.socket {
    Some(_) -> True
    None -> False
  }
}

pub fn retries(model: Model) -> Int {
  model.retries
}

pub fn next_retry_ms(model: Model) -> Int {
  backoff_ms(model.retries + 1)
}

/// Current subjects list (sorted), for debug UI
pub fn subjects(model: Model) -> List(String) {
  model.subjects
  |> set.to_list
  |> list.sort(string.compare)
}

/// Current KV buckets list (sorted), for debug UI
pub fn kv_buckets(model: Model) -> List(String) {
  model.kv_buckets
  |> set.to_list
  |> list.sort(string.compare)
}

pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg)) {
  case msg {
    Connect -> {
      // Guard against duplicate connects
      case model.socket {
        Some(_) -> #(model, effect.none())
        None -> #(model, ws.init(model.path, handle_ws_event))
      }
    }

    Connected(socket) -> {
      // Reset retries and resubscribe all subjects and KV buckets
      let resend_subjects =
        model.subjects
        |> set.to_list
        |> list.map(fn(subject) {
          encode_envelope("sub", subject, None, json.object([]))
        })
      let resend_kv_buckets =
        model.kv_buckets
        |> set.to_list
        |> list.map(fn(bucket) {
          encode_envelope("kv_sub", bucket, None, json.object([]))
        })

      // Auto-subscribe to article KV updates for real-time data
      let article_sub =
        encode_envelope(
          "kv_sub",
          "article",
          None,
          json.object([#("pattern", json.string(">"))]),
        )

      let all_messages =
        list.append(
          resend_subjects,
          list.append(resend_kv_buckets, [article_sub]),
        )
      let send_effect = case all_messages {
        [] -> effect.none()
        msgs ->
          msgs
          |> list.map(fn(m) { ws.send(socket, m) })
          |> effect.batch
      }
      #(Model(..model, socket: Some(socket), retries: 0), send_effect)
    }

    Disconnected(_reason) -> {
      let next_retries = model.retries + 1
      let delay_ms = backoff_ms(next_retries)
      #(
        Model(..model, socket: None, retries: next_retries),
        effect.from(fn(dispatch) {
          set_timeout(fn() { dispatch(Connect) }, delay_ms)
        }),
      )
    }

    WsText(text) -> handle_incoming_text(text, model)

    Incoming(_, _) -> #(model, effect.none())

    Subscribe(subject) -> {
      let subjects = set.insert(model.subjects, subject)
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(sock, encode_envelope("sub", subject, None, json.object([])))
        None -> effect.none()
      }
      #(Model(..model, subjects: subjects), send_eff)
    }

    Unsubscribe(subject) -> {
      let subjects = set.delete(model.subjects, subject)
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope("unsub", subject, None, json.object([])),
          )
        None -> effect.none()
      }
      #(Model(..model, subjects: subjects), send_eff)
    }

    KvSubscribe(bucket) -> {
      let kv_buckets = set.insert(model.kv_buckets, bucket)
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope("kv_sub", bucket, None, json.object([])),
          )
        None -> effect.none()
      }
      #(Model(..model, kv_buckets: kv_buckets), send_eff)
    }

    // Article operations
    ArticleList -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_list",
              "",
              Some("list_articles_1"),
              json.object([]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleGet(id) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_get",
              "",
              None,
              json.object([#("id", json.string(id))]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleCreate(req) -> {
      let data =
        json.object([
          #("title", json.string(req.title)),
          #("subtitle", json.string(req.subtitle)),
          #("leading", json.string(req.leading)),
          #("content", json.string(req.content)),
          #("tags", json.array(from: req.tags, of: json.string)),
          #("published_at", json.int(req.published_at)),
        ])
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(sock, encode_envelope("article_create", "", None, data))
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleUpdate(id, req) -> {
      let update_data =
        json.object([
          #("id", json.string(id)),
          #("data", encode_update_request(req)),
        ])
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope("article_update", "", None, update_data),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleDelete(id) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_delete",
              "",
              None,
              json.object([#("id", json.string(id))]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleHistory(id) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_history",
              "",
              None,
              json.object([#("id", json.string(id))]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleRevision(id, revision) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_revision",
              "",
              None,
              json.object([
                #("id", json.string(id)),
                #("revision", json.int(revision)),
              ]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleUpdated(id, article) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_updated",
              "",
              None,
              json.object([
                #("id", json.string(id)),
                #(
                  "article",
                  json.object([
                    #("id", json.string(article.id)),
                    #("slug", json.string(article.slug)),
                    #("title", json.string(article.title)),
                    #("subtitle", json.string(article.subtitle)),
                    #("leading", json.string(article.leading)),
                    #("author", json.string(article.author)),
                    #("published_at", json.int(article.published_at)),
                    #("tags", json.array(from: article.tags, of: json.string)),
                    #(
                      "content",
                      json.string(article.content |> option.unwrap("")),
                    ),
                    #("revision", json.int(article.revision)),
                    #("struct_version", json.int(article.struct_version)),
                  ]),
                ),
              ]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleCreated(id, article) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_created",
              "",
              None,
              json.object([
                #("id", json.string(id)),
                #(
                  "article",
                  json.object([
                    #("id", json.string(article.id)),
                    #("slug", json.string(article.slug)),
                    #("title", json.string(article.title)),
                    #("subtitle", json.string(article.subtitle)),
                    #("leading", json.string(article.leading)),
                    #("author", json.string(article.author)),
                    #("published_at", json.int(article.published_at)),
                    #("tags", json.array(from: article.tags, of: json.string)),
                    #(
                      "content",
                      json.string(article.content |> option.unwrap("")),
                    ),
                    #("revision", json.int(article.revision)),
                    #("struct_version", json.int(article.struct_version)),
                  ]),
                ),
              ]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    ArticleDeleted(id) -> {
      let send_eff = case model.socket {
        Some(sock) ->
          ws.send(
            sock,
            encode_envelope(
              "article_deleted",
              "",
              None,
              json.object([#("id", json.string(id))]),
            ),
          )
        None -> effect.none()
      }
      #(model, send_eff)
    }

    Noop -> #(model, effect.none())
  }
}

// Convenience constructors (Elm-like helpers)
pub fn subscribe(subject: String) -> Msg {
  Subscribe(subject)
}

pub fn unsubscribe(subject: String) -> Msg {
  Unsubscribe(subject)
}

pub fn kv_subscribe(bucket: String) -> Msg {
  KvSubscribe(bucket)
}

// Article operation helpers
pub fn article_list() -> Msg {
  ArticleList
}

pub fn article_get(id: String) -> Msg {
  ArticleGet(id)
}

pub fn article_create(
  title: String,
  subtitle: String,
  leading: String,
  content: String,
  tags: List(String),
  published_at: Int,
) -> Msg {
  ArticleCreate(ArticleCreateRequest(
    title: title,
    subtitle: subtitle,
    leading: leading,
    content: content,
    tags: tags,
    published_at: published_at,
  ))
}

pub fn article_update(
  id: String,
  title: Option(String),
  subtitle: Option(String),
  leading: Option(String),
  content: Option(String),
  tags: Option(List(String)),
  published_at: Option(Int),
) -> Msg {
  ArticleUpdate(
    id,
    ArticleUpdateRequest(
      title: title,
      subtitle: subtitle,
      leading: leading,
      content: content,
      tags: tags,
      published_at: published_at,
    ),
  )
}

pub fn article_delete(id: String) -> Msg {
  ArticleDelete(id)
}

pub fn article_history(id: String) -> Msg {
  ArticleHistory(id)
}

pub fn article_revision(id: String, revision: Int) -> Msg {
  ArticleRevision(id, revision)
}

// Article real-time update helpers
pub fn article_updated(id: String, article: ArticleResponse) -> Msg {
  ArticleUpdated(id, article)
}

pub fn article_created(id: String, article: ArticleResponse) -> Msg {
  ArticleCreated(id, article)
}

pub fn article_deleted(id: String) -> Msg {
  ArticleDeleted(id)
}

// ---------- Internals ----------

fn handle_ws_event(event: ws.WebSocketEvent) -> Msg {
  case event {
    ws.InvalidUrl -> Noop
    ws.OnBinaryMessage(_data) -> Noop
    ws.OnClose(reason) -> Disconnected(reason)
    ws.OnOpen(socket) -> Connected(socket)
    ws.OnTextMessage(data) -> WsText(data)
  }
}

fn handle_incoming_text(text: String, model: Model) -> #(Model, Effect(Msg)) {
  let decoder = {
    use target <- decode.field("target", decode.string)
    decode.success(target)
  }
  let parsed = json.parse(from: text, using: decoder)
  case parsed {
    Ok(target) -> {
      // Check if this is an article update message
      case target {
        "article" -> {
          // Parse article update message
          let article_decoder = {
            use op <- decode.field("op", decode.string)
            use key <- decode.field("key", decode.string)
            use value <- decode.field("value", decode.dynamic)
            decode.success(#(op, key, value))
          }
          let article_parsed = json.parse(from: text, using: article_decoder)
          case article_parsed {
            Ok(#(op, key, value_data)) -> {
              case op {
                "put" -> {
                  // Article created or updated
                  case decode_article_response(value_data) {
                    Ok(article) -> {
                      #(
                        model,
                        effect.from(fn(dispatch) {
                          dispatch(ArticleUpdated(key, article))
                        }),
                      )
                    }
                    Error(_) -> {
                      #(
                        model,
                        effect.from(fn(dispatch) {
                          dispatch(Incoming(target, text))
                        }),
                      )
                    }
                  }
                }
                "delete" -> {
                  // Article deleted
                  #(
                    model,
                    effect.from(fn(dispatch) { dispatch(ArticleDeleted(key)) }),
                  )
                }
                _ -> {
                  #(
                    model,
                    effect.from(fn(dispatch) {
                      dispatch(Incoming(target, text))
                    }),
                  )
                }
              }
            }
            Error(_) -> {
              #(
                model,
                effect.from(fn(dispatch) { dispatch(Incoming(target, text)) }),
              )
            }
          }
        }
        _ -> {
          // Check if this is a reply message (for article operations)
          let reply_decoder = {
            use op <- decode.field("op", decode.string)
            use inbox <- decode.field("inbox", decode.optional(decode.string))
            use data <- decode.field("data", decode.dynamic)
            decode.success(#(op, inbox, data))
          }
          case json.parse(from: text, using: reply_decoder) {
            Ok(#(op, inbox, data)) -> {
              case op {
                "reply" -> {
                  // Handle article list response
                  case inbox {
                    Some("list_articles_1") -> {
                      // This is the article list response
                      case decode_article_list_response(data) {
                        Ok(articles) -> {
                          let articles_json =
                            json.array(from: articles, of: fn(article) {
                              json.object([
                                #("id", json.string(article.id)),
                                #("slug", json.string(article.slug)),
                                #("title", json.string(article.title)),
                                #("subtitle", json.string(article.subtitle)),
                                #("leading", json.string(article.leading)),
                                #("author", json.string(article.author)),
                                #(
                                  "published_at",
                                  json.int(article.published_at),
                                ),
                                #(
                                  "tags",
                                  json.array(
                                    from: article.tags,
                                    of: json.string,
                                  ),
                                ),
                                #(
                                  "content",
                                  json.string(
                                    article.content |> option.unwrap(""),
                                  ),
                                ),
                                #("revision", json.int(article.revision)),
                                #(
                                  "struct_version",
                                  json.int(article.struct_version),
                                ),
                              ])
                            })
                          let response_data =
                            json.object([#("articles", articles_json)])
                          #(
                            model,
                            effect.from(fn(dispatch) {
                              dispatch(Incoming(
                                target,
                                json.to_string(response_data),
                              ))
                            }),
                          )
                        }
                        Error(_) -> {
                          #(
                            model,
                            effect.from(fn(dispatch) {
                              dispatch(Incoming(target, text))
                            }),
                          )
                        }
                      }
                    }
                    _ -> {
                      #(
                        model,
                        effect.from(fn(dispatch) {
                          dispatch(Incoming(target, text))
                        }),
                      )
                    }
                  }
                }
                _ -> {
                  #(
                    model,
                    effect.from(fn(dispatch) {
                      dispatch(Incoming(target, text))
                    }),
                  )
                }
              }
            }
            Error(_) -> {
              #(
                model,
                effect.from(fn(dispatch) { dispatch(Incoming(target, text)) }),
              )
            }
          }
        }
      }
    }
    Error(_) -> #(model, effect.none())
  }
}

fn encode_envelope(
  op: String,
  target: String,
  _inbox: Option(String),
  data: json.Json,
) -> String {
  json.to_string(
    json.object([
      #("op", json.string(op)),
      #("target", json.string(target)),
      #("data", data),
    ]),
  )
}

// no id needed in Elm-style API

fn decode_article_response(
  data: dynamic.Dynamic,
) -> Result(ArticleResponse, String) {
  // Parse from dynamic data directly
  case decode_article_from_dynamic(data) {
    Ok(article) -> Ok(article)
    Error(e) -> Error("Failed to decode article: " <> e)
  }
}

fn decode_article_from_dynamic(
  data: dynamic.Dynamic,
) -> Result(ArticleResponse, String) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use slug <- decode.field("slug", decode.string)
    use title <- decode.field("title", decode.string)
    use subtitle <- decode.field("subtitle", decode.string)
    use leading <- decode.field("leading", decode.string)
    use author <- decode.field("author", decode.string)
    use published_at <- decode.field("published_at", decode.int)
    use tags <- decode.field("tags", decode.list(decode.string))
    use content <- decode.field("content", decode.optional(decode.string))
    use revision <- decode.field("revision", decode.int)
    use struct_version <- decode.field("struct_version", decode.int)

    decode.success(ArticleResponse(
      id: id,
      slug: slug,
      title: title,
      subtitle: subtitle,
      leading: leading,
      author: author,
      published_at: published_at,
      tags: tags,
      content: content,
      revision: revision,
      struct_version: struct_version,
    ))
  }

  case decode.run(data, decoder) {
    Ok(article) -> Ok(article)
    Error(e) -> Error("Decode error: " <> string.inspect(e))
  }
}

fn decode_article_list_response(
  data: dynamic.Dynamic,
) -> Result(List(ArticleResponse), String) {
  let decoder = {
    use articles <- decode.field(
      "articles",
      decode.list(article_response_decoder()),
    )
    decode.success(articles)
  }

  case decode.run(data, decoder) {
    Ok(articles) -> Ok(articles)
    Error(e) -> Error("Decode error: " <> string.inspect(e))
  }
}

fn article_response_decoder() -> decode.Decoder(ArticleResponse) {
  use id <- decode.field("id", decode.string)
  use slug <- decode.field("slug", decode.string)
  use title <- decode.field("title", decode.string)
  use subtitle <- decode.field("subtitle", decode.string)
  use leading <- decode.field("leading", decode.string)
  use author <- decode.field("author", decode.string)
  use published_at <- decode.field("published_at", decode.int)
  use tags <- decode.field("tags", decode.list(decode.string))
  use content <- decode.field("content", decode.optional(decode.string))
  use revision <- decode.field("revision", decode.int)
  use struct_version <- decode.field("struct_version", decode.int)

  decode.success(ArticleResponse(
    id: id,
    slug: slug,
    title: title,
    subtitle: subtitle,
    leading: leading,
    author: author,
    published_at: published_at,
    tags: tags,
    content: content,
    revision: revision,
    struct_version: struct_version,
  ))
}

fn encode_update_request(req: ArticleUpdateRequest) -> json.Json {
  let fields =
    list.append(
      list.append(
        list.append(
          list.append(
            list.append(
              case req.title {
                Some(title) -> [#("title", json.string(title))]
                None -> []
              },
              case req.subtitle {
                Some(subtitle) -> [#("subtitle", json.string(subtitle))]
                None -> []
              },
            ),
            case req.leading {
              Some(leading) -> [#("leading", json.string(leading))]
              None -> []
            },
          ),
          case req.content {
            Some(content) -> [#("content", json.string(content))]
            None -> []
          },
        ),
        case req.tags {
          Some(tags) -> [#("tags", json.array(from: tags, of: json.string))]
          None -> []
        },
      ),
      case req.published_at {
        Some(published_at) -> [#("published_at", json.int(published_at))]
        None -> []
      },
    )

  json.object(fields)
}

fn backoff_ms(retries: Int) -> Int {
  case retries {
    1 -> 50
    2 -> 250
    3 -> 750
    4 -> 1500
    5 -> 3000
    _ -> 5000
  }
}
