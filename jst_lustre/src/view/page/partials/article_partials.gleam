import article.{type Article}
import birl
import gleam/list
import gleam/option.{None, Some}
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import routes

// Generic, message-agnostic partials for article-related UI bits

pub fn view_publication_status(article: Article) -> Element(msg) {
  case article.published_at {
    Some(published_time) -> {
      let formatted_date = birl.to_naive_date_string(published_time)
      html.span(
        [
          attr.class(
            "text-xs text-zinc-500 px-4 pt-2 w-max border-t-2 border-r-2 border-zinc-700 group-hover:border-pink-700 transition-colors duration-25",
          ),
        ],
        [html.text(formatted_date)],
      )
    }
    None ->
      html.span(
        [
          attr.class(
            "text-xs text-zinc-500 px-4 pt-2 w-max italic border-t-2 border-r-2 border-zinc-700 group-hover:border-pink-700 transition-colors duration-25",
          ),
        ],
        [html.text("not published")],
      )
  }
}

pub fn view_author(author: String) -> Element(msg) {
  html.div(
    [
      attr.class(
        "text-xs text-zinc-400 pt-0 border-r-2 border-zinc-700 pr-4 group-hover:border-pink-700 transition-colors duration-25",
      ),
    ],
    [
      html.span([attr.class("text-zinc-500 font-light")], [html.text("by ")]),
      html.span([attr.class("text-zinc-300")], [html.text(author)]),
    ],
  )
}

pub fn view_article_tags(tags: List(String)) -> Element(msg) {
  case tags {
    [] -> element.none()
    _ ->
      html.div(
        [
          attr.class(
            "flex justify-end align-end gap-0 ml-auto flex-wrap border-b-2 border-r-2 border-zinc-700 pb-1 pr-2 hover:border-pink-700 group-hover:border-pink-700 transition-colors duration-25 mt-2",
          ),
        ],
        list.map(tags, fn(tag) {
          html.span(
            [
              attr.class(
                "text-xs cursor-pointer text-zinc-500 px-2 hover:border-pink-700 hover:text-pink-700 transition-colors duration-25",
              ),
            ],
            [html.text(tag)],
          )
        }),
      )
  }
}

pub fn view_title(title: String, slug: String) -> Element(msg) {
  html.h1(
    [
      attr.id("article-title-" <> slug),
      attr.class(
        "text-2xl sm:text-3xl sm:h-10 md:text-4xl md:h-12 font-bold text-pink-700",
      ),
    ],
    [html.text(title)],
  )
}

pub fn view_subtitle(title: String, slug: String) -> Element(msg) {
  html.h2(
    [
      attr.id("article-subtitle-" <> slug),
      attr.class("text-md text-zinc-500 font-light pt-1"),
    ],
    [html.text(title)],
  )
}

pub fn view_leading(text: String, slug: String) -> Element(msg) {
  html.p(
    [
      attr.id("article-leading-" <> slug),
      attr.class("text-lg text-zinc-200 font-bold pt-4"),
    ],
    [html.text(text)],
  )
}

pub fn view_simple_paragraph(text: String) -> Element(msg) {
  html.p([attr.class("pt-8")], [html.text(text)])
}

pub fn view_error(error_string: String) -> Element(msg) {
  html.div([attr.class("text-red-400 border border-red-700 rounded p-4")], [
    html.text(error_string),
  ])
}

/// Dedicated article card with bespoke structure/styling
pub fn view_article_card(article: Article) -> Element(msg) {
  case article {
    article.ArticleV1(
      id: _,
      slug:,
      author:,
      title:,
      leading:,
      subtitle:,
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
                  "pointer-events-none absolute top-0 left-0 w-6 h-6 border-t-2 border-zinc-700 transition-colors duration-150 group-hover:border-pink-700",
                ),
              ],
              [],
            ),
            html.span(
              [
                attr.class(
                  "pointer-events-none absolute bottom-0 left-0 w-6 h-6 border-b-2 border-zinc-700 transition-colors duration-150 group-hover:border-pink-700",
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
                  [html.text(title)],
                ),
                view_subtitle(subtitle, slug),
              ]),
              html.div([attr.class("flex flex-col items-end")], [
                view_publication_status(article),
                view_author(author),
              ]),
            ]),
            view_simple_paragraph(leading),
            html.div([attr.class("flex justify-end mt-2")], [
              view_article_tags(tags),
            ]),
          ],
        ),
      ])
    }
  }
}
