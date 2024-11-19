import gleam/option.{ Some}
import gleam/uri.{Uri}

import wisp

pub type ShortUrl {
  Public(id: Int, long: String, short: String)
}

pub fn list_public() -> Result(List(ShortUrl), Nil) {
  Ok([
    Public(1, "https://www.example.com/1", wisp.random_string(4)),
    Public(2, "https://www.example.com/2", wisp.random_string(4)),
    Public(3, "https://www.example.com/3", wisp.random_string(4)),
    Public(4, "https://www.example.com/4", wisp.random_string(4)),
    Public(5, "https://www.example.com/5", wisp.random_string(4)),
    Public(6, "https://www.example.com/6", wisp.random_string(4)),
    Public(7, "https://www.example.com/7", wisp.random_string(4)),
  ])
}

pub type ShortUrlError {
  BadUrl
}

//   Uri(
//     scheme: Some("https"),
//     userinfo: None,
//     host: Some("example.com"),
//     port: Some(1234),
//     path: "/a/b",
//     query: Some("query=true"),
//     fragment: Some("fragment")
//   )
pub fn create(desired_url long: String) -> Result(ShortUrl, ShortUrlError) {
  case uri.parse(long) {
    Ok(Uri(
      scheme: Some(_),
      userinfo: _,
      host: Some(_),
      port: _,
      path: _,
      query: _,
      fragment: _,
    )) -> {
      Ok(Public(8, long, wisp.random_string(4)))
    }
    _ -> {
      wisp.log_debug("Failed to parse URL: " <> long)
      Error(BadUrl)
    }
  }
}
