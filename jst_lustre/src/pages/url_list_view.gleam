import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/int
import birl

import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

import utils/remote_data.{type RemoteData, Loaded, Pending, NotInitialized, Errored}
import utils/http.{type HttpError}
import utils/short_url.{type ShortUrl}
import utils/mouse
import components/ui

pub type Callbacks(msg) {
  Callbacks(
    copy_clicked: fn(String) -> msg,
    toggle_active_clicked: fn(String, Bool) -> msg,
    toggle_expanded: fn(String) -> msg,
    delete_clicked: fn(String) -> msg,
    delete_confirm_clicked: fn(String) -> msg,
    delete_cancel_clicked: fn() -> msg,
  )
}

pub fn list(
  urls: RemoteData(List(ShortUrl), HttpError),
  expanded_ids: Set(String),
  delete_confirmation: Option(String),
  copy_feedback: Option(String),
  cbs: Callbacks(msg),
) -> Element(msg) {
  case urls {
    NotInitialized | Pending(_, _) ->
      ui.card("urls", [
        html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
          html.text("URLs"),
        ]),
        ui.loading("Loading URLs...", ui.ColorNeutral),
      ])
    Loaded(short_urls, _, _) -> {
      case short_urls {
        [] ->
          ui.card("urls", [
            html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
              html.text("URLs"),
            ]),
            ui.empty_state(
              "No short URLs created yet",
              "Create your first short URL using the form above.",
              None,
            ),
          ])
        _ -> {
          let url_elements =
            list.map(short_urls, fn(url) {
              let is_expanded = set.contains(expanded_ids, url.id)
              case is_expanded {
                True -> expanded_url_card(copy_feedback, cbs, url)
                False -> compact_url_card(copy_feedback, cbs, url)
              }
            })
          ui.card("urls", [
            html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
              html.text("URLs"),
            ]),
            html.ul([attr.class("space-y-2"), attr.role("list")], url_elements),
            case delete_confirmation {
              Some(delete_id) -> delete_confirmation_modal(delete_id, short_urls, cbs)
              None -> html.div([], [])
            },
          ])
        }
      }
    }
    Errored(error, _) ->
      ui.card("urls", [
        html.h3([attr.class("text-lg text-pink-700 font-light mb-6")], [
          html.text("URLs"),
        ]),
        html.div([attr.class("text-center py-12")], [
          html.div([attr.class("text-red-400 text-lg mb-2")], [
            html.text("Error loading short URLs"),
          ]),
          html.div([attr.class("text-zinc-500 text-sm")], [
            html.text(http_error_to_string(error)),
          ]),
        ]),
      ])
  }
}

fn compact_url_card(
  copy_feedback: Option(String),
  cbs: Callbacks(msg),
  url: ShortUrl,
) -> Element(msg) {
  html.li(
    [attr.class("bg-zinc-800 border border-zinc-700 rounded-lg transition-colors")],
    [
      html.div([attr.class("flex items-center justify-between p-4")], [
        html.div([attr.class("flex items-center space-x-4 flex-1 min-w-0")], [
          html.button(
            [
              attr.class(
                "font-mono text-sm font-medium text-zinc-100 hover:text-pink-300 transition-colors cursor-pointer",
              ),
              mouse.on_mouse_down_no_right(cbs.copy_clicked(url.short_code)),
              attr.title("Click to copy short URL"),
            ],
            [
              html.span([attr.class("text-zinc-500")], [html.text("u.jst.dev/")]),
              html.span([attr.class("text-pink-400")], [html.text(url.short_code)]),
              case copy_feedback == Some(url.short_code) {
                True -> html.span([attr.class("ml-2 text-green-400 text-xs")], [html.text("✓ Copied!")])
                False -> html.div([], [])
              },
            ],
          ),
          html.div(
            [
              attr.class("text-sm text-zinc-400 truncate flex-1 cursor-pointer hover:text-zinc-300 transition-colors"),
              attr.title(url.target_url),
              mouse.on_mouse_down_no_right(cbs.toggle_expanded(url.id)),
            ],
            [html.span([attr.class("text-zinc-600")], [html.text("→ ")]), html.text(url.target_url)],
          ),
          html.button(
            [
              attr.class("cursor-pointer"),
              mouse.on_mouse_down_no_right(cbs.toggle_active_clicked(url.id, url.is_active)),
              attr.title("Toggle active/inactive"),
            ],
            [
              case url.is_active {
                True -> ui.status_badge("Active", ui.ColorGreen)
                False -> ui.status_badge("Inactive", ui.ColorRed)
              }
            ],
          ),
        ]),
        html.div(
          [
            attr.class("flex items-center space-x-2 ml-4 cursor-pointer hover:text-zinc-300 transition-colors"),
            mouse.on_mouse_down_no_right(cbs.toggle_expanded(url.id)),
          ],
          [html.div([attr.class("text-zinc-500 text-sm")], [html.text("▼")])],
        ),
      ]),
    ],
  )
}

