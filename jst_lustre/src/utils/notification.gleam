import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

pub type NotificationRequest {
  NotificationRequest(message: String)
}

pub type NotificationResponse {
  NotificationResponse(status: String, message: String, id: String)
}

pub fn create_notification_request(message: String) -> NotificationRequest {
  NotificationRequest(message: message)
}

pub fn send_notification(
  msg,
  base_uri: Uri,
  request: NotificationRequest,
) -> Effect(msg) {
  let body = encode_request(request) |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_path("/api/notifications")
  |> request.set_body(body)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(notification_response_decoder(), msg))
}

fn encode_request(request: NotificationRequest) -> Json {
  json.object([#("message", json.string(request.message))])
}

fn notification_response_decoder() -> Decoder(NotificationResponse) {
  use status <- decode.field("status", decode.string)
  use message <- decode.field("message", decode.string)
  use id <- decode.field("id", decode.string)
  decode.success(NotificationResponse(status, message, id))
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
