//// Commmon types and functions shared between the server and the client.

// import wisp

// ///  3 cahracters (0-9, a-z, A-Z) provides 216 000 unique ids. Sufficient for personal use.
// pub opaque type UrlShort {
//   UrlShort(
//     // 3 characters (0-9, a-z, A-Z)
//     id: String,
//     // URL
//     uri: String,
//     // Unisx timestamp
//     expires: Int,
//   )
// }

// pub fn create_url_short(uri: String) -> Result(UrlShort, Nil) {
//   UrlShort(
//     id: wisp.random_string(3),
//     uri: uri,
//     expires: unix_timestamp() + 60 * 60 * 24 * 7,
//   )
//   |> Ok
// }
