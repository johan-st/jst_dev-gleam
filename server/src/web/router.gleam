import gleam/http.{Get}
import web/web.{type Context}
import wisp.{type Request, type Response, File}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req, ctx)
  case wisp.path_segments(req) {
    _ -> index(req, ctx)
  }
}

fn index(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  wisp.ok()
  |> wisp.set_body(File(ctx.static_directory <> "/index.html"))
}
