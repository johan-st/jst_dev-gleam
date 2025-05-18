// IMPORTS ---------------------------------------------------------------------

import article/article.{
  type Article, type Content, ArticleFull, ArticleSummary, ArticleWithError,
}
import chat/chat
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{type Attribute}
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import utils/error_string
import utils/http.{type HttpError}
import utils/persist.{type PersistentModel, PersistentModelV0, PersistentModelV1}

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  // let app = lustre.application(init, update_with_localstorage, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    route: Route,
    articles: RemoteData(Dict(String, Article), HttpError),
    articles_drafts: Dict(String, Article),
    // user_messages: List(UserMessage),
    chat: chat.Model,
  )
}

type RemoteData(a, err) {
  NotInitialized
  Pending
  Loaded(a)
  Errored(err)
}

// type UserMessage {
//   UserError(id: Int, text: String)
//   UserWarning(id: Int, text: String)
//   UserInfo(id: Int, text: String)
// }

type Route {
  Index
  Articles
  ArticleBySlug(slug: String)
  ArticleBySlugEdit(slug: String)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

fn parse_route(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index
    ["articles"] -> Articles
    ["article", slug] -> ArticleBySlug(slug)
    ["article", slug, "edit"] -> ArticleBySlugEdit(slug)
    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

fn route_url(route: Route) -> String {
  case route {
    Index -> "/"
    About -> "/about"
    Articles -> "/articles"
    ArticleBySlug(slug) -> "/article/" <> slug
    ArticleBySlugEdit(slug) -> "/article/" <> slug <> "/edit"
    NotFound(_) -> "/404"
  }
}

fn href(route: Route) -> Attribute(msg) {
  attr.href(route_url(route))
}

fn init(_) -> #(Model, Effect(Msg)) {
  // The server for a typical SPA will often serve the application to *any*
  // HTTP request, and let the app itself determine what to show. Modem stores
  // the first URL so we can parse it for the app's initial route.
  let route = case modem.initial_uri() {
    Ok(uri) -> parse_route(uri)
    Error(_) -> Index
  }
  let #(chat_model, chat_effect) = chat.init()
  let model =
    Model(
      route:,
      articles: Pending,
      articles_drafts: dict.new(),
      // user_messages: [],
      chat: chat_model,
    )
  let effect_modem =
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })
  #(
    model,
    effect.batch([
      effect_modem,
      effect_navigation(model, route),
      effect.map(chat_effect, ChatMsg),
      article.get_metadata_all(ArticleMetaGot),
      persist.localstorage_get(
        persist.model_localstorage_key,
        persist.decoder(),
        PersistGotModel,
      ),
      // flags_get(GotFlags),
    ]),
  )
}

// pub fn flags_get(msg) -> Effect(Msg) {
//   let url = "http://127.0.0.1:1234/priv/static/flags.json"
//   http.get(url, http.expect_json(article_decoder(), msg))
// }

// UPDATE ----------------------------------------------------------------------

type Msg {
  // NAVIGATION
  UserNavigatedTo(route: Route)
  // MESSAGES
  // UserMessageDismissed(msg: UserMessage)
  // LOCALSTORAGE
  PersistGotModel(opt: Option(PersistentModel))
  // ARTICLES
  ArticleHovered(article: Article)
  ArticleGot(slug: String, result: Result(Article, HttpError))
  ArticleMetaGot(result: Result(List(Article), HttpError))
  // ARTICLE EDIT
  ArticleEditCancelled(article: Article)
  ArticleEditSaved(article: Article)
  ArticleEditUpdated(article: Article)
  // ARTICLE CONTENT EDIT
  ArticleEditContentUpdate(index: Int, content: Content)
  ArticleEditContentRemove(index: Int)
  ArticleEditContentMoveUp(index: Int)
  ArticleEditContentMoveDown(index: Int)
  ArticleEditContentListItemAdd(index: Int)
  ArticleEditContentListItemRemove(content_index: Int, item_index: Int)
  // CHAT
  ChatMsg(msg: chat.Msg)
}

