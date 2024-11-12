//// Commmon types and functions shared between the server and the client.

///  3 cahracters (0-9, a-z, A-Z) provides 216 000 unique ids. Sufficient for personal use.
pub type UrlShort {
    UrlShort (
        id: String, // 3 characters (0-9, a-z, A-Z)
        target: String, // URL
        expires: Int, // Unix timestamp
    )
}