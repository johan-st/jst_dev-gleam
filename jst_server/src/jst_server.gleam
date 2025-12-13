import gleam/io
import jst_server/app
import jst_server/nats/enats

pub fn main() -> Nil {
  io.println("starting jst_server (" <> enats.version_hint() <> ")")
  app.start()
}
