import gleam/int
import gleam/list
import gleam/string
import gleam/option.{type Option, None, Some}
import gleam/uri
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import components/ui
import utils/remote_data.{type RemoteData, Loaded}
import utils/short_url.{type ShortUrl}
import view/common
import routes
import birl
import utils/jot_to_lustre as jot_to_lustre
import lustre/event

pub fn loading_page() -> List(Element(msg)) {
  [ui.loading_state("Loading page...", None, ui.ColorNeutral)]
}

pub fn article_list_loading() -> List(Element(msg)) {
  [ui.page_title("Articles"), ui.loading_state("Loading articles...", None, ui.ColorNeutral)]
}

pub fn djot_demo(
  content: String,
  on_input: fn(String) -> msg,
) -> List(Element(msg)) {
  let preview_content = case content {
    "" -> [html.div([attr.class("text-zinc-500 italic text-center mt-8")], [html.text("Start typing in the editor to see the preview here...")])]
    _ -> jot_to_lustre.to_lustre(content)
  }
  [
    common.title("Djot Demo", "djot-demo"),
    html.div([attr.class("grid grid-cols-1 lg:grid-cols-2 gap-6")], [
      html.section([attr.class("space-y-4")], [
        html.div([attr.class("flex items-center justify-between")], [
          html.h2([attr.class("text-xl text-pink-700 font-light")], [html.text("Editor")]),
          html.div([attr.class("text-xs text-zinc-500")], [html.text("Live preview updates as you type")]),
        ]),
        html.div([attr.class("relative")], [
          html.textarea([
            attr.class("w-full h-[400px] lg:h-[600px] bg-zinc-800 border border-zinc-600 rounded-lg p-4 font-mono text-sm text-zinc-100 resize-none focus:border-pink-700 focus:ring-1 focus:ring-pink-700 focus:outline-none transition-colors duration-200"),
            attr.placeholder("# Start typing your article content here...\n\n## Headings\n\n- Lists\n- Work too\n\n**Bold** and *italic* text\n\n[Link text](url)"),
            attr.value(content),
            event.on_input(on_input),
            attr.attribute("spellcheck", "false"),
          ], content),
          html.div([attr.class("absolute bottom-2 right-2 text-xs text-zinc-500 bg-zinc-800 px-2 py-1 rounded")], [html.text(string.length(content) |> string.inspect), html.text(" chars")]),
        ]),
      ]),
      html.section([attr.class("space-y-4")], [
        html.div([attr.class("flex items-center justify-between")], [
          html.h2([attr.class("text-xl text-pink-700 font-light")], [html.text("Preview")]),
          html.div([attr.class("text-xs text-zinc-500")], [html.text("Rendered output")]),
        ]),
        html.div([attr.class("w-full h-[400px] lg:h-[600px] bg-zinc-900 border border-zinc-600 rounded-lg p-6 overflow-y-auto prose prose-invert prose-pink max-w-none")], preview_content),
      ]),
    ]),
  ]
}

pub type UrlInfoCallbacks(msg) {
  UrlInfoCallbacks(
    on_back: msg,
    on_copy: fn(String) -> msg,
    on_toggle_active: fn(String, Bool) -> msg,
    on_delete: fn(String) -> msg,
  )
}

pub fn url_info(
  urls: RemoteData(List(ShortUrl), a),
  short_code: String,
  copy_feedback: Option(String),
  cbs: UrlInfoCallbacks(msg),
) -> List(Element(msg)) {
  case urls {
    Loaded(list_, _, _) -> {
      case list.find(list_, fn(u) { u.short_code == short_code }) {
        Ok(url) -> [
          common.title("URL Info", "url-info"),
          html.div([attr.class("mt-8 p-6 bg-zinc-800 rounded-lg border border-zinc-700")], [
            html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [html.text("URL Details")]),
            html.div([attr.class("space-y-4 text-zinc-300")], [
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Short Code:")]), html.span([attr.class("font-mono text-pink-700")], [html.text(url.short_code)])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Target URL:")]), html.span([attr.class("break-all")], [html.text(url.target_url)])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Created By:")]), html.span([], [html.text(url.created_by)])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Created:")]), html.span([], [html.text(birl.from_unix_milli(url.created_at * 1000) |> birl.to_naive_date_string)])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Updated:")]), html.span([], [html.text(birl.from_unix_milli(url.updated_at * 1000) |> birl.to_naive_date_string)])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Access Count:")]), html.span([], [html.text(int.to_string(url.access_count))])]),
              html.div([attr.class("flex justify-between items-center")], [html.span([attr.class("text-zinc-500")], [html.text("Status:")]), case url.is_active { True -> html.span([attr.class("text-green-400")], [html.text("Active")]) False -> html.span([attr.class("text-red-400")], [html.text("Inactive")]) }]),
            ]),
            html.div([attr.class("mt-6 flex gap-4")], [
              ui.button("Back to URLs", ui.ColorTeal, ui.ButtonStateNormal, cbs.on_back),
              ui.button(case copy_feedback == Some(url.short_code) { True -> "Copied!" False -> "Copy URL" }, ui.ColorTeal, ui.ButtonStateNormal, cbs.on_copy(url.short_code)),
              ui.button(case url.is_active { True -> "Deactivate" False -> "Activate" }, case url.is_active { True -> ui.ColorOrange False -> ui.ColorTeal }, ui.ButtonStateNormal, cbs.on_toggle_active(url.id, url.is_active)),
              ui.button("Delete URL", ui.ColorRed, ui.ButtonStateNormal, cbs.on_delete(url.id)),
            ]),
          ]),
        ]
        Error(_) -> [common.title("URL Not Found", "url-not-found"), common.simple_paragraph("The requested URL was not found.")]
      }
    }
    _ -> [common.title("URL Info", "url-info"), common.simple_paragraph("Loading URL information...")]
  }
}

pub fn not_found(requested_uri: uri.Uri) -> List(Element(msg)) {
  [
    common.title("404 - Page Not Found", "not-found"),
    common.subtitle("The page you're looking for doesn't exist.", "not-found"),
    common.simple_paragraph("The page at " <> uri.to_string(requested_uri) <> " could not be found."),
  ]
}

pub fn error_state(msg: String) -> Element(msg) {
  ui.error_state(ui.ErrorGeneric, "Something went wrong", msg, None)
}

pub fn article_edit_not_found(id: String) -> List(Element(msg)) {
  [
    common.title("Article not found", id),
    common.simple_paragraph("The article you are looking for does not exist."),
  ]
}

