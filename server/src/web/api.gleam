import context.{type Context}
import gleam/dynamic.{type DecodeError, decode1, field, string}
import gleam/http.{Get, Post}
import gleam/io
import gleam/list
import gleam/string
import gleam/string_builder.{type StringBuilder}
import repo/repo
import short_url/short_url.{BadUrl, FailedToStore}
import wisp.{type Request, type Response}

pub fn router(
  request req: Request,
  context ctx: Context,
  remaing_path path: List(String),
) -> Response {
  wisp.log_debug("api router")
  case path {
    ["v1", "short_urls"] ->
      case req.method {
        Get -> {
          wisp.log_debug("GET")
          req
          |> wisp.set_max_body_size(0)
          |> wisp.set_max_files_size(0)
          case short_url.list_public(ctx.repo()) {
            Ok(short_urls) -> {
              wisp.log_debug("list_public OK")
              wisp.ok() |> wisp.string_body(string.inspect(short_urls))
            }
            Error(Nil) -> {
              wisp.log_debug("list_public failed")
              wisp.internal_server_error()
            }
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
          wisp.log_debug("POST")

          let decoder =
            decode1(PostRoot, field("url_to_shorten", dynamic.string))

          case decoder(json) {
            Ok(PostRoot(desired_url)) -> {
              case short_url.create_public(desired_url, ctx) {
                Ok(short) -> {
                  wisp.log_debug("shortUrl created")
                  case repo.add_url(short, ctx.repo()) {
                    Ok(_repo) -> {
                      wisp.log_debug("add_url OK")
                      wisp.created()
                    }
                    Error(_) -> {
                      wisp.log_debug("add_url Error")
                      wisp.internal_server_error()
                    }
                  }
                }
                Error(BadUrl) ->
                  wisp.bad_request() |> wisp.string_body("Invalid URL")
                Error(FailedToStore) ->
                  wisp.internal_server_error()
                  |> wisp.string_body("Failed to persist URL")
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