// fn update_with_localstorage(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
//   let #(new_model, effect) = update(model, msg)
//   let persistent_model = fn(model: Model) -> PersistentModel {
//     PersistentModelV1(
//       version: 1,
//       articles: case model.articles {
//         NotInitialized -> []
//         Pending -> []
//         Loaded(articles) -> articles |> dict.to_list
//         Errored(_) -> []
//       }
//         |> list.map(fn(tuple) {
//           let #(_id, article) = tuple
//           article
//         }),
//     )
//   }
//   case msg {
//     ArticleMetaGot(_) -> {
//       persist.localstorage_set(
//         persist.model_localstorage_key,
//         persist.encode(persistent_model(new_model)),
//       )
//     }
//     ArticleGot(_, _) -> {
//       persist.localstorage_set(
//         persist.model_localstorage_key,
//         persist.encode(persistent_model(new_model)),
//       )
//     }
//     _ -> Nil
//   }
//   #(new_model, effect)
// }

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // NAVIGATION
    UserNavigatedTo(route:) -> {
      case route {
        ArticleBySlugEdit(slug) -> {
          let article = dict.get(model.articles_drafts, slug)
          case article {
            Ok(_) -> {
              #(Model(..model, route:), effect_navigation(model, route))
            }
            Error(_) -> {
              // Check if we have a full article in the loaded articles
              let maybe_full_article = case model.articles {
                Loaded(articles) -> dict.get(articles, slug)
                _ -> Error(Nil)
              }

              let articles_drafts = case maybe_full_article {
                // If we have a full article, use it as the draft
                Ok(full_article) ->
                  dict.insert(model.articles_drafts, slug, full_article)
                // Otherwise create a summary as before
                Error(_) ->
                  dict.insert(
                    model.articles_drafts,
                    slug,
                    ArticleSummary(slug, 0, "", "", ""),
                  )
              }

              // If we only have a summary, fetch the full article
              let effect = case maybe_full_article {
                Ok(ArticleSummary(_, _, _, _, _)) | Error(_) ->
                  article.get_article(
                    fn(result) { ArticleGot(slug, result) },
                    slug,
                  )
                _ -> effect.none()
              }

              #(Model(..model, route:, articles_drafts:), effect)
            }
          }
        }
        _ -> {
          #(Model(..model, route:), effect_navigation(model, route))
        }
      }
    }
    // Browser Persistance
    PersistGotModel(opt:) -> {
      case opt {
        Some(PersistentModelV1(_, articles)) -> {
          #(
            Model(..model, articles: articles |> article.list_to_dict |> Loaded),
            effect.none(),
          )
        }
        Some(PersistentModelV0(_)) -> {
          #(model, effect.none())
        }
        None -> {
          #(model, effect.none())
        }
      }
    }
    ArticleMetaGot(result:) -> {
      update_got_articles_metadata(model, result)
    }
    ArticleGot(slug, result) -> {
      case result {
        Ok(article) -> {
          case model.articles {
            Loaded(articles) -> {
              #(
                Model(
                  ..model,
                  articles: Loaded(dict.insert(articles, article.slug, article)),
                ),
                effect.none(),
              )
            }
            _ -> {
              #(
                Model(
                  ..model,
                  articles: Loaded(dict.insert(
                    dict.new(),
                    article.slug,
                    article,
                  )),
                ),
                effect.none(),
              )
            }
          }
        }
        Error(err) -> update_got_article_error(model, err, slug)
      }
    }
    ArticleHovered(article:) -> {
      case article {
        ArticleSummary(slug, _, _, _, _) -> {
          #(
            model,
            article.get_article(fn(result) { ArticleGot(slug, result) }, slug),
          )
        }
        ArticleFull(_, _, _, _, _, _) -> {
          #(model, effect.none())
        }
        ArticleWithError(_, _, _, _, _, _) -> {
          #(model, effect.none())
        }
      }
    }
    // ARTICLE EDIT
    ArticleEditCancelled(article:) -> {
      echo "article edit cancelled"
      #(
        Model(
          ..model,
          articles_drafts: dict.delete(model.articles_drafts, article.slug),
        ),
        effect.none(),
      )
    }
    ArticleEditSaved(article:) -> {
      echo "article edit saved"
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      #(
        Model(
          ..model,
          articles_drafts: dict.delete(model.articles_drafts, article.slug),
          articles: Loaded(dict.insert(articles, article.slug, article)),
          route: ArticleBySlug(article.slug),
        ),
        modem.push(route_url(ArticleBySlug(article.slug)), None, None),
      )
    }
    ArticleEditUpdated(article:) -> {
      #(
        Model(
          ..model,
          articles_drafts: dict.insert(
            model.articles_drafts,
            article.slug,
            article,
          ),
        ),
        effect.none(),
      )
    }
    // ARTICLE CONTENT EDIT
    ArticleEditContentUpdate(index, content) -> {
      case model.route {
        ArticleBySlugEdit(slug) -> {
          let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
          let assert ArticleFull(_, _, _, _, _, content_list) = draft
          let updated_content = list_set(content_list, index, content)
          let updated_article =
            update_article_content_blocks(draft, updated_content)
          #(
            Model(
              ..model,
              articles_drafts: dict.insert(
                model.articles_drafts,
                slug,
                updated_article,
              ),
            ),
            effect.none(),
          )
        }
        _ -> #(model, effect.none())
      }
    }

    ArticleEditContentRemove(index) -> {
      case model.route {
        ArticleBySlugEdit(slug) -> {
          let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
          let assert ArticleFull(_, _, _, _, _, content_list) = draft
          let before = list.take(content_list, index)
          let after = list.drop(content_list, index + 1)
          let updated_content = list.append(before, after)
          let updated_article =
            update_article_content_blocks(draft, updated_content)
          #(
            Model(
              ..model,
              articles_drafts: dict.insert(
                model.articles_drafts,
                slug,
                updated_article,
              ),
            ),
            effect.none(),
          )
        }
        _ -> #(model, effect.none())
      }
    }

    ArticleEditContentMoveUp(index) -> {
      case index {
        0 -> #(model, effect.none())
        _ -> {
          case model.route {
            ArticleBySlugEdit(slug) -> {
              let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
              let assert ArticleFull(_, _, _, _, _, content_list) = draft
              let item = list_at(content_list, index)
              let prev_item = list_at(content_list, index - 1)

              case item, prev_item {
                Ok(current), Ok(previous) -> {
                  let updated_content =
                    content_list
                    |> list_set(index, previous)
                    |> list_set(index - 1, current)

                  let updated_article =
                    update_article_content_blocks(draft, updated_content)

                  #(
                    Model(
                      ..model,
                      articles_drafts: dict.insert(
                        model.articles_drafts,
                        slug,
                        updated_article,
                      ),
                    ),
                    effect.none(),
                  )
                }
                _, _ -> #(model, effect.none())
              }
            }
            _ -> #(model, effect.none())
          }
        }
      }
    }

    ArticleEditContentMoveDown(index) -> {
      case model.route {
        ArticleBySlugEdit(slug) -> {
          let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
          let assert ArticleFull(_, _, _, _, _, content_list) = draft
          case index >= list.length(content_list) - 1 {
            True -> #(model, effect.none())
            False -> {
              let item = list_at(content_list, index)
              let next_item = list_at(content_list, index + 1)

              case item, next_item {
                Ok(current), Ok(next) -> {
                  let updated_content =
                    content_list
                    |> list_set(index, next)
                    |> list_set(index + 1, current)

                  let updated_article =
                    update_article_content_blocks(draft, updated_content)

                  #(
                    Model(
                      ..model,
                      articles_drafts: dict.insert(
                        model.articles_drafts,
                        slug,
                        updated_article,
                      ),
                    ),
                    effect.none(),
                  )
                }
                _, _ -> #(model, effect.none())
              }
            }
          }
        }
        _ -> #(model, effect.none())
      }
    }

    ArticleEditContentListItemAdd(index) -> {
      case model.route {
        ArticleBySlugEdit(slug) -> {
          let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
          let assert ArticleFull(_, _, _, _, _, content_list) = draft
          let content_item = list_at(content_list, index)

          case content_item {
            Ok(article.List(items)) -> {
              let updated_items = list.append(items, [article.Text("")])
              let updated_content =
                list_set(content_list, index, article.List(updated_items))
              let updated_article =
                update_article_content_blocks(draft, updated_content)

              #(
                Model(
                  ..model,
                  articles_drafts: dict.insert(
                    model.articles_drafts,
                    slug,
                    updated_article,
                  ),
                ),
                effect.none(),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        _ -> #(model, effect.none())
      }
    }

    ArticleEditContentListItemRemove(content_index, item_index) -> {
      case model.route {
        ArticleBySlugEdit(slug) -> {
          let assert Ok(draft) = model.articles_drafts |> dict.get(slug)
          let assert ArticleFull(_, _, _, _, _, content_list) = draft

          let content_item = list_at(content_list, content_index)

          case content_item {
            Ok(article.List(items)) -> {
              let before = list.take(items, item_index)
              let after = list.drop(items, item_index + 1)
              let updated_items = list.append(before, after)
              let updated_content =
                list_set(
                  content_list,
                  content_index,
                  article.List(updated_items),
                )
              let updated_article =
                update_article_content_blocks(draft, updated_content)

              #(
                Model(
                  ..model,
                  articles_drafts: dict.insert(
                    model.articles_drafts,
                    slug,
                    updated_article,
                  ),
                ),
                effect.none(),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        _ -> #(model, effect.none())
      }
    }

    ChatMsg(msg) -> {
      let #(chat_model, chat_effect) = chat.update(msg, model.chat)
      #(Model(..model, chat: chat_model), effect.map(chat_effect, ChatMsg))
    }
  }
}

fn effect_navigation(model: Model, route: Route) -> Effect(Msg) {
  case route {
    ArticleBySlug(slug) -> {
      let articles = case model.articles {
        Loaded(articles) -> articles
        _ -> dict.new()
      }
      let article = dict.get(articles, slug)
      case article {
        Ok(article) -> {
          case article {
            ArticleSummary(slug, _, _, _, _) -> {
              article.get_article(fn(result) { ArticleGot(slug, result) }, slug)
            }
            ArticleFull(_, _, _, _, _, _) -> {
              effect.none()
            }
            ArticleWithError(_, _, _, _, _, _) -> {
              article.get_article(fn(result) { ArticleGot(slug, result) }, slug)
            }
          }
        }
        Error(Nil) -> {
          echo "no article found for slug: " <> slug
          effect.none()
        }
      }
    }
    _ -> {
      effect.none()
    }
  }
}

// fn update_websocket_on_message(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "message: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_close(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "close: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_error(
//   model: Model,
//   data: String,
// ) -> #(Model, Effect(Msg)) {
//   echo "error: " <> data
//   #(model, effect.none())
// }

// fn update_websocket_on_open(model: Model, data: String) -> #(Model, Effect(Msg)) {
//   echo "open: " <> data
//   #(model, effect.none())
// }

fn update_got_articles_metadata(
  model: Model,
  result: Result(List(Article), HttpError),
) {
  case echo result {
    Ok(articles) -> {
      let articles = article.list_to_dict(articles)
      let effect = case model.route {
        ArticleBySlug(_) -> {
          echo "loading article content"
          effect_navigation(
            Model(..model, articles: Loaded(articles)),
            model.route,
          )
        }
        ArticleBySlugEdit(_) -> {
          echo "loading article content"
          effect_navigation(
            Model(..model, articles: Loaded(articles)),
            model.route,
          )
        }
        _ -> {
          echo "no effect for route: " <> route_url(model.route)
          effect.none()
        }
      }
      #(Model(..model, articles: Loaded(articles)), effect)
    }
    Error(err) -> {
      // let error_string = error_string.http_error(err)
      // let user_messages =
      //   list.append(model.user_messages, [
      //     UserError(user_message_id_next(model.user_messages), error_string),
      //   ])
      // #(Model(..model, user_messages:, articles: Errored(err)), effect.none())
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

fn update_got_article_error(
  model: Model,
  err: HttpError,
  slug: String,
) -> #(Model, Effect(Msg)) {
  let error_string =
    "failed to load article (slug: "
    <> slug
    <> "): "
    <> error_string.http_error(err)
  let articles = case model.articles {
    Loaded(articles) -> articles
    _ -> dict.new()
  }
  case err {
    http.JsonError(json.UnexpectedByte(_)) -> {
      case dict.get(articles, slug) {
        Ok(article) -> {
          let art =
            articles_update(
              [
                ArticleWithError(
                  slug,
                  article.revision,
                  article.title,
                  article.leading,
                  article.subtitle,
                  error_string,
                ),
              ],
              articles,
            )
          #(Model(..model, articles: Loaded(art)), effect.none())
        }
        Error(_) -> {
          echo error_string.http_error(err)
          #(model, effect.none())
        }
      }
    }

    http.NotFound -> {
      case dict.get(articles, slug) {
        Ok(article) -> {
          let article =
            ArticleWithError(
              slug,
              article.revision,
              article.title,
              article.leading,
              article.subtitle,
              error_string,
            )
          #(
            Model(
              ..model,
              articles: Loaded(dict.insert(articles, slug, article)),
            ),
            effect.none(),
          )
        }
        Error(_) -> {
          echo "not found: " <> error_string.http_error(err)
          #(model, effect.none())
        }
      }
    }
    _ -> {
      echo err
      // let user_messages =
      //   list.append(model.user_messages, [
      //     UserError(
      //       user_message_id_next(model.user_messages),
      //       "UNHANDLED ERROR while loading article (slug:"
      //         <> slug
      //         <> "): "
      //         <> error_string,
      //     ),
      //   ])
      // #(Model(..model, user_messages:), effect.none())
      #(Model(..model, articles: Errored(err)), effect.none())
    }
  }
}

fn articles_update(
  new_articles: List(Article),
  old_articles: Dict(String, Article),
) -> Dict(String, Article) {
  new_articles
  |> list.map(fn(article) { #(article.slug, article) })
  |> dict.from_list
  |> dict.merge(old_articles, _)
}

// fn user_message_id_next(user_messages: List(UserMessage)) -> Int {
//   case list.last(user_messages) {
//     Ok(msg) -> msg.id + 1
//     Error(_) -> 0
//   }
// }

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attr.class("text-zinc-400 h-full w-full text-lg font-thin mx-auto "),
      attr.class(
        "focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
      ),
    ],
    [
      view_header(model),
      // html.div(
      //   [attr.class("fixed top-18 left-0 right-0")],
      //   view_user_messages(model.user_messages),
      // ),
      html.main([attr.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          Index -> view_index()
          Articles -> {
            case model.articles {
              Loaded(articles) -> {
                case dict.is_empty(articles) {
                  True -> [view_error("got no articles from server")]
                  False -> view_article_listing(articles)
                }
              }
              Errored(err) -> [
                view_h2(error_string.http_error(err)),
                view_paragraph([
                  article.Text(
                    "We encountered an error while loading the articles. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  article.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  article.Text("no atempt to load articles made. This is a bug"),
                ]),
              ]
            }
          }
          ArticleBySlug(slug) -> {
            case model.articles {
              Loaded(articles) -> {
                let article = dict.get(articles, slug)
                case article {
                  Ok(article) -> view_article(article)
                  Error(_) -> view_not_found()
                }
              }
              Errored(err) -> [
                view_h2(error_string.http_error(err)),
                view_paragraph([
                  article.Text(
                    "We encountered an error while loading the articles and that includes this one. Try reloading the page..",
                  ),
                ]),
              ]
              Pending -> [
                view_h2("loading..."),
                view_paragraph([
                  article.Text(
                    "We are loading the articles.. Give us a moment.",
                  ),
                ]),
              ]
              NotInitialized -> [
                view_h2("A bug.."),
                view_paragraph([
                  article.Text("no atempt to load articles made. This is a bug"),
                ]),
              ]
            }
          }
          ArticleBySlugEdit(slug) -> {
            case model.articles {
              Loaded(articles) -> {
                case dict.is_empty(articles) {
                  True -> {
                    echo "article by slug: no articles loaded"
                    view_article(article.loading_article())
                  }
                  False -> {
                    let article = dict.get(articles, slug)
                    case article {
                      Ok(article) -> view_article_edit(model, article)
                      Error(_) -> view_not_found()
                    }
                  }
                }
              }
              Errored(err) -> [view_error(error_string.http_error(err))]
              Pending -> [view_error("loading...")]
              NotInitialized -> [view_error("no atempt to load articles made")]
            }
          }
          About -> view_about()
          NotFound(_) -> view_not_found()
        }
      }),
      // ..chat.view(ChatMsg, model.chat)
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------påökjölmnnm,öoigbo9ybnpuhbp.,kb iuu
fn view_header(model: Model) -> Element(Msg) {
  html.nav(
    [attr.class("py-2 border-b bg-zinc-800 border-pink-700 font-mono ")],
    [
      html.div(
        [
          attr.class(
            "flex justify-between px-10 items-center max-w-screen-md mx-auto",
          ),
        ],
        [
          html.div([], [
            html.a([attr.class("font-light"), href(Index)], [
              html.text("jst.dev"),
            ]),
          ]),
          // html.div([], [
          //   html.text(case model.user_messages {
          //     [] -> ""
          //     _ -> {
          //       let num = list.length(model.user_messages)
          //       "got " <> int.to_string(num) <> " messages"
          //     }
          //   }),
          // ]),
          html.ul([attr.class("flex space-x-8 pr-2")], [
            view_header_link(
              current: model.route,
              to: Articles,
              label: "Articles",
            ),
            view_header_link(current: model.route, to: About, label: "About"),
          ]),
        ],
      ),
    ],
  )
}

fn view_header_link(
  to target: Route,
  current current: Route,
  label text: String,
) -> Element(msg) {
  let is_active = case current, target {
    ArticleBySlug(_), Articles -> True
    _, _ -> current == target
  }

  html.li(
    [
      attr.classes([
        #("border-transparent border-b-2 hover:border-pink-700", True),
        #("text-pink-700", is_active),
      ]),
    ],
    [html.a([href(target)], [html.text(text)])],
  )
}

// VIEW MESSAGES ---------------------------------------------------------------

// fn view_user_messages(msgs) {
//   case msgs {
//     [] -> []
//     [msg, ..msgs] -> [view_user_message(msg), ..view_user_messages(msgs)]
//   }
// }

// fn view_user_message(msg: UserMessage) -> Element(Msg) {
//   case msg {
//     UserError(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("rounded-md bg-red-50 p-4 absolute top-0 left-0 right-0"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("ERROR")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("text-sm font-medium text-red-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100 focus:outline-none focus:ring-2 focus:ring-red-600 focus:ring-offset-2 focus:ring-offset-orange-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }

//     UserWarning(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("rounded-md bg-green-50 p-4 relative top-0 left-0 right-0"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("WARNING")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("text-sm font-medium text-green-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-green-50 p-1.5 text-green-500 hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-600 focus:ring-offset-2 focus:ring-offset-green-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }

//     UserInfo(id, msg_text) -> {
//       html.div(
//         [
//           attr.class("border-l-4 border-yellow-400 bg-yellow-50 p-4"),
//           attr.id("user-message-" <> int.to_string(id)),
//         ],
//         [
//           html.div([attr.class("flex")], [
//             html.div([attr.class("shrink-0")], [html.text("INFO")]),
//             html.div([attr.class("ml-3")], [
//               html.p([attr.class("font-medium text-yellow-800")], [
//                 html.text(msg_text),
//               ]),
//             ]),
//             html.div([attr.class("ml-auto pl-3")], [
//               html.div([attr.class("-mx-1.5 -my-1.5")], [
//                 html.button(
//                   [
//                     attr.class(
//                       "inline-flex rounded-md bg-yellow-50 p-1.5 text-yellow-500 hover:bg-yellow-100 focus:outline-none focus:ring-2 focus:ring-yellow-600 focus:ring-offset-2 focus:ring-offset-yellow-50",
//                     ),
//                     event.on_click(UserMessageDismissed(msg)),
//                   ],
//                   [html.text("Dismiss")],
//                 ),
//               ]),
//             ]),
//           ]),
//         ],
//       )
//     }
//   }
// }

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  [
    view_title("Welcome to jst.dev!", "welcome"),
    view_subtitle(
      "...or, A lession on overengineering for fun and.. 
      well just for fun.",
      "welcome",
    ),
    view_leading(
      "This site and it's underlying IT-infrastructure is the primary 
      place for me to experiment with technologies and topologies. I 
      also share some of my thoughts and learnings here.",
      "welcome",
    ),
    html.p([attr.class("mt-14")], [
      html.text(
        "This site and it's underlying IT-infrastructure is the primary 
        place for me to experiment with technologies and topologies. I 
        also share some of my thoughts and learnings here. Feel free to 
        check out my overview, ",
      ),
      view_link(
        ArticleBySlug("nats-all-the-way-down"),
        "NATS all the way down ->",
      ),
    ]),
    view_paragraph([
      article.Text(
        "It to is a work in progress and I mostly keep it here for my own reference.",
      ),
    ]),
    view_paragraph([
      article.Text(
        "I'm also a software developer and a writer. I'm also a father and a 
        husband. I'm also a software developer and a writer. I'm also a father 
        and a husband. I'm also a software developer and a writer. I'm also a 
        father and a husband. I'm also a software developer and a writer.",
      ),
    ]),
  ]
}

fn view_article_listing(articles: Dict(String, Article)) -> List(Element(Msg)) {
  let articles =
    articles
    |> dict.values
    |> list.sort(fn(a, b) { string.compare(a.slug, b.slug) })
    |> list.index_map(fn(article, _index) {
      case article {
        ArticleFull(slug, _, title, leading, subtitle, _)
        | ArticleSummary(slug, _, title, leading, subtitle) -> {
          html.article([attr.class("mt-14 hover:bg-blur-sm")], [
            html.a(
              [
                attr.class(
                  "group block  border-l border-zinc-700  pl-4  hover:border-pink-700 transition-colors duration-25",
                ),
                href(ArticleBySlug(slug)),
                event.on_mouse_enter(ArticleHovered(article)),
              ],
              [
                html.div([attr.class("flex justify-between gap-4")], [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl text-pink-700 font-light"),
                    ],
                    [html.text(title)],
                  ),
                  view_edit_link(article),
                ]),
                view_subtitle(subtitle, slug),
                view_paragraph([article.Text(leading)]),
              ],
            ),
          ])
        }
        ArticleWithError(slug, _revision, title, _leading, _subtitle, error) -> {
          html.article(
            [attr.class("mt-14 group group-hover"), attr.class("animate-break")],
            [
              html.a(
                [
                  href(ArticleBySlug(slug)),
                  attr.class(
                    "group block  border-l border-zinc-700 pl-4 hover:border-zinc-500 transition-colors duration-25",
                  ),
                ],
                [
                  html.h3(
                    [
                      attr.id("article-title-" <> slug),
                      attr.class("article-title"),
                      attr.class("text-xl font-light w-max-content"),
                      attr.class("animate-break--mirror hover:animate-break"),
                    ],
                    [html.text(title)],
                  ),
                  view_subtitle(error, slug),
                  view_error(
                    "there was an error loading this article. Click to try again.",
                  ),
                ],
              ),
            ],
          )
        }
      }
    })

  [view_title("Articles", "articles"), ..articles]
}

fn view_article_edit(model: Model, article: Article) -> List(Element(Msg)) {
  let draft_article = case model.articles_drafts |> dict.get(article.slug) {
    Ok(draft) -> draft
    Error(_) -> article
  }

  // Ensure we're working with an ArticleFull that has content blocks
  let draft_article = case draft_article {
    ArticleSummary(slug, revision, title, leading, subtitle) ->
      ArticleFull(slug, revision, title, leading, subtitle, [])
    ArticleWithError(slug, revision, title, leading, subtitle, _) ->
      ArticleFull(slug, revision, title, leading, subtitle, [])
    article -> article
  }

  let #(title, subtitle, leading) = case draft_article {
    ArticleSummary(_, _, title, leading, subtitle) -> #(
      title,
      subtitle,
      leading,
    )
    ArticleFull(_, _, title, leading, subtitle, _) -> #(
      title,
      subtitle,
      leading,
    )
    ArticleWithError(_, _, title, leading, subtitle, _) -> #(
      title,
      subtitle,
      leading,
    )
  }
  let assert Ok(index_uri) = uri.parse("/")

  [
    html.article([attr.class("with-transition")], [
      html.div([attr.class("mb-4")], [
        html.label(
          [attr.class("block text-sm font-medium text-zinc-400 mb-1")],
          [html.text("Title")],
        ),
        html.input([
          attr.class(
            "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 text-3xl text-pink-700 font-light",
          ),
          attr.value(title),
          attr.id("edit-title-" <> article.slug),
          event.on_input(fn(new_title) {
            let updated_article =
              update_article_field(draft_article, "title", new_title)
            ArticleEditUpdated(updated_article)
          }),
        ]),
      ]),
      html.div([attr.class("mb-4")], [
        html.label(
          [attr.class("block text-sm font-medium text-zinc-400 mb-1")],
          [html.text("Subtitle")],
        ),
        html.input([
          attr.class(
            "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 text-md text-zinc-500 font-light",
          ),
          attr.value(subtitle),
          attr.id("edit-subtitle-" <> article.slug),
          event.on_input(fn(new_subtitle) {
            let updated_article =
              update_article_field(draft_article, "subtitle", new_subtitle)
            ArticleEditUpdated(updated_article)
          }),
        ]),
      ]),
      html.div([attr.class("mb-4")], [
        html.label(
          [attr.class("block text-sm font-medium text-zinc-400 mb-1")],
          [html.text("Leading Text")],
        ),
        html.textarea(
          [
            attr.class(
              "w-full bg-zinc-800 border border-zinc-700 rounded-md p-2 font-bold",
            ),
            attr.value(leading),
            attr.id("edit-leading-" <> article.slug),
            attr.rows(3),
            event.on_input(fn(new_leading) {
              let updated_article =
                update_article_field(draft_article, "leading", new_leading)
              ArticleEditUpdated(updated_article)
            }),
          ],
          leading <> "maybe this is a test",
        ),
      ]),
      // Content editor with support for different content types
      case draft_article {
        ArticleFull(_, _, _, _, _, content) ->
          html.div([attr.class("mb-4")], [
            html.label(
              [attr.class("block text-sm font-medium text-zinc-400 mb-1")],
              [html.text("Content")],
            ),
            // Content blocks container
            html.div(
              [attr.class("space-y-4 mb-4")],
              list.index_map(content, fn(content_item, index) {
                view_content_editor_block(content_item, index, article.slug)
              }),
            ),
            // Add content buttons
            html.div([attr.class("flex flex-wrap gap-2 mt-4")], [
              view_add_content_button("Text", article.slug, fn() {
                let updated_content = list.append(content, [article.Text("")])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("Heading", article.slug, fn() {
                let updated_content =
                  list.append(content, [article.Heading("")])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("List", article.slug, fn() {
                let updated_content = list.append(content, [article.List([])])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("Block", article.slug, fn() {
                let updated_content = list.append(content, [article.Block([])])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("Link", article.slug, fn() {
                let updated_content =
                  list.append(content, [article.Link(index_uri, "link_title")])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("External Link", article.slug, fn() {
                let updated_content =
                  list.append(content, [
                    article.LinkExternal(index_uri, "link_title"),
                  ])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
              view_add_content_button("Image", article.slug, fn() {
                let updated_content =
                  list.append(content, [article.Image(index_uri, "")])
                let updated_article =
                  update_article_content_blocks(draft_article, updated_content)
                ArticleEditUpdated(updated_article)
              }),
            ]),
          ])
        _ -> html.div([], [])
      },
      html.div([attr.class("flex justify-end gap-4 mt-6")], [
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600",
            ),
            event.on_click(ArticleEditCancelled(draft_article)),
          ],
          [html.text("Cancel")],
        ),
        html.button(
          [
            attr.class(
              "px-4 py-2 bg-pink-700 text-white rounded-md hover:bg-pink-600",
            ),
            event.on_click(ArticleEditSaved(draft_article)),
          ],
          [html.text("Save")],
        ),
      ]),
    ]),
  ]
}

// Helper function to update article fields
fn update_article_field(
  article: Article,
  field: String,
  value: String,
) -> Article {
  case article {
    ArticleSummary(slug, revision, title, leading, subtitle) -> {
      case field {
        "title" -> ArticleSummary(slug, revision, value, leading, subtitle)
        "subtitle" -> ArticleSummary(slug, revision, title, leading, value)
        "leading" -> ArticleSummary(slug, revision, title, value, subtitle)
        _ -> article
      }
    }
    ArticleFull(slug, revision, title, leading, subtitle, content) -> {
      case field {
        "title" ->
          ArticleFull(slug, revision, value, leading, subtitle, content)
        "subtitle" ->
          ArticleFull(slug, revision, title, leading, value, content)
        "leading" ->
          ArticleFull(slug, revision, title, value, subtitle, content)
        _ -> article
      }
    }
    ArticleWithError(slug, revision, title, leading, subtitle, error) -> {
      case field {
        "title" ->
          ArticleWithError(slug, revision, value, leading, subtitle, error)
        "subtitle" ->
          ArticleWithError(slug, revision, title, leading, value, error)
        "leading" ->
          ArticleWithError(slug, revision, title, value, subtitle, error)
        _ -> article
      }
    }
  }
}

// Helper function to update article content
fn update_article_content(article: Article, content_text: String) -> Article {
  // This is a simplified implementation - in a real app you'd parse the content text
  // into proper Content structures
  case article {
    ArticleFull(slug, revision, title, leading, subtitle, _) -> {
      let parsed_content = [article.Text(content_text)]
      ArticleFull(slug, revision, title, leading, subtitle, parsed_content)
    }
    _ -> {
      // Convert other article types to ArticleFull with the new content
      let slug = article.slug
      let revision = article.revision
      let title = article.title
      let leading = article.leading
      let subtitle = article.subtitle
      let parsed_content = [article.Text(content_text)]
      ArticleFull(slug, revision, title, leading, subtitle, parsed_content)
    }
  }
}

// Helper function to convert content to string for editing
fn content_to_string(content: List(Content)) -> String {
  content
  |> list.map(fn(c) {
    case c {
      article.Text(text) -> text
      article.Image(url, alt) -> "image not implemented"
      article.Block(_) -> "block not implemented"
      article.Heading(_) -> "heading not implemented"
      article.Link(_, _) -> "link not implemented"
      article.LinkExternal(_, _) -> "link external not implemented"
      article.List(_) -> "list not implemented"
      article.Paragraph(_) -> "paragraph not implemented"
      article.Unknown(_) -> "unknown not implemented"
    }
  })
  |> string.join("\n\n")
}

fn view_article(article: Article) -> List(Element(msg)) {
  let content = case article {
    ArticleSummary(slug, _revision, title, leading, subtitle) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_paragraph([article.Text("loading content..")]),
    ]
    ArticleFull(slug, _revision, title, leading, subtitle, content) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      ..view_article_content(content)
    ]
    ArticleWithError(slug, _revision, title, leading, subtitle, error) -> [
      view_title(title, slug),
      view_subtitle(subtitle, slug),
      view_leading(leading, slug),
      view_error(error),
    ]
  }

  [
    html.article([attr.class("with-transition")], content),
    html.p([attr.class("mt-14")], [view_link(Articles, "<- Go back?")]),
  ]
}

fn view_about() -> List(Element(msg)) {
  [
    view_title("About", "about"),
    view_paragraph([
      article.Text(
        "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
      ),
    ]),
    view_paragraph([
      article.Text(
        "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
      ),
    ]),
  ]
}

fn view_not_found() -> List(Element(msg)) {
  [
    view_title("Not found", "not-found"),
    view_paragraph([
      article.Text(
        "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
      ),
    ]),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn view_edit_link(article: Article) -> Element(Msg) {
  html.a(
    [
      attr.class(
        "text-gray-500 border-e pe-4 text-underline pt-2 hover:text-teal-300 hover:border-teal-300 border-t border-gray-500",
      ),
      href(ArticleBySlugEdit(article.slug)),
    ],
    [html.text("edit")],
  )
}

fn view_title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class("text-3xl pt-8 text-pink-700 font-light"),
      attr.class("article-title"),
    ],
    [html.text(title)],
  )
}

fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.div(
    [
      attr.id("article-subtitle-" <> slug),
      attr.class("text-md text-zinc-500 font-light"),
      attr.class("article-subtitle"),
    ],
    [html.text(title)],
  )
}

fn view_leading(text: String, slug: String) -> Element(msg) {
  html.p(
    [
      attr.id("article-lead-" <> slug),
      attr.class("font-bold pt-8"),
      attr.class("article-leading"),
    ],
    [html.text(text)],
  )
}

fn view_h2(title: String) -> Element(msg) {
  html.h2(
    [
      attr.class("text-2xl text-pink-600 font-light pt-16"),
      attr.class("article-h2"),
    ],
    [html.text(title)],
  )
}

// fn view_h3(title: String) -> Element(msg) {
//   html.h3(
//     [attr.class("text-xl text-pink-600 font-light"), attr.class("article-h3")],
//     [html.text(title)],
//   )
// }

// fn view_h4(title: String) -> Element(msg) {
//   html.h4(
//     [attr.class("text-lg text-pink-600 font-light"), attr.class("article-h4")],
//     [html.text(title)],
//   )
// }

fn view_paragraph(contents: List(Content)) -> Element(msg) {
  html.p([attr.class("pt-8")], view_article_content(contents))
}

fn view_error(error_string: String) -> Element(msg) {
  html.p([attr.class("pt-8 text-orange-500")], [html.text(error_string)])
}

fn view_link(target: Route, title: String) -> Element(msg) {
  html.a(
    [href(target), attr.class("text-pink-700 hover:underline cursor-pointer")],
    [html.text(title)],
  )
}

fn view_link_external(url: Uri, title: String) -> Element(msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("text-pink-700 hover:underline cursor-pointer"),
      attr.target("_blank"),
    ],
    [html.text(title)],
  )
}

fn view_link_missing(url: Uri, title: String) -> Element(msg) {
  html.a(
    [
      attr.href(uri.to_string(url)),
      attr.class("hover:underline cursor-pointer"),
    ],
    [
      html.span([attr.class("text-orange-500")], [html.text("broken link: ")]),
      html.text(title),
    ],
  )
}

fn view_block(contents: List(Content)) -> Element(msg) {
  html.div([attr.class("pt-8")], view_article_content(contents))
}

fn view_list(items: List(Content)) -> Element(msg) {
  html.ul(
    [attr.class("pt-8 list-disc list-inside")],
    items
      |> list.map(fn(item) {
        html.li([attr.class("pt-1")], view_article_content([item]))
      }),
  )
}

fn view_unknown(content_type: String) -> Element(msg) {
  html.span([attr.class("text-orange-500")], [
    html.text("<unknown: " <> content_type <> ">"),
  ])
}

// VIEW ARTICLE CONTENT --------------------------------------------------------

fn view_article_content(contents: List(Content)) -> List(Element(msg)) {
  let view_content = fn(content: Content) -> Element(msg) {
    case content {
      article.Text(text) -> html.text(text)
      article.Block(contents) -> view_block(contents)
      article.Heading(text) -> view_h2(text)
      article.Paragraph(contents) -> view_paragraph(contents)
      article.Link(url, title) -> {
        echo "url"
        echo url
        let route = parse_route(url)
        case route {
          NotFound(_) -> view_link_missing(url, title)
          _ -> view_link(route, title)
        }
      }
      article.LinkExternal(url, title) -> view_link_external(url, title)
      article.Image(_, _) -> todo as "view content image"
      article.List(items) -> view_list(items)
      article.Unknown(content_type) -> view_unknown(content_type)
    }
  }
  list.map(contents, view_content)
}

// Helper function to create add content buttons
fn view_add_content_button(
  label: String,
  slug: String,
  on_click_handler,
) -> Element(Msg) {
  html.button(
    [
      attr.class(
        "px-3 py-1 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600 text-sm",
      ),
      event.on_click(on_click_handler()),
    ],
    [html.text("+ " <> label)],
  )
}

// Helper function to render content editor blocks based on content type
fn view_content_editor_block(
  content_item: Content,
  index: Int,
  slug: String,
) -> Element(Msg) {
  html.div([attr.class("border border-zinc-700 rounded-md p-3 bg-zinc-800")], [
    // Content type label and controls
    html.div([attr.class("flex justify-between items-center mb-2")], [
      html.span([attr.class("text-xs text-zinc-500")], [
        html.text(content_type_label(content_item)),
      ]),
      html.div([attr.class("flex gap-2")], [
        // Move up button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600",
            ),
            event.on_click(ArticleEditContentMoveUp(index)),
            attr.disabled(index == 0),
          ],
          [html.text("↑")],
        ),
        // Move down button
        html.button(
          [
            attr.class(
              "text-xs px-2 py-1 bg-zinc-700 rounded hover:bg-zinc-600",
            ),
            event.on_click(ArticleEditContentMoveDown(index)),
          ],
          [html.text("↓")],
        ),
        // Delete button
        html.button(
          [
            attr.class("text-xs px-2 py-1 bg-red-900 rounded hover:bg-red-800"),
            event.on_click(ArticleEditContentRemove(index)),
          ],
          [html.text("×")],
        ),
      ]),
    ]),
    // Content editor based on type
    case content_item {
      article.Text(text) ->
        html.textarea(
          [
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.rows(3),
            attr.value(text),
            event.on_input(fn(new_text) {
              ArticleEditContentUpdate(index, article.Text(new_text))
            }),
          ],
          text,
        )

      article.Heading(text) ->
        html.input([
          attr.class(
            "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2 text-xl text-pink-600",
          ),
          attr.value(text),
          event.on_input(fn(new_text) {
            ArticleEditContentUpdate(index, article.Heading(new_text))
          }),
        ])

      article.Link(url, title) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Link text"),
            attr.value(title),
            event.on_input(fn(new_title) {
              ArticleEditContentUpdate(index, article.Link(url, new_title))
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("URL (e.g., /articles)"),
            attr.value(uri.to_string(url)),
            event.on_input(fn(new_url) {
              case uri.parse(new_url) {
                Ok(parsed_url) ->
                  ArticleEditContentUpdate(
                    index,
                    article.Link(parsed_url, title),
                  )
                Error(_) ->
                  ArticleEditContentUpdate(index, article.Link(url, title))
              }
            }),
          ]),
        ])

      article.LinkExternal(url, title) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Link text"),
            attr.value(title),
            event.on_input(fn(new_title) {
              ArticleEditContentUpdate(
                index,
                article.LinkExternal(url, new_title),
              )
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("URL (e.g., https://example.com)"),
            attr.value(uri.to_string(url)),
            event.on_input(fn(new_url) {
              case uri.parse(new_url) {
                Ok(parsed_url) ->
                  ArticleEditContentUpdate(
                    index,
                    article.LinkExternal(parsed_url, title),
                  )
                Error(_) ->
                  ArticleEditContentUpdate(
                    index,
                    article.LinkExternal(url, title),
                  )
              }
            }),
          ]),
        ])

      article.Image(url, alt) ->
        html.div([attr.class("space-y-2")], [
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Alt text"),
            attr.value(alt),
            event.on_input(fn(new_alt) {
              ArticleEditContentUpdate(index, article.Image(url, new_alt))
            }),
          ]),
          html.input([
            attr.class(
              "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
            ),
            attr.placeholder("Image URL"),
            attr.value(uri.to_string(url)),
            event.on_input(fn(new_url) {
              case uri.parse(new_url) {
                Ok(parsed_url) ->
                  ArticleEditContentUpdate(
                    index,
                    article.Image(parsed_url, alt),
                  )
                Error(_) ->
                  ArticleEditContentUpdate(index, article.Image(url, alt))
              }
            }),
          ]),
        ])

      article.List(items) ->
        html.div(
          [attr.class("space-y-2")],
          list.append(
            list.index_map(items, fn(item, item_index) {
              html.div([attr.class("flex gap-2")], [
                html.input([
                  attr.class(
                    "w-full bg-zinc-900 border border-zinc-700 rounded-md p-2",
                  ),
                  attr.value(content_to_string([item])),
                  event.on_input(fn(new_text) {
                    let updated_items =
                      list_set(items, item_index, article.Text(new_text))
                    ArticleEditContentUpdate(index, article.List(updated_items))
                  }),
                ]),
                html.button(
                  [
                    attr.class("px-2 bg-zinc-700 rounded hover:bg-zinc-600"),
                    event.on_click(ArticleEditContentListItemRemove(
                      index,
                      item_index,
                    )),
                  ],
                  [html.text("×")],
                ),
              ])
            }),
            [
              html.button(
                [
                  attr.class(
                    "w-full mt-2 px-2 py-1 bg-zinc-700 text-zinc-300 rounded hover:bg-zinc-600 text-sm",
                  ),
                  event.on_click(ArticleEditContentListItemAdd(index)),
                ],
                [html.text("+ Add Item")],
              ),
            ],
          ),
        )

      article.Block(contents) ->
        html.div([attr.class("space-y-2")], [
          html.div(
            [attr.class("bg-zinc-900 border border-zinc-700 rounded-md p-3")],
            [
              html.div([attr.class("mb-2 text-xs text-zinc-500")], [
                html.text("Block Contents"),
              ]),
              // Nested content blocks
              html.div(
                [attr.class("space-y-3")],
                list.index_map(contents, fn(nested_content, nested_index) {
                  html.div([attr.class("flex gap-2")], [
                    html.textarea(
                      [
                        attr.class(
                          "w-full bg-zinc-950 border border-zinc-700 rounded-md p-2",
                        ),
                        attr.rows(2),
                        attr.value(content_to_string([nested_content])),
                        event.on_input(fn(new_text) {
                          let updated_contents =
                            list_set(
                              contents,
                              nested_index,
                              article.Text(new_text),
                            )
                          ArticleEditContentUpdate(
                            index,
                            article.Block(updated_contents),
                          )
                        }),
                      ],
                      content_to_string([nested_content]),
                    ),
                    html.button(
                      [
                        attr.class("px-2 bg-zinc-700 rounded hover:bg-zinc-600"),
                        event.on_click(ArticleEditContentListItemRemove(
                          index,
                          nested_index,
                        )),
                      ],
                      [html.text("×")],
                    ),
                  ])
                }),
              ),
              html.button(
                [
                  attr.class(
                    "w-full mt-2 px-2 py-1 bg-zinc-700 text-zinc-300 rounded hover:bg-zinc-600 text-sm",
                  ),
                  event.on_click(ArticleEditContentListItemAdd(index)),
                ],
                [html.text("+ Add Block Item")],
              ),
            ],
          ),
        ])

      _ ->
        html.div([], [
          html.text(
            "Unsupported content type: " <> content_type_label(content_item),
          ),
        ])
    },
  ])
}

