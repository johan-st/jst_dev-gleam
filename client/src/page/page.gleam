//// The Page module contains the different pages a user can be shown and supporting functions.

import gleam/uri.{type Uri}
import page/url_shortener

/// All the different pages a user can be shown..
pub type Page {
  // probably not needed
  Loading
  Home
  Debug
  Error(msg: String)
  UrlShortener(model: url_shortener.Model)
}

pub fn from_uri(uri: Uri) -> Page {
  case uri.path_segments(uri.path) {
    [] -> Home
    ["url"] -> UrlShortener(url_shortener.Form(""))
    ["dbg"] -> Debug
    _ -> Error("404 - not found")
  }
}
