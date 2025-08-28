import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

pub type ChatRequestRequest {
  ChatRequestRequest(client_msg_id: String)
}

pub type ChatRequestResponse {
  ChatRequestResponse(status: String, message: String, id: String)
}

pub fn create_chat_request(client_msg_id: String) -> ChatRequestRequest {
  ChatRequestRequest(client_msg_id: client_msg_id)
}

pub fn send_chat_request(
  msg,
  base_uri: Uri,
  request: ChatRequestRequest,
) -> Effect(msg) {
  let body = encode_request(request) |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_path("/api/contact/request")
  |> request.set_body(body)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(chat_request_response_decoder(), msg))
}

fn encode_request(request: ChatRequestRequest) -> Json {
  json.object([#("client_msg_id", json.string(request.client_msg_id))])
}

fn chat_request_response_decoder() -> Decoder(ChatRequestResponse) {
  use status <- decode.field("status", decode.string)
  use message <- decode.field("message", decode.string)
  use id <- decode.field("id", decode.string)
  decode.success(ChatRequestResponse(status, message, id))
}

fn add_base_uri(req, base_uri: Uri) {
  let req = case base_uri.scheme {
    Some("http") -> req |> request.set_scheme(gleam_http.Http)
    Some("https") -> req |> request.set_scheme(gleam_http.Https)
    _ -> req |> request.set_scheme(gleam_http.Https)
  }

  let req = case base_uri.host {
    Some(host) -> req |> request.set_host(host)
    None -> req
  }

  let req = case base_uri.port {
    Some(port) -> req |> request.set_port(port)
    None -> req
  }

  req
}