import dot_env
import dot_env/env
import gleam/io
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import short_url/short_url

pub fn main() {
  gleeunit.main()
}

// pub fn tmp_test() {
//   io.debug("tmp_test")
//   io.debug(string.inspect(env.get_string("TURSO_PUBLIC_URL")))
//   dot_env.new()
//   |> dot_env.set_path("./.env")
//   |> dot_env.set_debug(True)
//   |> dot_env.load()
//   io.debug(string.inspect(env.get_string("TURSO_PUBLIC_URL")))
// }

// gleeunit test functions end in `_test`
pub fn is_uri_comliant_test() {
  let compliant = [
    "https://example.com", "http://example.com", "ftp://example.com",
    "https://example.com/a/b/c", "https://example.com/a/b/c?query=true",
    "https://example.com/a/b/c?query=true#fragment",
  ]

  compliant
  |> list.map(short_url.is_compliant)
  |> list.map(should.be_true)
}

pub fn is_uri_non_comliant_test() {
  let non_compliant = ["example", "jst.dev", "http://", "https://", "ftp://"]
  non_compliant
  |> list.map(short_url.is_compliant)
  |> list.map(should.be_false)
}
