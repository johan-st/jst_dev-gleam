import context
import gleam/erlang/os
import gleam/erlang/process
import mist
import repo/repo
import web/router
import wisp
import wisp/wisp_mist

pub fn main() {
  logger_setup()
  wisp.log_debug("creating server context")
  let ctx = context.server_context()
  // let _db = repo.init(ctx)

  wisp.log_debug("creating router")
  // The handle_request function is partially applied with the context to make
  // the request handler function that only takes a request.
  let handler = router.handle_request(_, ctx)

  wisp.log_debug("starting server")
  let assert Ok(_) =
    wisp_mist.handler(handler, ctx.secret_key_base)
    |> mist.new
    |> mist.bind(ctx.host)
    |> mist.port(ctx.port)
    |> mist.start_http

  wisp.log_debug("server started, sleeping forever")
  process.sleep_forever()
}

fn logger_setup() {
  wisp.configure_logger()

  case os.get_env("LOG_LEVEL") {
    // system is unusable (all hands on deck!)
    Ok("emergency") -> wisp.set_logger_level(wisp.EmergencyLevel)

    // indicates a condition that should be corrected immediately (on call)
    Ok("alert") -> wisp.set_logger_level(wisp.AlertLevel)

    // indicates a serious error (triage issue at earliest convenience)
    Ok("critical") -> wisp.set_logger_level(wisp.CriticalLevel)

    // indicates a failure that might impact the system or data integrity (evaluate issue, plan action)
    Ok("error") -> wisp.set_logger_level(wisp.ErrorLevel)

    // indicates a potential problem, action advised (monitor issue, evaluate)
    Ok("warn") -> wisp.set_logger_level(wisp.WarningLevel)

    // might require action (monitor issue)
    Ok("notice") -> wisp.set_logger_level(wisp.NoticeLevel)

    // information abount normal operation (normal operation)
    Ok("info") -> wisp.set_logger_level(wisp.InfoLevel)

    // includes technical details (debugging)
    Ok("debug") -> wisp.set_logger_level(wisp.DebugLevel)

    // if not set..
    _ -> {
      wisp.log_error("No log level set, defaulting to debug")
      wisp.set_logger_level(wisp.DebugLevel)
    }
  }
}
