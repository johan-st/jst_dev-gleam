import gleam/string_builder
import web/web.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use _req <- web.middleware(req, ctx)

  case wisp.path_segments(req) {
    ["assets"] -> {
      let body = string_builder.from_string("404 - Not Found")
      wisp.response(404)
      |> wisp.string_builder_body(body)
    }
    _ -> {
      wisp.response(200)
      |> wisp.set_body(wisp.File(ctx.static_directory <> "/index.html"))
    }
  }
}
