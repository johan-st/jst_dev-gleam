import gleam/json.{type Json}
import gleam/option.{None, Some}
import lustre/effect.{type Effect}
import lustre_websocket as ws

pub type ChatRequestRequest {
  ChatRequestRequest(client_msg_id: String)
}

pub fn create_chat_request(client_msg_id: String) -> ChatRequestRequest {
  ChatRequestRequest(client_msg_id: client_msg_id)
}

pub fn send_chat_request(
  msg,
  websocket: ws.WebSocket,
  request: ChatRequestRequest,
) -> Effect(msg) {
  let body = encode_request(request) |> json.to_string
  
  // Send NATS request via WebSocket
  ws.send(websocket, json.object([
    #("op", json.string("sub")),
    #("target", json.string("chat.request.create")),
    #("data", json.string(body))
  ]))
}

fn encode_request(request: ChatRequestRequest) -> Json {
  json.object([#("client_msg_id", json.string(request.client_msg_id))])
}