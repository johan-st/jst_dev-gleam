import article.{type Article}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

import session
import utils/error_string
import utils/jot_to_lustre
import utils/remote_data.{Errored, Loaded, NotInitialized, Pending}

import routes
import view/page/partials/article_partials as parts
import view/ui

pub fn view_article_page(
  article: Article,
  sess: session.Session,
  edit_msg: fn(uri.Uri) -> msg,
  publish_msg: fn(Article) -> msg,
  unpublish_msg: fn(Article) -> msg,
  delete_msg: fn(Article) -> msg,
  delete_confirm_msg: fn(Article) -> msg,
  delete_cancel_msg: fn() -> msg,
  delete_confirmation: Option(#(String, msg)),
) -> List(Element(msg)) {
  let content: List(Element(msg)) = jot_to_lustre.to_lustre(article.content)
  let action_buttons =
    parts.view_article_actions(
      article,
      sess,
      edit_msg,
      publish_msg,
      unpublish_msg,
      delete_msg,
      delete_confirm_msg,
      delete_cancel_msg,
      delete_confirmation,
    )

  [
    html.article([], [
      // Top actions bar
      html.div([attr.class("flex justify-end gap-3 mb-4")], action_buttons),
      // Header block
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
      // Leading and content
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