// Helper function to get a label for content type
fn content_type_label(content: Content) -> String {
  case content {
    article.Text(_) -> "Text"
    article.Heading(_) -> "Heading"
    article.Link(_, _) -> "Link"
    article.LinkExternal(_, _) -> "External Link"
    article.Image(_, _) -> "Image"
    article.List(_) -> "List"
    article.Block(_) -> "Block"
    article.Paragraph(_) -> "Paragraph"
    article.Unknown(type_) -> "Unknown: " <> type_
  }
}

// Helper function to update article content blocks
fn update_article_content_blocks(
  article: Article,
  content: List(Content),
) -> Article {
  case article {
    ArticleFull(slug, revision, title, leading, subtitle, _) ->
      ArticleFull(slug, revision, title, leading, subtitle, content)
    _ -> {
      // Convert other article types to ArticleFull with the new content
      let slug = article.slug
      let revision = article.revision
      let title = article.title
      let leading = article.leading
      let subtitle = article.subtitle
      ArticleFull(slug, revision, title, leading, subtitle, content)
    }
  }
}

// Add this helper function near your other helpers
fn list_set(list: List(a), index: Int, value: a) -> List(a) {
  list
  |> list.index_map(fn(item, i) {
    case i == index {
      True -> value
      False -> item
    }
  })
}

fn list_at(list: List(a), index: Int) -> Result(a, Nil) {
  list
  |> list.index_map(fn(item, i) { #(item, i) })
  |> list.find(fn(pair) { pair.1 == index })
  |> result.map(fn(pair) { pair.0 })
}
