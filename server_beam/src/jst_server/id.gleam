pub fn random_hex(bytes: Int) -> String {
  random_hex_ffi(bytes)
}

pub fn random_short_code(length: Int) -> String {
  random_short_code_ffi(length)
}

@external(erlang, "jst_server_id_ffi", "random_hex")
fn random_hex_ffi(bytes: Int) -> String

@external(erlang, "jst_server_id_ffi", "random_short_code")
fn random_short_code_ffi(length: Int) -> String
