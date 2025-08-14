import article.{type Article}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

import session
import utils/error_string
import utils/jot_to_lustre
import utils/remote_data.{Errored, Loaded, NotInitialized, Pending}

import view/page/partials/article_partials as parts
import view/ui

pub fn view_article_page(
  article: Article,
  _sess: session.Session,
) -> List(Element(msg)) {
  let content: List(Element(msg)) = case article.content {
    NotInitialized -> [parts.view_error("content not initialized")]
    Pending(_, _) -> [
      ui.loading_bar(ui.ColorTeal),
      ui.loading("Loading article...", ui.ColorNeutral),
    ]
    Loaded(content_string, _, _) -> jot_to_lustre.to_lustre(content_string)
    Errored(error, _) -> [parts.view_error(error_string.http_error(error))]
  }

  [
    html.article([], [
      html.div([attr.class("flex flex-col justify-between group")], [
        html.div([attr.class("flex gap-2 justify-between")], [
          html.div([attr.class("flex flex-col justify-between")], [
            parts.view_title(article.title, article.slug),
            parts.view_subtitle(article.subtitle, article.slug),
          ]),
          html.div([attr.class("flex flex-col items-end ")], [
            parts.view_publication_status(article),
            parts.view_author(article.author),
          ]),
        ]),
        html.div([attr.class("flex justify-between mt-2")], [
          parts.view_article_tags(article.tags),
        ]),
      ]),
      parts.view_leading(article.leading, article.slug),
      ..content
    ]),
  ]
}

pub fn view_article_not_found(slug: String) -> List(Element(msg)) {
  [
    parts.view_title("Article not found", slug),
    parts.view_simple_paragraph(
      "The article you are looking for does not exist.",
    ),
  ]
}
