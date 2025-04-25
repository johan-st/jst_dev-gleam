import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
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
    _ -> {
      "unhandled error"
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
      "unexpected format\n" <> dynamic_error_list(errors)
    }
    json.UnableToDecode(errors) -> {
      "unable to decode\n" <> decode_error_list(errors)
    }
  }
}

// gleam/dynamic

fn dynamic_error_list(errors: List(dynamic.DecodeError)) -> String {
  case errors {
    [] -> {
      "no errors"
    }
    [error, ..errors] -> {
      dynamic_error(error) <> "\n" <> dynamic_error_list(errors)
    }
  }
}

fn dynamic_error(error: dynamic.DecodeError) -> String {
  case error {
    dynamic.DecodeError(expected, found, path) -> {
      "expected: "
      <> expected
      <> ", found: "
      <> found
      <> ", path: "
      <> string.join(path, "/")
    }
  }
}

// gleam/dynamic/decode

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
