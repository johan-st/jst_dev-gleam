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
  // target, raw json
  Noop
}

// ---------- Public API ----------

pub fn init(path: String) -> #(Model, Effect(Msg)) {
  let model = Model(path: path, socket: None, retries: 0, subjects: set.new(), kv_buckets: set.new())
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
      let all_messages = list.append(resend_subjects, resend_kv_buckets)
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
      #(model, effect.from(fn(dispatch) { dispatch(Incoming(target, text)) }))
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