fn expanded_url_card(
  copy_feedback: Option(String),
  cbs: Callbacks(msg),
  url: ShortUrl,
) -> Element(msg) {
  html.li(
    [attr.class("bg-zinc-800 border border-zinc-700 rounded-lg transition-colors")],
    [
      html.div([attr.class("flex items-center justify-between p-4")], [
        html.div([attr.class("flex items-center space-x-4 flex-1 min-w-0")], [
          html.button(
            [
              attr.class(
                "font-mono text-sm font-medium text-zinc-100 hover:text-pink-300 transition-colors cursor-pointer",
              ),
              mouse.on_mouse_down_no_right(cbs.copy_clicked(url.short_code)),
              attr.title("Click to copy short URL"),
            ],
            [
              html.span([attr.class("text-zinc-500")], [html.text("u.jst.dev/")]),
              html.span([attr.class("text-pink-400")], [html.text(url.short_code)]),
              case copy_feedback == Some(url.short_code) {
                True -> html.span([attr.class("ml-2 text-green-400 text-xs")], [html.text("✓ Copied!")])
                False -> html.div([], [])
              },
            ],
          ),
          html.div([attr.class("text-sm text-zinc-400 truncate flex-1")], [
            html.span([attr.class("text-zinc-600")], [html.text("→ ")]),
            html.text(url.target_url),
          ]),
          html.button(
            [
              attr.class(case url.is_active {
                True -> "inline-flex shrink-0 items-center rounded-full bg-green-600/20 px-2 py-1 text-xs font-medium text-green-400 ring-1 ring-inset ring-green-600/30 cursor-pointer hover:bg-green-600/30 transition-colors"
                False -> "inline-flex shrink-0 items-center rounded-full bg-red-600/20 px-2 py-1 text-xs font-medium text-red-400 ring-1 ring-inset ring-red-600/30 cursor-pointer hover:bg-red-600/30 transition-colors"
              }),
               mouse.on_mouse_down_no_right(cbs.toggle_active_clicked(url.id, url.is_active)),
              attr.title("Toggle active/inactive"),
            ],
            [html.text(case url.is_active { True -> "Active" False -> "Inactive" })],
          ),
        ]),
        html.div(
          [
            attr.class("flex items-center space-x-2 ml-4 cursor-pointer hover:text-zinc-300 transition-colors"),
             mouse.on_mouse_down_no_right(cbs.toggle_expanded(url.id)),
          ],
          [html.div([attr.class("text-zinc-500 text-sm")], [html.text("▲")])],
        ),
      ]),
      html.div([attr.class("px-4 pb-4")], [
        html.div([attr.class("mb-4 pt-2 border-t border-zinc-700")], [
          html.div([attr.class("text-sm text-zinc-500 mb-2")], [html.text("Target URL:")]),
          html.div(
            [
              attr.class(
                "text-zinc-300 break-all bg-zinc-900 rounded px-3 py-2 text-sm cursor-pointer hover:bg-zinc-850 transition-colors",
              ),
              attr.title(url.target_url <> " (click to collapse)"),
              mouse.on_mouse_down_no_right(cbs.toggle_expanded(url.id)),
            ],
            [html.text(url.target_url)],
          ),
        ]),
        html.div([attr.class("space-y-3 text-sm mb-4")], [
          meta_row("Created By:", url.created_by),
          meta_row("Access Count:", int.to_string(url.access_count)),
          meta_row("Created:", birl.from_unix_milli(url.created_at * 1000) |> birl.to_naive_date_string),
          meta_row("Updated:", birl.from_unix_milli(url.updated_at * 1000) |> birl.to_naive_date_string),
        ]),
        html.div([attr.class("space-y-2")], [
          ui.button(
            case copy_feedback == Some(url.short_code) { True -> "Copied!" False -> "Copy URL" },
            ui.ColorTeal,
            ui.ButtonStateNormal,
            cbs.copy_clicked(url.short_code),
          ),
          ui.button(
            case url.is_active { True -> "Deactivate" False -> "Activate" },
            case url.is_active { True -> ui.ColorOrange False -> ui.ColorTeal },
            ui.ButtonStateNormal,
            cbs.toggle_active_clicked(url.id, url.is_active),
          ),
          ui.button(
            "Delete",
            ui.ColorRed,
            ui.ButtonStateNormal,
            cbs.delete_clicked(url.id),
          ),
        ]),
      ]),
    ],
  )
}

fn delete_confirmation_modal(
  delete_id: String,
  short_urls: List(ShortUrl),
  cbs: Callbacks(msg),
) -> Element(msg) {
  let url_to_delete =
    case list.find(short_urls, fn(url) { url.id == delete_id }) {
      Ok(url) -> url.short_code
      Error(_) -> "unknown"
    }

  html.div([], [
    ui.modal_backdrop(cbs.delete_cancel_clicked()),
    ui.modal(
      "Delete Short URL",
      [html.p([attr.class("text-zinc-300")], [
        html.text("Are you sure you want to delete the short URL "),
        html.span([attr.class("font-mono text-pink-400")], [html.text("u.jst.dev/" <> url_to_delete)]),
        html.text("? This action cannot be undone."),
      ])],
      [
        ui.button("Cancel", ui.ColorTeal, ui.ButtonStateNormal, cbs.delete_cancel_clicked()),
        ui.button("Delete", ui.ColorRed, ui.ButtonStateNormal, cbs.delete_confirm_clicked(delete_id)),
      ],
      cbs.delete_cancel_clicked(),
    ),
  ])
}

fn meta_row(label: String, value: String) -> Element(msg) {
  html.div([attr.class("flex justify-between items-center")], [
    html.span([attr.class("text-zinc-500 shrink-0")], [html.text(label)]),
    html.span([attr.class("text-zinc-300 truncate ml-2")], [html.text(value)]),
  ])
}

fn http_error_to_string(error: HttpError) -> String {
  // Minimal wrapper to avoid pulling in error_string module here
  case error { _ -> "Error" }
}

