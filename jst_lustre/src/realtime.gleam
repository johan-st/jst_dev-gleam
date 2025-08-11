import gleam/json
import gleam/option.{None, Some}
import gleam/list
import gleam/map
import gleam/int
import gleam/string
import gleam/io
import lustre

pub type Event {
  Connected
  Disconnected
  Message(String, json.Json)
  CommandReply(String, json.Json)
  CapabilitiesUpdate(json.Json)
}

pub type Msg {
  Connect
  ConnectedEvent
  DisconnectedEvent
  Subscribe(String)
  Unsubscribe(String)
  KVSubscribe(String)
  KVSubscribeWithPattern(String, String)
  JSSubscribe(String, Int, Int)
  JSSubscribeWithFilter(String, Int, Int, String)
  JSResume(String, Int, Int, String)
  Command(String, json.Json, String)
  WsIncoming(String)
}

pub type Model {
  Model(
    socket: Option(lustre.WebSocket),
    subs: List(String),
    kv_subs: List(String),
    js_subs: List(#(String, Int, Int, String)),
    pending_cmds: map.Map(String, fn(json.Json) -> Msg)
  )
}

pub fn init() -> Model {
  Model(None, [], [], [], map.new())
}

pub fn update(model: Model, msg: Msg) -> #(Model, Option(Event)) {
  case msg {
    Connect -> {
      let url = "/ws" // same origin; include cookies for auth
      case lustre.websocket_connect(url, WsIncoming) {
        Ok(sock) ->
          // resubscribe
          list.each(model.subs, fn s {
            send(model.socket, json.object([
              #("op", json.string("sub")), #("target", json.string(s))
            ]))
          })
          list.each(model.kv_subs, fn b {
            send(model.socket, json.object([
              #("op", json.string("kv_sub")), #("target", json.string(b))
            ]))
          })
          list.each(model.js_subs, fn #(stream, start_seq, batch, filter) {
            send(model.socket, json.object([
              #("op", json.string("js_sub")), #("target", json.string(stream)),
              #("data", json.object([
                #("start_seq", json.int(start_seq)), #("batch", json.int(batch)), #("filter", json.string(filter))
              ]))
            ]))
          })
          #(Model(Some(sock), model.subs, model.kv_subs, model.js_subs, model.pending_cmds), Some(Connected))
        Error(e) -> {
          io.debug("WS connect error: " <> e)
          #(Model(None, model.subs, model.kv_subs, model.js_subs, model.pending_cmds), Some(Disconnected))
        }
      }
    }

    ConnectedEvent -> #(model, Some(Connected))

    DisconnectedEvent -> #(Model(None, model.subs, model.kv_subs, model.js_subs, model.pending_cmds), Some(Disconnected))

    Subscribe(subject) -> {
      send(model.socket, json.object([
        #("op", json.string("sub")), #("target", json.string(subject))
      ]))
      #(Model(model.socket, [subject, ..model.subs], model.kv_subs, model.js_subs, model.pending_cmds), None)
    }

    Unsubscribe(subject) -> {
      send(model.socket, json.object([
        #("op", json.string("unsub")), #("target", json.string(subject))
      ]))
      #(Model(model.socket, list.filter(model.subs, fn s { s != subject }), model.kv_subs, model.js_subs, model.pending_cmds), None)
    }

    KVSubscribe(bucket) -> {
      send(model.socket, json.object([
        #("op", json.string("kv_sub")), #("target", json.string(bucket))
      ]))
      #(Model(model.socket, model.subs, [bucket, ..model.kv_subs], model.js_subs, model.pending_cmds), None)
    }

    KVSubscribeWithPattern(bucket, pattern) -> {
      send(model.socket, json.object([
        #("op", json.string("kv_sub")), #("target", json.string(bucket)),
        #("data", json.object([#("pattern", json.string(pattern))]))
      ]))
      #(Model(model.socket, model.subs, [bucket, ..model.kv_subs], model.js_subs, model.pending_cmds), None)
    }

    JSSubscribe(stream, start_seq, batch) -> {
      send(model.socket, json.object([
        #("op", json.string("js_sub")), #("target", json.string(stream)),
        #("data", json.object([#("start_seq", json.int(start_seq)), #("batch", json.int(batch)), #("filter", json.string(""))]))
      ]))
      #(Model(model.socket, model.subs, model.kv_subs, [#(stream, start_seq, batch, ""), ..model.js_subs], model.pending_cmds), None)
    }

    JSSubscribeWithFilter(stream, start_seq, batch, filter) -> {
      send(model.socket, json.object([
        #("op", json.string("js_sub")), #("target", json.string(stream)),
        #("data", json.object([#("start_seq", json.int(start_seq)), #("batch", json.int(batch)), #("filter", json.string(filter))]))
      ]))
      #(Model(model.socket, model.subs, model.kv_subs, [#(stream, start_seq, batch, filter), ..model.js_subs], model.pending_cmds), None)
    }

    JSResume(stream, last_seq, batch, filter) -> {
      let start_seq = last_seq + 1
      send(model.socket, json.object([
        #("op", json.string("js_sub")), #("target", json.string(stream)),
        #("data", json.object([#("start_seq", json.int(start_seq)), #("batch", json.int(batch)), #("filter", json.string(filter))]))
      ]))
      #(Model(model.socket, model.subs, model.kv_subs, [#(stream, start_seq, batch, filter), ..model.js_subs], model.pending_cmds), None)
    }

    Command(target, payload, inbox) -> {
      send(model.socket, json.object([
        #("op", json.string("cmd")), #("target", json.string(target)), #("inbox", json.string(inbox)), #("data", payload)
      ]))
      #(model, None)
    }

    WsIncoming(raw) -> {
      case json.decode(raw, json.object([])) {
        Ok(obj) -> {
          let op = json.get(obj, "op") |> result.unwrap(json.string(""))
          let target = json.get(obj, "target") |> result.unwrap(json.string(""))
          let data = json.get(obj, "data") |> result.unwrap(json.null())
          let inbox = json.get(obj, "inbox") |> result.unwrap(json.string(""))

          case op {
            "msg" -> #(model, Some(Message(target, data)))
            "reply" -> #(model, Some(CommandReply(inbox, data)))
            "cap_update" -> #(model, Some(CapabilitiesUpdate(data)))
            _ -> #(model, None)
          }
        }
        Error(_) -> #(model, None)
      }
    }
  }
}

pub fn new_inbox() -> String {
  string.concat(["inbox_", int.to_string(lustre.unique_id())])
}

pub fn send_command(model: Model, target: String, payload: json.Json, cb: fn(json.Json) -> Msg) -> Model {
  let inbox = new_inbox()
  send(model.socket, json.object([
    #("op", json.string("cmd")), #("target", json.string(target)), #("inbox", json.string(inbox)), #("data", payload)
  ]))
  Model(model.socket, model.subs, model.kv_subs, model.js_subs, map.insert(model.pending_cmds, inbox, cb))
}

fn send(sock: Option(lustre.WebSocket), payload: json.Json) {
  case sock {
    Some(s) -> lustre.websocket_send(s, json.stringify(payload))
    None -> io.debug("No socket to send on")
  }
}