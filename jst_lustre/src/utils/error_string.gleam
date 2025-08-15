import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import utils/http

// utils/http

pub fn http_error(error: http.HttpError) -> String {
  case error {
    http.BadUrl(url) -> {
      "bad url: " <> url
    }
    http.InternalServerError(body) -> {
      "internal server error: " <> body
    }
    http.JsonError(error) -> {
      "json error\n" <> json_error(error)
    }
    http.NotFound -> {
      "not found"
    }
    http.Unauthorized -> {
      "unauthorized"
    }
    http.OtherError(code, body) -> {
      "other error: " <> int.to_string(code) <> " " <> body
    }
    http.NetworkError -> {
      "network error"
    }
  }
}

// gleam/json

pub fn json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> {
      "unexpected end of input"
    }
    json.UnexpectedByte(byte) -> {
      "unexpected byte: " <> byte
    }
    json.UnexpectedSequence(expected) -> {
      "unexpected sequence: " <> expected
    }
    json.UnexpectedFormat(errors) -> {
      "unexpected format\n" <> list.map(errors, fn(error) { 
        case error {
          dynamic.DecodeError(expected, found, path) -> 
            decode.DecodeError(expected: expected, found: found, path: path)
        }
      }) |> decode_error_list
    }
    json.UnableToDecode(errors) -> {
      "unable to decode\n" <> decode_error_list(errors)
    }
  }
}



fn decode_error_list(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> {
      ""
    }
    [error, ..errors] -> {
      decode_error(error) <> "\n" <> decode_error_list(errors)
    }
  }
}

fn decode_error(error: decode.DecodeError) -> String {
  case error {
    decode.DecodeError(expected, found, path) -> {
      "expected: "
      <> expected
      <> ", found: "
      <> found
      <> ", path: "
      <> string.join(path, "/")
    }
  }
}
