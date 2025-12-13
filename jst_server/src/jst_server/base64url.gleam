import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/string

pub type Base64UrlError {
  Base64UrlError(message: String)
}

pub fn encode(bits: BitArray) -> BitArray {
  base64url_encode(bits)
}

pub fn decode(bits: BitArray) -> Result(BitArray, Base64UrlError) {
  case decode.run(base64url_decode(bits), ok_bits_decoder()) {
    Ok(out) -> Ok(out)
    Error(errs) -> Error(Base64UrlError("base64url decode failed: " <> string.inspect(errs)))
  }
}

fn ok_bits_decoder() -> decode.Decoder(BitArray) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.bit_array, decode.success)
    _ -> decode.failure(<<>>, "expected {ok, bit_array}")
  }
}

@external(erlang, "jst_server_ffi", "base64url_encode")
fn base64url_encode(bits: BitArray) -> BitArray

@external(erlang, "jst_server_ffi", "base64url_decode")
fn base64url_decode(bits: BitArray) -> Dynamic


