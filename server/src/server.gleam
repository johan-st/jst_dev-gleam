import gleam/erlang/os
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import mist
import web/router
import web/web.{Context}
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()
  // TODO: set a environment variable to configure the secret key base for consistency between boots and nodes.
  let secret_key_base = wisp.random_string(64)

  // A context is constructed holding the static directory path.
  let static_directory = static_directory()
  let assert Ok(host) =
    os.get_env("HOST")
    |> result.or(Ok("localhost"))
  let assert Ok(port) =
    os.get_env("PORT")
    |> result.map(int.parse)
    |> result.flatten
    |> result.or(Ok(8000))
  let ctx = Context(static_directory: static_directory, host: host, port: port)

  wisp.log_info("Starting server")
  io.debug(ctx)

  // The handle_request function is partially applied with the context to make
  // the request handler function that only takes a request.
  let handler = router.handle_request(_, ctx)

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.bind(ctx.host)
    |> mist.port(ctx.port)
    |> mist.start_http

  process.sleep_forever()
}

pub fn static_directory() -> String {
  // The priv directory is where we store non-Gleam and non-Erlang files,
  // including static assets to be served.
  // This function returns an absolute path and works both in development and in
  // production after compilation.
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  priv_directory <> "/static"
}
