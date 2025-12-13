import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/string

pub type JsonError {
  JsonError(message: String)
}

pub fn decode_bits(bits: BitArray) -> Result(dynamic.Dynamic, JsonError) {
  case decode.run(json_decode(bits), ok_dynamic_decoder()) {
    Ok(value) -> Ok(value)
    Error(errs) -> Error(JsonError("json decode failed: " <> string.inspect(errs)))
  }
}

pub fn encode_dynamic(value: dynamic.Dynamic) -> Result(BitArray, JsonError) {
  case decode.run(json_encode(value), ok_bits_decoder()) {
    Ok(bits) -> Ok(bits)
    Error(errs) -> Error(JsonError("json encode failed: " <> string.inspect(errs)))
  }
}

fn ok_dynamic_decoder() -> decode.Decoder(dynamic.Dynamic) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.dynamic, decode.success)
    _ -> decode.failure(dynamic.int(0), "expected {ok, term}")
  }
}

fn ok_bits_decoder() -> decode.Decoder(BitArray) {
  use tag <- decode.subfield([0], atom.decoder())
  case atom.to_string(tag) {
    "ok" -> decode.subfield([1], decode.bit_array, decode.success)
    _ -> decode.failure(<<>>, "expected {ok, bit_array}")
  }
}

@external(erlang, "jst_server_ffi", "json_decode")
fn json_decode(bits: BitArray) -> dynamic.Dynamic

@external(erlang, "jst_server_ffi", "json_encode")
fn json_encode(term: dynamic.Dynamic) -> dynamic.Dynamic


