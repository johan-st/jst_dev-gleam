import carpenter/table
import gleam/list
import short_url/types.{type ShortUrl, Public}

pub opaque type Repo {
  /// TODO: read up on ETS
  Mem(short_urls: List(ShortUrl))
  Ets(
    short_urls: table.Set(String, ShortUrl),
    //   cache: table.Set(Uri, String)
  )
}

pub type RepoError {
  FailedToStore
  FailedToRetrieve
}

fn new_repo_mem() -> fn() -> Repo {
  let repo: Repo = Mem([])
  fn() { repo }
}

pub fn init() -> fn() -> Repo {
  //   let assert Ok(short_urls) =
  //     table.build("short_urls")
  //     |> table.privacy(table.Public)
  //     |> table.write_concurrency(table.AutoWriteConcurrency)
  //     |> table.read_concurrency(True)
  //     |> table.decentralized_counters(True)
  //     |> table.compression(False)
  //     |> table.set
  //   Ets(short_urls: short_urls)
  new_repo_mem()
}

pub fn add_url(url: ShortUrl, repo: Repo) -> Result(Repo, RepoError) {
  case repo {
    Mem(short_urls: urls) -> {
      Ok(Mem(short_urls: [url, ..urls]))
    }
    Ets(short_urls: urls) -> {
      urls
      |> table.insert([#(url.short, url)])
      Ok(repo)
    }
  }
}

pub fn all_public(repo) -> Result(List(ShortUrl), RepoError) {
  case repo {
    Mem(short_urls: urls) -> {
      urls
      |> list.filter(fn(u) {
        case u {
          Public(_, _) -> True
        }
      })
      |> Ok
    }

    _ -> Error(FailedToRetrieve)
  }
}
// MIGRATIONS (glibsql/ sqlite)

// const short_urls_v0 = "CREATE TABLE  IF NOT EXISTS short_urls(
//         id INTEGER PRIMARY KEY,
//         original TEXT CHECK(length(original) > 4 AND length(original) < 512),
//         short TEXT CHECK(length(short) = 4),
//         expires_at TEXT -- Considered as DATETIME in ISO8601 format ('YYYY-MM-DD HH:MM:SS')
//     );"
