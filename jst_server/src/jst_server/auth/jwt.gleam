import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string

import jst_server/base64url
import jst_server/json

pub type JwtError {
  JwtError(message: String)
}

pub type Claims {
  Claims(
    subject: String,
    permissions: List(String),
    expires_at: Int,
  )
}

pub fn verify_hs512(
  secret: BitArray,
  audience: String,
  token: String,
) -> Result(Claims, JwtError) {
  case string.split(token, ".") {
    [h64, p64, s64] -> {
      let signing_input = h64 <> "." <> p64
      let expected_sig = hmac_sha512(secret, bit_array.from_string(signing_input))
      case base64url.encode(expected_sig) |> bit_array.to_string {
        Error(_) -> Error(JwtError("signature encoding failed"))
        Ok(expected) ->
          case expected == s64 {
            False -> Error(JwtError("invalid signature"))
            True ->
              case base64url.decode(bit_array.from_string(h64)) {
                Error(_) -> Error(JwtError("invalid header b64"))
                Ok(header_bits) ->
                  case base64url.decode(bit_array.from_string(p64)) {
                    Error(_) -> Error(JwtError("invalid payload b64"))
                    Ok(payload_bits) ->
                      case json.decode_bits(header_bits) {
                        Error(e) -> Error(JwtError(e.message))
                        Ok(header_dyn) ->
                          case json.decode_bits(payload_bits) {
                            Error(e) -> Error(JwtError(e.message))
                            Ok(payload_dyn) ->
                              case get_string(header_dyn, "alg") {
                                Error(e) -> Error(e)
                                Ok(alg) ->
                                  case alg == "HS512" {
                                    False -> Error(JwtError("unexpected alg: " <> alg))
                                    True ->
                                      case get_string(payload_dyn, "sub") {
                                        Error(e) -> Error(e)
                                        Ok(subject) ->
                                          case get_int(payload_dyn, "exp") {
                                            Error(e) -> Error(e)
                                            Ok(exp) -> {
                                              let perms =
                                                get_string_list(payload_dyn, "perm")
                                                |> result.unwrap([])

                                              case ensure_audience(payload_dyn, audience) {
                                                Error(e) -> Error(e)
                                                Ok(_) ->
                                                  Ok(Claims(subject: subject, permissions: perms, expires_at: exp))
                                              }
                                            }
                                          }
                                      }
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
    }
    _ -> Error(JwtError("invalid token format"))
  }
}

fn ensure_audience(payload: Dynamic, required: String) -> Result(Nil, JwtError) {
  // aud can be string or array of strings in JWT
  case get_string(payload, "aud") {
    Ok(aud) ->
      case string.contains(aud, required) {
        True -> Ok(Nil)
        False -> Error(JwtError("invalid audience"))
      }
    Error(_) -> {
      case get_string_list(payload, "aud") {
        Ok(auds) ->
          case list.any(auds, fn(a) { a == required }) {
            True -> Ok(Nil)
            False -> Error(JwtError("invalid audience"))
          }
        Error(_) -> Error(JwtError("missing audience"))
      }
    }
  }
}

// ---- dynamic helpers (jiffy returns maps) -------------------------------------

fn get_string(obj: Dynamic, key: String) -> Result(String, JwtError) {
  case decode.run(obj, decode.field(key, decode.string, decode.success)) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(JwtError("missing/invalid field: " <> key))
  }
}

fn get_int(obj: Dynamic, key: String) -> Result(Int, JwtError) {
  case decode.run(obj, decode.field(key, decode.int, decode.success)) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(JwtError("missing/invalid field: " <> key))
  }
}

fn get_string_list(obj: Dynamic, key: String) -> Result(List(String), JwtError) {
  case decode.run(obj, decode.field(key, decode.list(decode.string), decode.success)) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(JwtError("missing/invalid field: " <> key))
  }
}

@external(erlang, "jst_server_ffi", "hmac_sha512")
fn hmac_sha512(key: BitArray, data: BitArray) -> BitArray


