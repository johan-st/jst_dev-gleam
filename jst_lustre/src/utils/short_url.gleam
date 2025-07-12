import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/string
import gleam/result
import lustre/effect.{type Effect}
import utils/http.{type HttpError}

// SHORT URL TYPES ------------------------------------------------------------

pub type ShortUrl {
  ShortUrl(
    id: String,
    short_code: String,
    target_url: String,
    created_by: String,
    created_at: String,
    updated_at: String,
    access_count: Int,
    is_active: Bool,
  )
}

pub type ShortUrlCreateRequest {
  ShortUrlCreateRequest(
    short_code: String,
    target_url: String,
    created_by: String,
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

// DECODERS -------------------------------------------------------------------

fn short_url_decoder() -> Decoder(ShortUrl) {
  use id <- decode.field("id", decode.string)
  use short_code <- decode.field("shortCode", decode.string)
  use target_url <- decode.field("targetUrl", decode.string)
  use created_by <- decode.field("createdBy", decode.string)
  use created_at <- decode.field("createdAt", decode.string)
  use updated_at <- decode.field("updatedAt", decode.string)
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
    #("createdBy", json.string(req.created_by)),
  ])
}

// API CALLS ------------------------------------------------------------------

pub fn create_short_url(
  msg,
  base_url: String,
  req: ShortUrlCreateRequest,
) -> Effect(msg) {
  let url = base_url <> "/api/shorturl/create"
  let body = encode_short_url_create_request(req)
  http.post(url, body, http.expect_json(short_url_decoder(), msg))
}

pub fn list_short_urls(
  msg,
  base_url: String,
  created_by: String,
  limit: Int,
  offset: Int,
) -> Effect(msg) {
  let url = base_url <> "/api/shorturl/list"
  let body = json.object([
    #("createdBy", json.string(created_by)),
    #("limit", json.int(limit)),
    #("offset", json.int(offset)),
  ])
  http.post(url, body, http.expect_json(short_url_list_response_decoder(), msg))
}

pub fn delete_short_url(
  msg,
  base_url: String,
  id: String,
) -> Effect(msg) {
  let url = base_url <> "/api/shorturl/delete"
  let body = json.object([
    #("id", json.string(id)),
  ])
  http.post(url, body, http.expect_text(msg))
} 