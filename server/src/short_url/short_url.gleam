import context.{type Context}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/uri.{type Uri, Uri}
import repo/repo.{type Repo}
import short_url/types.{type ShortUrl, Public}

import wisp

pub fn list_public(repo: Repo) -> Result(List(ShortUrl), Nil) {
  repo.all_public(repo)
  |> result.nil_error
}

pub type ShortUrlError {
  BadUrl
  FailedToStore
}

pub fn create_public(
  desired_url long: String,
  server_context ctx: Context,
) -> Result(ShortUrl, ShortUrlError) {
  case is_compliant(long) {
    True -> store(long, ctx.repo())
    False -> Error(BadUrl)
  }
}

/// Check if the URL-string matches the expected format and is compliant with current settings. 
pub fn is_compliant(url: String) -> Bool {
  let allowed_schemes = ["http", "https", "ftp"]
  case uri.parse(url) {
    Ok(Uri(
      scheme: Some(scheme),
      userinfo: _,
      host: Some(host),
      port: _,
      path: _,
      query: _,
      fragment: _,
    ))
      if host != ""
    -> list.contains(allowed_schemes, scheme)
    _ -> False
  }
}

// REPO

fn store(url: String, repo: Repo) -> Result(ShortUrl, ShortUrlError) {
  let short = Public(wisp.random_string(4), url)
  case repo.add_url(short, repo) {
    Ok(_) -> Ok(short)
    _ -> Error(FailedToStore)
  }
}
