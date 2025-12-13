import gleam/dynamic/decode.{type Decoder}
import gleam/json

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

pub fn decoder() -> Decoder(ShortUrl) {
  use id <- decode.field("id", decode.string)
  use short_code <- decode.field("shortCode", decode.string)
  use target_url <- decode.field("targetUrl", decode.string)
  use created_by <- decode.field("createdBy", decode.string)
  use created_at <- decode.field("createdAt", decode.int)
  use updated_at <- decode.field("updatedAt", decode.int)
  use access_count <- decode.field("accessCount", decode.int)
  use is_active <- decode.field("isActive", decode.bool)
  decode.success(ShortUrl(
    id:,
    short_code:,
    target_url:,
    created_by:,
    created_at:,
    updated_at:,
    access_count:,
    is_active:,
  ))
}

pub fn encoder(url: ShortUrl) -> json.Json {
  json.object([
    #("id", json.string(url.id)),
    #("shortCode", json.string(url.short_code)),
    #("targetUrl", json.string(url.target_url)),
    #("createdBy", json.string(url.created_by)),
    #("createdAt", json.int(url.created_at)),
    #("updatedAt", json.int(url.updated_at)),
    #("accessCount", json.int(url.access_count)),
    #("isActive", json.bool(url.is_active)),
  ])
}
