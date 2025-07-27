import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// Validates a target URL string and returns validation result with optional error message
pub fn validate_target_url(url_string: String) -> #(Bool, Option(String)) {
  case url_string {
    "" -> #(False, Some("URL is required"))
    _ -> {
      case uri.parse(url_string) {
        Ok(parsed_uri) -> {
          case parsed_uri.scheme, parsed_uri.host {
            Some(scheme), Some(host) -> {
              case scheme {
                "http" | "https" -> {
                  case validate_host(host) {
                    True -> #(True, None)
                    False -> #(
                      False,
                      Some(
                        "Host must be a valid domain with a TLD (e.g., example.com)",
                      ),
                    )
                  }
                }
                _ -> #(False, Some("URL must use http or https protocol"))
              }
            }
            None, Some(_) -> #(
              False,
              Some("URL must include a protocol (http or https)"),
            )
            Some(_), None -> #(False, Some("URL must include a host"))
            None, None -> #(
              False,
              Some("URL must include both protocol and host"),
            )
          }
        }
        Error(_) -> #(False, Some("Invalid URL format"))
      }
    }
  }
}

/// Validates a host string to ensure it's a proper domain with TLD
pub fn validate_host(host: String) -> Bool {
  case host {
    "" -> False
    _ -> {
      // Check if host contains at least one dot (for TLD)
      case string.contains(host, ".") {
        True -> {
          let parts = string.split(host, ".")
          case list.length(parts) >= 2 {
            True -> {
              // Check that no part is empty and last part (TLD) is at least 2 characters
              case list.all(parts, fn(part) { string.length(part) > 0 }) {
                True -> {
                  case list.last(parts) {
                    Ok(tld) -> string.length(tld) >= 2
                    Error(_) -> False
                  }
                }
                False -> False
              }
            }
            False -> False
          }
        }
        False -> False
      }
    }
  }
} 