import gleam/erlang/process
import gleam/int
import gleam/io

import jst_server/config
import jst_server/db
import jst_server/pubsub
import jst_server/web

pub fn main() {
  let conf = config.load()

  // Ensure data directory exists
  let _ = ensure_data_dir(conf.db_path)

  // Connect to SQLite
  let conn = case db.connect(conf.db_path) {
    Ok(conn) -> conn
    Error(db.DbError(msg)) -> {
      io.println_error("Failed to connect to database: " <> msg)
      panic as "database connection failed"
    }
  }

  // Start PubSub actor
  let pubsub = case pubsub.start() {
    Ok(ps) -> ps
    Error(_) -> {
      io.println_error("Failed to start pubsub actor")
      panic as "pubsub start failed"
    }
  }

  io.println("Server starting on port " <> int.to_string(conf.port))
  io.println("Database: " <> conf.db_path)

  let _ = web.start(conn, pubsub, conf)
  process.sleep_forever()
}

fn ensure_data_dir(db_path: String) -> Result(Nil, Nil) {
  case split_path(db_path) {
    "" -> Ok(Nil)
    dir -> make_dir(dir)
  }
}

@external(erlang, "filename", "dirname")
fn split_path(path: String) -> String

@external(erlang, "filelib", "ensure_dir")
fn ensure_dir_erl(path: String) -> a

fn make_dir(dir: String) -> Result(Nil, Nil) {
  let _ = ensure_dir_erl(dir <> "/")
  Ok(Nil)
}
