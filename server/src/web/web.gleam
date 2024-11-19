import context
import wisp

pub fn middleware(
  req: wisp.Request,
  ctx: context.Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  // let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use <- wisp.serve_static(req, under: "/", from: ctx.client_directory)
  use <- wisp.serve_static(req, under: "/", from: ctx.static_directory)

  handle_request(req)
}
