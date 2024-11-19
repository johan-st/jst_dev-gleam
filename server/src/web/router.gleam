import context.{type Context}
import gleam/http.{Get}
import web/api
import web/web
import wisp.{type Request, type Response, File}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req, ctx)
  case wisp.path_segments(req) {
    ["api"] -> api_docs(req, ctx)
    ["api", ..rest] -> api.router(remaing_path: rest, request: req, context: ctx)
    _ -> spa(req, ctx)
  }
}

fn spa(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  wisp.ok()
  |> wisp.set_body(File(ctx.client_directory <> "/index.html"))
}

fn api_docs(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  wisp.ok()
  |> wisp.set_body(File(ctx.static_directory <> "/api_docs.html"))
}
