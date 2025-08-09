import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

pub type NotificationRequest {
  NotificationRequest(
    title: String,
    message: String,
    category: String,
    priority: String,
    ntfy_topic: String,
    data: List(#(String, String)),
  )
}

pub type NotificationResponse {
  NotificationResponse(status: String, message: String, id: String)
}

pub fn create_notification_request(
  title: String,
  message: String,
  category: String,
  priority: String,
  ntfy_topic: String,
  data: List(#(String, String)),
) -> NotificationRequest {
  NotificationRequest(
    title: title,
    message: message,
    category: category,
    priority: priority,
    ntfy_topic: ntfy_topic,
    data: data,
  )
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
  let data_object = case request.data {
    [] -> json.object([])
    data -> {
      let data_pairs =
        list.map(data, fn(pair) {
          case pair {
            #(key, value) -> #(key, json.string(value))
          }
        })
      json.object(data_pairs)
    }
  }

  json.object([
    #("title", json.string(request.title)),
    #("message", json.string(request.message)),
    #("category", json.string(request.category)),
    #("priority", json.string(request.priority)),
    #("ntfy_topic", json.string(request.ntfy_topic)),
    #("data", data_object),
  ])
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
