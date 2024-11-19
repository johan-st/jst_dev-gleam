import gleam/erlang/os
import gleam/int
import gleam/result
import wisp

pub type Context {
  Context(
    secret_key_base: String,
    static_directory: String,
    client_directory: String,
    host: String,
    port: Int,
  )
}

pub fn server_context() -> Context {
  let assert Ok(priv_directory) = wisp.priv_directory("server")

  let secret_key_base = case os.get_env("SECRET_KEY_BASE") {
    Ok(secret_key_base) -> secret_key_base
    _ -> {
      wisp.log_warning(
        "SECRET_KEY_BASE not set, generating a random one. This will invalidate all existing sessions.",
      )
      wisp.random_string(64)
    }
  }

  let assert Ok(host) =
    os.get_env("HOST")
    |> result.or(Ok("localhost"))

  let assert Ok(port) =
    os.get_env("PORT")
    |> result.map(int.parse)
    |> result.flatten
    |> result.or(Ok(8000))

  Context(
    secret_key_base: secret_key_base,
    static_directory: priv_directory <> "/static",
    client_directory: priv_directory <> "/client",
    host: host,
    port: port,
  )
}
