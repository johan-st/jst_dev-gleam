import context.{type Context}
import gleam/dynamic.{type DecodeError, decode1, field, string}
import gleam/http.{Get, Post}
import gleam/io
import gleam/list
import gleam/string
import gleam/string_builder.{type StringBuilder}
import short_url.{BadUrl}
import wisp.{type Request, type Response}

pub fn router(
  request req: Request,
  context _ctx: Context,
  remaing_path path: List(String),
) -> Response {
  io.println(string.inspect(req))

  case path {
    ["v1", "short_urls"] ->
      case req.method {
        Get -> {
          req
          |> wisp.set_max_body_size(0)
          |> wisp.set_max_files_size(0)
          case short_url.list_public() {
            Ok(short_urls) ->
              wisp.ok() |> wisp.string_body(string.inspect(short_urls))
            Error(_) -> wisp.internal_server_error()
          }
        }
        Post -> {
          // Max body of 1 MB 
          // and Disable file uploads (needed?)
          let req =
            req
            |> wisp.set_max_body_size(1024 * 2)
            |> wisp.set_max_files_size(0)
          use json <- wisp.require_json(req)

          let decoder =
            decode1(PostRoot, field("url_to_shorten", dynamic.string))

          case decoder(json) {
            Ok(PostRoot(desired_url)) -> {
              case short_url.create(desired_url) {
                Ok(short) ->
                  wisp.created() |> wisp.string_body(string.inspect(short))
                Error(BadUrl) ->
                  wisp.bad_request() |> wisp.string_body("Invalid URL")
              }
            }
            Error(decode_errors) -> {
              wisp.log_notice(string.inspect(decode_errors))
              let body =
                string_builder.from_string(
                  "Invalid body.Failed to decode JSON body:\n",
                )
                |> append_decode_errors(decode_errors)
              wisp.bad_request()
              |> wisp.string_builder_body(body)
            }
          }
        }
        _ -> wisp.method_not_allowed(allowed: [Get, Post])
      }
    ["v1", "short_urls", id] -> todo as { "short_urls_id got id" <> id }
    // short_urls_id(req, id) 
    _ -> wisp.not_found()
  }
}

type RequestBody {
  PostRoot(url_to_shorten: String)
}

fn append_decode_errors(
  builder: StringBuilder,
  errors: List(DecodeError),
) -> StringBuilder {
  errors
  |> list.map(decode_error_to_string)
  |> list.intersperse("\n")
  |> list.fold(builder, string_builder.append)
}

fn decode_error_to_string(error: DecodeError) -> String {
  //   "@foo.bar: expected String, got Integer"
  "@\""
  <> string.join(error.path, ".")
  <> "\": expected "
  <> error.expected
  <> ", got "
  <> error.found
}
