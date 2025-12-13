import gleam/erlang/atom
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{None}

import jst_server/config.{type Config}
import jst_server/db
import jst_server/id
import jst_server/pubsub.{type PubSub}
import shared/article
import shared/omni as shared_omni
import shared/short_url

import mist
import sqlight.{type Connection}

pub type State {
  State(db: Connection, pubsub: PubSub, conf: Config)
}

pub fn websocket(
  db_conn: Connection,
  pubsub: PubSub,
  req: Request(mist.Connection),
  conf: Config,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      #(State(db: db_conn, pubsub: pubsub, conf: conf), None)
    },
    on_close: fn(_state) { Nil },
    handler: handle_ws_message,
  )
}

fn handle_ws_message(state: State, message, conn) {
  case message {
    mist.Text(text) -> {
      case shared_omni.decode_client_message(text) {
        Ok(client_msg) -> handle_client_message(state, conn, client_msg)
        Error(shared_omni.DecodeError(err)) -> {
          let _ = send(conn, shared_omni.ServerError("decode error: " <> err))
          mist.continue(state)
        }
      }
    }

    mist.Binary(_bin) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(_custom) -> mist.continue(state)
  }
}

fn handle_client_message(state: State, conn, msg: shared_omni.ClientMessage) {
  case msg {
    shared_omni.SubscribeShortUrls -> {
      let _ = case db.list_short_urls(state.db) {
        Ok(urls) -> send(conn, shared_omni.ShortUrlsSnapshot(urls))
        Error(db.DbError(e)) ->
          send(conn, shared_omni.ServerError("db error: " <> e))
      }
      mist.continue(state)
    }

    shared_omni.SubscribeArticles -> {
      let _ = case db.list_articles(state.db) {
        Ok(articles) -> send(conn, shared_omni.ArticlesSnapshot(articles))
        Error(db.DbError(e)) ->
          send(conn, shared_omni.ServerError("db error: " <> e))
      }
      mist.continue(state)
    }

    shared_omni.ShortUrlUpsert(url) -> {
      case upsert_short_url(state.db, url) {
        Ok(saved) -> {
          let _ = send(conn, shared_omni.ShortUrlUpserted(saved))
          pubsub.broadcast(
            state.pubsub,
            pubsub.ShortUrls,
            shared_omni.ShortUrlUpserted(saved),
          )
        }
        Error(e) -> {
          let _ = send(conn, shared_omni.ServerError(e))
          Nil
        }
      }
      mist.continue(state)
    }

    shared_omni.ArticleUpsert(a) -> {
      case upsert_article(state.db, a) {
        Ok(saved) -> {
          let _ = send(conn, shared_omni.ArticleUpserted(saved))
          pubsub.broadcast(
            state.pubsub,
            pubsub.Articles,
            shared_omni.ArticleUpserted(saved),
          )
        }
        Error(e) -> {
          let _ = send(conn, shared_omni.ServerError(e))
          Nil
        }
      }
      mist.continue(state)
    }

    shared_omni.ShortUrlDelete(url_id) -> {
      let _ = db.delete_short_url(state.db, url_id)
      let _ = send(conn, shared_omni.ShortUrlDeleted(url_id))
      pubsub.broadcast(
        state.pubsub,
        pubsub.ShortUrls,
        shared_omni.ShortUrlDeleted(url_id),
      )
      mist.continue(state)
    }

    shared_omni.ArticleDelete(article_id) -> {
      let _ = db.delete_article(state.db, article_id)
      let _ = send(conn, shared_omni.ArticleDeleted(article_id))
      pubsub.broadcast(
        state.pubsub,
        pubsub.Articles,
        shared_omni.ArticleDeleted(article_id),
      )
      mist.continue(state)
    }

    _other -> {
      let _ = send(conn, shared_omni.ServerError("not implemented"))
      mist.continue(state)
    }
  }
}

fn upsert_short_url(
  conn: Connection,
  url: short_url.ShortUrl,
) -> Result(short_url.ShortUrl, String) {
  let now = now_unix_seconds()

  let url = case url.id {
    "" -> {
      let new_id = id.random_hex(16)
      let short_code = case url.short_code {
        "" -> id.random_short_code(4)
        other -> other
      }

      short_url.ShortUrl(
        id: new_id,
        short_code: short_code,
        target_url: url.target_url,
        created_by: url.created_by,
        created_at: now,
        updated_at: now,
        access_count: 0,
        is_active: True,
      )
    }

    _ -> short_url.ShortUrl(..url, updated_at: now)
  }

  case url.target_url == "" {
    True -> Error("target_url is required")
    False -> {
      case db.upsert_short_url(conn, url) {
        Ok(saved) -> Ok(saved)
        Error(db.DbError(e)) -> Error("db error: " <> e)
      }
    }
  }
}

fn upsert_article(
  conn: Connection,
  a: article.Article,
) -> Result(article.Article, String) {
  let a = case a.id {
    "" -> {
      article.Article(
        id: id.random_hex(16),
        slug: a.slug,
        revision: 1,
        author: a.author,
        tags: a.tags,
        published_at_ms: a.published_at_ms,
        title: a.title,
        subtitle: a.subtitle,
        leading: a.leading,
        content: a.content,
      )
    }
    _ -> article.Article(..a, revision: a.revision + 1)
  }

  // If no slug provided, make one from id.
  let a = case a.slug {
    "" -> article.Article(..a, slug: "post-" <> a.id)
    _ -> a
  }

  case db.upsert_article(conn, a) {
    Ok(saved) -> Ok(saved)
    Error(db.DbError(e)) -> Error("db error: " <> e)
  }
}

fn send(conn, msg: shared_omni.ServerMessage) {
  let payload = shared_omni.encode_server_message(msg)
  mist.send_text_frame(conn, payload)
}

fn now_unix_seconds() -> Int {
  system_time(atom.create("second"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int
