import gleam/dynamic/decode.{type Decoder}
import gleam/http as gleam_http
import gleam/http/request
import gleam/json.{type Json}
import gleam/int
import gleam/option.{None, Some}
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import utils/http

// SHORT URL TYPES ------------------------------------------------------------

pub type ShortUrl {
  ShortUrl(
    id: String,
    short_code: String,
    target_url: String,
    created_by: String,
    created_at: Int,
    updated_at: Int,
    access_count: Int,
    is_active: Bool,
  )
}

pub type ShortUrlCreateRequest {
  ShortUrlCreateRequest(
    short_code: String,
    target_url: String,
  )
}

pub type ShortUrlListResponse {
  ShortUrlListResponse(
    short_urls: List(ShortUrl),
    total: Int,
    limit: Int,
    offset: Int,
  )
}

pub type ShortUrlUpdateRequest {
  ShortUrlUpdateRequest(
    id: String,
    is_active: option.Option(Bool),
  )
}

// DECODERS -------------------------------------------------------------------

fn short_url_decoder() -> Decoder(ShortUrl) {
  use id <- decode.field("id", decode.string)
  use short_code <- decode.field("shortCode", decode.string)
  use target_url <- decode.field("targetUrl", decode.string)
  use created_by <- decode.field("createdBy", decode.string)
  use created_at <- decode.field("createdAt", decode.int)
  use updated_at <- decode.field("updatedAt", decode.int)
  use access_count <- decode.field("accessCount", decode.int)
  use is_active <- decode.field("isActive", decode.bool)
  decode.success(ShortUrl(
    id: id,
    short_code: short_code,
    target_url: target_url,
    created_by: created_by,
    created_at: created_at,
    updated_at: updated_at,
    access_count: access_count,
    is_active: is_active,
  ))
}

fn short_url_list_response_decoder() -> Decoder(ShortUrlListResponse) {
  use short_urls <- decode.field("shortUrls", decode.list(short_url_decoder()))
  use total <- decode.field("total", decode.int)
  use limit <- decode.field("limit", decode.int)
  use offset <- decode.field("offset", decode.int)
  decode.success(ShortUrlListResponse(short_urls, total, limit, offset))
}

// ENCODERS -------------------------------------------------------------------

pub fn encode_short_url_create_request(req: ShortUrlCreateRequest) -> Json {
  json.object([
    #("shortCode", json.string(req.short_code)),
    #("targetUrl", json.string(req.target_url)),
  ])
}

pub fn encode_short_url_update_request(req: ShortUrlUpdateRequest) -> Json {
  let base_fields = [
    #("id", json.string(req.id)),
  ]
  
  let fields = case req.is_active {
    Some(is_active) -> [
      #("isActive", json.bool(is_active)),
      ..base_fields
    ]
    None -> base_fields
  }
  
  json.object(fields)
}

// API CALLS ------------------------------------------------------------------

pub fn create_short_url(
  msg,
  base_uri: Uri,
  req: ShortUrlCreateRequest,
) -> Effect(msg) {
  let body = encode_short_url_create_request(req)
    |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_path("/api/url")
  |> request.set_body(body)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(short_url_decoder(), msg))
}

pub fn list_short_urls(
  msg,
  base_uri: Uri,
  limit: Int,
  offset: Int,
) -> Effect(msg) {
  let path = "/api/url?limit=" <> int.to_string(limit) <> "&offset=" <> int.to_string(offset)
  
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_path(path)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(short_url_list_response_decoder(), msg))
}

pub fn delete_short_url(
  msg,
  base_uri: Uri,
  id: String,
) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Delete)
  |> request.set_path("/api/url/" <> id)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_text(msg))
}

pub fn update_short_url(
  msg,
  base_uri: Uri,
  req: ShortUrlUpdateRequest,
) -> Effect(msg) {
  let body = encode_short_url_update_request(req)
    |> json.to_string

  request.new()
  |> request.set_method(gleam_http.Put)
  |> request.set_path("/api/url/" <> req.id)
  |> request.set_body(body)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(short_url_decoder(), msg))
}

pub fn get_short_url(
  msg,
  base_uri: Uri,
  short_code: String,
) -> Effect(msg) {
  request.new()
  |> request.set_method(gleam_http.Get)
  |> request.set_path("/api/url/" <> short_code)
  |> add_base_uri(base_uri)
  |> http.send(http.expect_json(short_url_decoder(), msg))
}

// HELPERS ---------------------------------------------------------------------

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