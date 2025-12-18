import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

import shared/article.{type Article, Article}
import shared/short_url.{type ShortUrl, ShortUrl}

import sqlight.{type Connection, type Error as SqlError}

pub type DbError {
  DbError(String)
}

fn sql_error_msg(e: SqlError) -> String {
  "SQL error: " <> e.message
}

/// Open a SQLite connection and run migrations.
pub fn connect(path: String) -> Result(Connection, DbError) {
  case sqlight.open(path) {
    Ok(conn) -> {
      case run_migrations(conn) {
        Ok(_) -> Ok(conn)
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

fn run_migrations(conn: Connection) -> Result(Nil, DbError) {
  let migrations = [
    "CREATE TABLE IF NOT EXISTS articles (
      id TEXT PRIMARY KEY,
      slug TEXT UNIQUE NOT NULL,
      revision INTEGER DEFAULT 1,
      author TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      published_at_ms INTEGER,
      title TEXT NOT NULL DEFAULT '',
      subtitle TEXT NOT NULL DEFAULT '',
      leading TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT ''
    )",
    "CREATE TABLE IF NOT EXISTS short_urls (
      id TEXT PRIMARY KEY,
      short_code TEXT UNIQUE NOT NULL,
      target_url TEXT NOT NULL,
      created_by TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      access_count INTEGER DEFAULT 0,
      is_active INTEGER DEFAULT 1
    )",
    "CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      email TEXT NOT NULL DEFAULT '',
      permissions TEXT NOT NULL DEFAULT '[]'
    )",
  ]

  list.try_each(migrations, fn(sql) {
    case sqlight.exec(sql, conn) {
      Ok(_) -> Ok(Nil)
      Error(e) -> Error(DbError(sql_error_msg(e)))
    }
  })
}

// ----------------------------------------------------------------------------
// Articles
// ----------------------------------------------------------------------------

pub fn list_articles(conn: Connection) -> Result(List(Article), DbError) {
  let sql =
    "SELECT id, slug, revision, author, tags, published_at_ms, title, subtitle, leading, content FROM articles"

  case sqlight.query(sql, conn, [], article_decoder()) {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn get_article(
  conn: Connection,
  id: String,
) -> Result(Option(Article), DbError) {
  let sql =
    "SELECT id, slug, revision, author, tags, published_at_ms, title, subtitle, leading, content FROM articles WHERE id = ?"

  case sqlight.query(sql, conn, [sqlight.text(id)], article_decoder()) {
    Ok([art]) -> Ok(Some(art))
    Ok([]) -> Ok(None)
    Ok(_) -> Error(DbError("multiple articles with same id"))
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn upsert_article(conn: Connection, a: Article) -> Result(Article, DbError) {
  let tags_json = json.array(a.tags, json.string) |> json.to_string
  let published = case a.published_at_ms {
    Some(ms) -> sqlight.int(ms)
    None -> sqlight.null()
  }

  let sql =
    "INSERT INTO articles (id, slug, revision, author, tags, published_at_ms, title, subtitle, leading, content)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       slug = excluded.slug,
       revision = excluded.revision,
       author = excluded.author,
       tags = excluded.tags,
       published_at_ms = excluded.published_at_ms,
       title = excluded.title,
       subtitle = excluded.subtitle,
       leading = excluded.leading,
       content = excluded.content"

  let params = [
    sqlight.text(a.id),
    sqlight.text(a.slug),
    sqlight.int(a.revision),
    sqlight.text(a.author),
    sqlight.text(tags_json),
    published,
    sqlight.text(a.title),
    sqlight.text(a.subtitle),
    sqlight.text(a.leading),
    sqlight.text(a.content),
  ]

  case sqlight.query(sql, conn, params, decode.dynamic) {
    Ok(_) -> Ok(a)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn delete_article(conn: Connection, id: String) -> Result(Nil, DbError) {
  let sql = "DELETE FROM articles WHERE id = ?"
  case sqlight.query(sql, conn, [sqlight.text(id)], decode.dynamic) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

fn article_decoder() -> Decoder(Article) {
  use id <- decode.field(0, decode.string)
  use slug <- decode.field(1, decode.string)
  use rev <- decode.field(2, decode.int)
  use author <- decode.field(3, decode.string)
  use tags_str <- decode.field(4, decode.string)
  use pub_ms <- decode.field(5, decode.optional(decode.int))
  use title <- decode.field(6, decode.string)
  use sub <- decode.field(7, decode.string)
  use lead <- decode.field(8, decode.string)
  use content <- decode.field(9, decode.string)
  let tags = parse_json_string_list(tags_str)
  decode.success(Article(
    id,
    slug,
    rev,
    author,
    tags,
    pub_ms,
    title,
    sub,
    lead,
    content,
  ))
}

fn parse_json_string_list(s: String) -> List(String) {
  case json.parse(s, using: decode.list(decode.string)) {
    Ok(lst) -> lst
    Error(_) -> []
  }
}

// ----------------------------------------------------------------------------
// Short URLs
// ----------------------------------------------------------------------------

pub fn list_short_urls(conn: Connection) -> Result(List(ShortUrl), DbError) {
  let sql =
    "SELECT id, short_code, target_url, created_by, created_at, updated_at, access_count, is_active FROM short_urls"

  case sqlight.query(sql, conn, [], short_url_decoder()) {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn get_short_url(
  conn: Connection,
  id: String,
) -> Result(Option(ShortUrl), DbError) {
  let sql =
    "SELECT id, short_code, target_url, created_by, created_at, updated_at, access_count, is_active FROM short_urls WHERE id = ?"

  case sqlight.query(sql, conn, [sqlight.text(id)], short_url_decoder()) {
    Ok([url]) -> Ok(Some(url))
    Ok([]) -> Ok(None)
    Ok(_) -> Error(DbError("multiple short_urls with same id"))
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn get_short_url_by_code(
  conn: Connection,
  code: String,
) -> Result(Option(ShortUrl), DbError) {
  let sql =
    "SELECT id, short_code, target_url, created_by, created_at, updated_at, access_count, is_active FROM short_urls WHERE short_code = ? AND is_active = 1"

  case sqlight.query(sql, conn, [sqlight.text(code)], short_url_decoder()) {
    Ok([url]) -> Ok(Some(url))
    Ok([]) -> Ok(None)
    Ok(_) -> Error(DbError("multiple short_urls with same code"))
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn upsert_short_url(
  conn: Connection,
  url: ShortUrl,
) -> Result(ShortUrl, DbError) {
  let is_active_int = case url.is_active {
    True -> 1
    False -> 0
  }

  let sql =
    "INSERT INTO short_urls (id, short_code, target_url, created_by, created_at, updated_at, access_count, is_active)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       short_code = excluded.short_code,
       target_url = excluded.target_url,
       created_by = excluded.created_by,
       updated_at = excluded.updated_at,
       access_count = excluded.access_count,
       is_active = excluded.is_active"

  let params = [
    sqlight.text(url.id),
    sqlight.text(url.short_code),
    sqlight.text(url.target_url),
    sqlight.text(url.created_by),
    sqlight.int(url.created_at),
    sqlight.int(url.updated_at),
    sqlight.int(url.access_count),
    sqlight.int(is_active_int),
  ]

  case sqlight.query(sql, conn, params, decode.dynamic) {
    Ok(_) -> Ok(url)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn increment_short_url_access(
  conn: Connection,
  id: String,
  now: Int,
) -> Result(Nil, DbError) {
  let sql =
    "UPDATE short_urls SET access_count = access_count + 1, updated_at = ? WHERE id = ?"
  case
    sqlight.query(
      sql,
      conn,
      [sqlight.int(now), sqlight.text(id)],
      decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn delete_short_url(conn: Connection, id: String) -> Result(Nil, DbError) {
  let sql = "DELETE FROM short_urls WHERE id = ?"
  case sqlight.query(sql, conn, [sqlight.text(id)], decode.dynamic) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

fn short_url_decoder() -> Decoder(ShortUrl) {
  use id <- decode.field(0, decode.string)
  use code <- decode.field(1, decode.string)
  use target <- decode.field(2, decode.string)
  use created_by <- decode.field(3, decode.string)
  use created_at <- decode.field(4, decode.int)
  use updated_at <- decode.field(5, decode.int)
  use count <- decode.field(6, decode.int)
  use active <- decode.field(7, decode.int)
  decode.success(ShortUrl(
    id,
    code,
    target,
    created_by,
    created_at,
    updated_at,
    count,
    active == 1,
  ))
}

// ----------------------------------------------------------------------------
// Users
// ----------------------------------------------------------------------------

pub type User {
  User(
    id: String,
    username: String,
    password_hash: String,
    email: String,
    permissions: List(String),
  )
}

pub fn get_user_by_username(
  conn: Connection,
  username: String,
) -> Result(Option(User), DbError) {
  let sql =
    "SELECT id, username, password_hash, email, permissions FROM users WHERE username = ?"

  case sqlight.query(sql, conn, [sqlight.text(username)], user_decoder()) {
    Ok([user]) -> Ok(Some(user))
    Ok([]) -> Ok(None)
    Ok(_) -> Error(DbError("multiple users with same username"))
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

pub fn create_user(conn: Connection, user: User) -> Result(User, DbError) {
  let perms_json = json.array(user.permissions, json.string) |> json.to_string

  let sql =
    "INSERT INTO users (id, username, password_hash, email, permissions) VALUES (?, ?, ?, ?, ?)"

  let params = [
    sqlight.text(user.id),
    sqlight.text(user.username),
    sqlight.text(user.password_hash),
    sqlight.text(user.email),
    sqlight.text(perms_json),
  ]

  case sqlight.query(sql, conn, params, decode.dynamic) {
    Ok(_) -> Ok(user)
    Error(e) -> Error(DbError(sql_error_msg(e)))
  }
}

fn user_decoder() -> Decoder(User) {
  use id <- decode.field(0, decode.string)
  use username <- decode.field(1, decode.string)
  use hash <- decode.field(2, decode.string)
  use email <- decode.field(3, decode.string)
  use perms_str <- decode.field(4, decode.string)
  let perms = parse_json_string_list(perms_str)
  decode.success(User(id, username, hash, email, perms))
}
