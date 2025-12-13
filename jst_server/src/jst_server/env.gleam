import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}

/// Get an environment variable, returning `None` if unset.
pub fn get(key: String) -> Option(String) {
  case decode.run(getenv(key), decode.string) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

@external(erlang, "jst_server_ffi", "getenv")
fn getenv(key: String) -> Dynamic


