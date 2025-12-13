import gleam/int
import gleam/result

pub type Config {
  Config(port: Int, jwt_secret: String, web_hash_salt: String, db_path: String)
}

pub fn load() -> Config {
  let jwt_secret = get_env("JWT_SECRET", "dev_secret_change_me")
  let web_hash_salt = get_env("WEB_HASH_SALT", "dev_salt_change_me")
  let db_path = get_env("DB_PATH", "./data/local.db")

  let port =
    get_env("PORT", "8080")
    |> int.parse
    |> result.unwrap(8080)

  Config(
    port: port,
    jwt_secret: jwt_secret,
    web_hash_salt: web_hash_salt,
    db_path: db_path,
  )
}

@external(erlang, "jst_server_env_ffi", "get_env")
fn get_env(name: String, default: String) -> String
