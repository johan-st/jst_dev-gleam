import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import lustre/effect.{type Effect}
import lustre_websocket as ws

pub type OutMsg {
  OnOpen(ws.WebSocket)
  OnMessage(String)
  OnClosed
  OnError(String)
}

pub fn connect(path: String) -> Effect(OutMsg) {
  ws.init(path, fn(ev) {
    case ev {
      ws.InvalidUrl -> OnError("invalid_url")
      ws.OnOpen(sock) -> OnOpen(sock)
      ws.OnTextMessage(txt) -> OnMessage(txt)
      ws.OnBinaryMessage(_) -> OnError("binary_not_supported")
      ws.OnClose(_) -> OnClosed
    }
  })
}

pub fn sub(sock: ws.WebSocket, subject: String) -> Effect(OutMsg) {
  ws.send(sock, encode_envelope("sub", subject, None, dict.new()))
}

pub fn unsub(sock: ws.WebSocket, subject: String) -> Effect(OutMsg) {
  ws.send(sock, encode_envelope("unsub", subject, None, dict.new()))
}

pub fn kv_sub(
  sock: ws.WebSocket,
  bucket: String,
  pattern: option.Option(String),
) -> Effect(OutMsg) {
  let data = case pattern {
    Some(p) -> dict.from_list([#("pattern", json.string(p))])
    None -> dict.new()
  }
  ws.send(sock, encode_envelope("kv_sub", bucket, None, data))
}

pub fn js_sub(
  sock: ws.WebSocket,
  stream: String,
  start_seq: Int,
  batch: Int,
  filter: String,
) -> Effect(OutMsg) {
  let data =
    dict.from_list([
      #("start_seq", json.int(start_seq)),
      #("batch", json.int(batch)),
      #("filter", json.string(filter)),
    ])
  ws.send(sock, encode_envelope("js_sub", stream, None, data))
}

pub fn cmd(
  sock: ws.WebSocket,
  target: String,
  inbox: String,
  payload: json.Json,
) -> Effect(OutMsg) {
  let data = payload
  ws.send(sock, encode_envelope_with_json("cmd", target, Some(inbox), data))
}

fn encode_envelope(
  op: String,
  target: String,
  inbox: option.Option(String),
  data: dict.Dict(String, json.Json),
) -> String {
  encode_envelope_with_json(op, target, inbox, json.object(dict.to_list(data)))
}

fn encode_envelope_with_json(
  op: String,
  target: String,
  inbox: option.Option(String),
  data: json.Json,
) -> String {
  let base = [
    #("op", json.string(op)),
    #("target", json.string(target)),
    #("data", data),
  ]
  let fields = case inbox {
    Some(i) -> [#("inbox", json.string(i)), ..base]
    None -> base
  }
  json.to_string(json.object(fields))
}
