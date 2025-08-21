import article.{type Article}
import birl
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

import routes
import session
import view/page/partials/article_partials as parts
import view/ui

pub fn view(
  in_sync: Bool,
  articles: List(Article),
  sess: session.Session,
) -> List(Element(msg)) {
  let filtered_articles = case sess {
    session.Unauthenticated ->
      articles
      |> list.filter(fn(article) {
        case article.published_at {
          Some(_) -> True
          None -> False
        }
      })
    _ -> articles
  }

  let articles_elements =
    filtered_articles
    |> list.sort(fn(a, b) {
      case a.published_at, b.published_at {
        None, None -> string.compare(a.slug, b.slug)
        None, Some(_) -> order.Lt
        Some(_), None -> order.Gt
        Some(da), Some(db) -> birl.compare(db, da)
      }
    })
    |> list.map(parts.view_article_card)

  let header_section = [
    ui.flex_between(ui.page_title("Articles"), element.none()),
  ]

  let content_section = case articles_elements {
    [] -> [
      ui.empty_state(
        "No articles yet",
        case sess {
          session.Authenticated(_) ->
            "Ready to share your thoughts? Create your first article to get started."
          _ ->
            "No published articles are available yet. Check back later for new content!"
        },
        None,
      ),
    ]
    _ -> articles_elements
  }

  list.append(header_section, content_section)
}

pub fn view_article_listing(
  articles: List(Article),
  sess: session.Session,
) -> List(Element(msg)) {
  let filtered_articles = case sess {
    session.Unauthenticated ->
      articles
      |> list.filter(fn(article) {
        case article.published_at {
          Some(_) -> True
          None -> False
        }
      })
    _ -> articles
  }

  let articles_elements =
    filtered_articles
    |> list.sort(fn(a, b) {
      case a.published_at, b.published_at {
        None, None -> string.compare(a.slug, b.slug)
        None, Some(_) -> order.Lt
        Some(_), None -> order.Gt
        Some(da), Some(db) -> birl.compare(db, da)
      }
    })
    |> list.map(fn(article) {
      case article {
        article.ArticleV1(
          id: _,
          slug:,
          author: _,
          title: _,
          leading: _,
          subtitle: _,
          content: _,
          draft: _,
          published_at: _,
          revision: _,
          tags:,
        ) -> {
          let article_uri = routes.Article(slug) |> routes.to_uri
          html.article([attr.class("mt-6 group hover:bg-zinc-700/10")], [
            html.a(
              [
                attr.class(
                  "relative group block border-l-8 border-zinc-700 pl-4 hover:border-pink-700 transition-colors duration-150",
                ),
                attr.href(uri.to_string(article_uri)),
              ],
              [
                html.span(
                  [
                    attr.class(
                      "pointer-events-none absolute top-0 left-0 w-6 h-6 border-t border-zinc-700 transition-colors duration-150 group-hover:border-pink-700",
                    ),
                  ],
                  [],
                ),
                html.span(
                  [
                    attr.class(
                      "pointer-events-none absolute bottom-0 left-0 w-6 h-6 border-b border-zinc-700 transition-colors duration-150 group-hover:border-pink-700",
                    ),
                  ],
                  [],
                ),
                html.div([attr.class("flex justify-between gap-4")], [
                  html.div([attr.class("flex flex-col")], [
                    html.h3(
                      [
                        attr.id("article-title-" <> slug),
                        attr.class("article-title"),
                        attr.class("text-xl text-pink-700 font-light pt-4"),
                      ],
                      [html.text(article.title)],
                    ),
                    parts.view_subtitle(article.subtitle, slug),
                  ]),
                  html.div([attr.class("flex flex-col items-end")], [
                    parts.view_publication_status(article),
                    parts.view_author(article.author),
                  ]),
                ]),
                parts.view_simple_paragraph(article.leading),
                html.div([attr.class("flex justify-end mt-2")], [
                  parts.view_article_tags(tags),
                ]),
              ],
            ),
          ])
        }
      }
    })

  let header_section = [
    ui.flex_between(ui.page_title("Articles"), html.div([], [])),
  ]

  let content_section = case articles_elements {
    [] -> [
      ui.empty_state(
        "No articles yet",
        "No published articles are available yet. Check back later for new content!",
        None,
      ),
    ]
    _ -> articles_elements
  }

  list.append(header_section, content_section)
}
