import components/ui
import gleam/int
import gleam/option.{None, Some}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import article/draft
import article/article.{type Article} as article
import session
import utils/remote_data as rd
import components/ui as ui
import utils/mouse as mouse

pub type Callbacks(msg) {
  Callbacks(
    on_toggle_mode: msg,
    on_update_slug: fn(String) -> msg,
    on_update_title: fn(String) -> msg,
    on_update_subtitle: fn(String) -> msg,
    on_update_leading: fn(String) -> msg,
    on_update_content: fn(String) -> msg,
    on_discard: msg,
    on_save: msg,
  )
}

pub fn view(
  art: article.Article,
  d: draft.Draft,
  is_preview_mode: Bool,
  cbs: Callbacks(msg),
) -> List(Element(msg)) {
  edit_layout(art, d, is_preview_mode, cbs)
}

fn edit_layout(
  art: article.Article,
  d: draft.Draft,
  is_preview_mode: Bool,
  cbs: Callbacks(msg),
) -> List(Element(msg)) {
  let preview_content = case draft.content(d) {
    "" -> "Start typing in the editor to see the preview here..."
    content -> content
  }
  let draft_article = article.ArticleV1(
    author: article.author(art),
    published_at: article.published_at(art),
    tags: [],
    title: draft.title(d),
    content: rd.to_loaded(rd.NotInitialized, preview_content),
    draft: None,
    id: article.content(art) |> fn(_) { art.id },
    leading: draft.leading(d),
    revision: 0,
    slug: draft.slug(d),
    subtitle: draft.subtitle(d),
  )
  let preview = pages/article_view.view_article_page(draft_article, session.Unauthenticated)
  [
    html.div([attr.class("lg:hidden mb-4 flex justify-center")], [
      ui.button(case is_preview_mode { False -> "Show Preview" True -> "Show Editor" }, ui.ColorTeal, ui.ButtonStateNormal, cbs.on_toggle_mode),
    ]),
    html.div([
      attr.classes([#("grid gap-4 lg:gap-8 h-screen", True), #("grid-cols-1 lg:grid-cols-2", True)]),
    ], [
      html.div([
        attr.classes([
          #("space-y-4", True),
          #("lg:block", True),
          #("lg:col-span-1", True),
          #("col-span-2", !is_preview_mode),
          #("hidden", is_preview_mode),
        ]),
      ], view_edit_actions(d, art, cbs)),
      html.div([
        attr.classes([
          #("max-w-screen-md mx-auto px-10 py-10 overflow-y-auto", True),
          #("lg:block", True),
          #("lg:col-span-1", True),
          #("col-span-2", is_preview_mode),
          #("hidden", !is_preview_mode),
        ]),
      ], preview),
    ]),
    view_djot_quick_reference(),
  ]
}

fn view_edit_actions(d: draft.Draft, art: article.Article, cbs: Callbacks(msg)) -> List(Element(msg)) {
  [
    html.div([attr.class("mb-4")], [
      html.div([attr.class("flex items-center justify-between mb-1")], [
        html.label([attr.class("block text-sm font-medium text-zinc-400")], [html.text("Slug")]),
        html.span([attr.class("text-xs text-zinc-500")], [html.text("rev 0")]),
      ]),
      html.input([
        attr.class("w-full bg-zinc-800 border border-zinc-600 rounded-md p-3 sm:p-2 font-light text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200"),
        attr.value(draft.slug(d)),
        attr.id("edit-" <> draft.slug(d) <> "-Slug"),
        event.on_input(cbs.on_update_slug),
      ]),
    ]),
    view_article_edit_input("Title", ArticleEditInputTypeTitle, draft.title(d), cbs.on_update_title, draft.slug(d)),
    view_article_edit_input("Subtitle", ArticleEditInputTypeSubtitle, draft.subtitle(d), cbs.on_update_subtitle, draft.slug(d)),
    html.div([attr.class("mb-4")], [
      html.label([attr.class("block text-sm font-medium text-zinc-400 mb-1")], [html.text("Leading")]),
      html.textarea([
        attr.class("w-full h-20 sm:h-24 bg-zinc-800 border border-zinc-600 rounded-md p-3 sm:p-2 font-bold text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200"),
        attr.value(draft.leading(d)),
        event.on_input(cbs.on_update_leading),
        attr.placeholder("Write a compelling leading paragraph..."),
      ], draft.leading(d)),
    ]),
    html.div([attr.class("mb-4")], [
      html.label([attr.class("block text-sm font-medium text-zinc-400 mb-1")], [html.text("Content")]),
      html.textarea([
        attr.class("w-full h-64 sm:h-80 lg:h-96 bg-zinc-800 border border-zinc-600 rounded-md p-4 font-mono text-sm text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200"),
        attr.value(draft.content(d)),
        event.on_input(cbs.on_update_content),
        attr.placeholder("Write your article content in Djot format..."),
      ], draft.content(d)),
    ]),
    html.div([attr.class("flex justify-between gap-4")], [
      html.div([], []),
      html.div([attr.class("flex gap-4")], [
        html.button([
          attr.class("px-4 py-2 bg-zinc-700 text-zinc-300 rounded-md hover:bg-zinc-600 transition-colors duration-200"),
          mouse.on_mouse_down_no_right(cbs.on_discard),
        ], [html.text("Discard Changes")]),
        html.button([
          attr.class("px-4 py-2 bg-teal-700 text-white rounded-md hover:bg-teal-600 transition-colors duration-200"),
          mouse.on_mouse_down_no_right(cbs.on_save),
        ], [html.text("Save Article")]),
      ]),
    ]),
  ]
}

type ArticleEditInputType {
  ArticleEditInputTypeSlug
  ArticleEditInputTypeTitle
  ArticleEditInputTypeSubtitle
  ArticleEditInputTypeLeading
}

fn view_article_edit_input(
  label: String,
  input_type: ArticleEditInputType,
  value: String,
  on_input: fn(String) -> msg,
  article_slug: String,
) -> Element(msg) {
  let label_classes = attr.class("block text-sm font-medium text-zinc-400 mb-1")
  let input_classes = case input_type {
    ArticleEditInputTypeSlug -> attr.class("w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 font-light text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200")
    ArticleEditInputTypeTitle -> attr.class("w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-3xl text-pink-700 font-light focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200")
    ArticleEditInputTypeSubtitle -> attr.class("w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 text-md text-zinc-500 font-light focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200")
    ArticleEditInputTypeLeading -> attr.class("w-full bg-zinc-800 border border-zinc-600 rounded-md p-2 font-bold text-zinc-100 focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200")
  }
  html.div([attr.class("mb-4")], [
    html.label([label_classes], [html.text(label)]),
    html.input([
      input_classes,
      attr.value(value),
      attr.id("edit-" <> article_slug <> "-" <> label),
      event.on_input(on_input),
    ]),
  ])
}

fn view_djot_quick_reference() -> Element(Msg) {
  html.div([
    attr.class("mt-8 p-4 bg-zinc-800 rounded-lg border border-zinc-700")
  ], [html.text("")])
}

