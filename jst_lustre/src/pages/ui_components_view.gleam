import components/ui
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

pub type Msg {
  Panic
}

pub fn view() -> List(Element(Msg)) {
  [
    ui.page_header("UI Components", Some("Showcase of all available UI components")),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("loading-states", "Loading States", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Loading Indicators")]),
        html.div([attr.class("space-y-6")], [
          html.div([attr.class("grid grid-cols-2 md:grid-cols-3 gap-4")], [
            ui.loading("Loading...", ui.ColorNeutral),
            ui.loading("Loading...", ui.ColorPink),
            ui.loading("Loading...", ui.ColorTeal),
            ui.loading("Loading...", ui.ColorOrange),
            ui.loading("Loading...", ui.ColorRed),
            ui.loading("Loading...", ui.ColorGreen),
          ]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Loading Bars")]),
        html.div([attr.class("space-y-4")], [
          ui.loading_bar(ui.ColorNeutral),
          ui.loading_bar(ui.ColorPink),
          ui.loading_bar(ui.ColorTeal),
          ui.loading_bar(ui.ColorOrange),
          ui.loading_bar(ui.ColorRed),
          ui.loading_bar(ui.ColorGreen),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Full Loading States")]),
        html.div([attr.class("space-y-6")], [
          ui.loading_state("Loading content...", Some("Please wait while we fetch your data"), ui.ColorTeal),
          ui.loading_state("Processing...", Some("This may take a few moments"), ui.ColorOrange),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("buttons", "Buttons", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Button Variants")]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-zinc-400 mb-3")], [html.text("Neutral")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorNeutral, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorNeutral, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorNeutral, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-pink-400 mb-3")], [html.text("Pink")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorPink, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorPink, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorPink, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-teal-400 mb-3")], [html.text("Teal")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorTeal, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorTeal, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorTeal, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-orange-400 mb-3")], [html.text("Orange")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorOrange, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorOrange, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorOrange, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-red-400 mb-3")], [html.text("Red")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorRed, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorRed, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorRed, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.div([attr.class("mb-6")], [
          html.h4([attr.class("text-md font-medium text-green-400 mb-3")], [html.text("Green")]),
          html.div([attr.class("flex flex-wrap gap-3")], [
            ui.button("Normal", ui.ColorGreen, ui.ButtonStateNormal, Panic),
            ui.button("Pending", ui.ColorGreen, ui.ButtonStatePending, Panic),
            ui.button("Disabled", ui.ColorGreen, ui.ButtonStateDisabled, Panic),
          ]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Menu Buttons")]),
        html.div([attr.class("max-w-sm")], list.map([
          #(ui.ColorNeutral, ui.ButtonStateNormal, "Neutral Menu (Normal)"),
          #(ui.ColorNeutral, ui.ButtonStatePending, "Neutral Menu (Pending)"),
          #(ui.ColorNeutral, ui.ButtonStateDisabled, "Neutral Menu (Disabled)"),
          #(ui.ColorPink, ui.ButtonStateNormal, "Pink Menu (Normal)"),
          #(ui.ColorPink, ui.ButtonStatePending, "Pink Menu (Pending)"),
          #(ui.ColorPink, ui.ButtonStateDisabled, "Pink Menu (Disabled)"),
          #(ui.ColorTeal, ui.ButtonStateNormal, "Teal Menu (Normal)"),
          #(ui.ColorTeal, ui.ButtonStatePending, "Teal Menu (Pending)"),
          #(ui.ColorTeal, ui.ButtonStateDisabled, "Teal Menu (Disabled)"),
          #(ui.ColorOrange, ui.ButtonStateNormal, "Orange Menu (Normal)"),
          #(ui.ColorOrange, ui.ButtonStatePending, "Orange Menu (Pending)"),
          #(ui.ColorOrange, ui.ButtonStateDisabled, "Orange Menu (Disabled)"),
          #(ui.ColorRed, ui.ButtonStateNormal, "Red Menu (Normal)"),
          #(ui.ColorRed, ui.ButtonStatePending, "Red Menu (Pending)"),
          #(ui.ColorRed, ui.ButtonStateDisabled, "Red Menu (Disabled)"),
          #(ui.ColorGreen, ui.ButtonStateNormal, "Green Menu (Normal)"),
          #(ui.ColorGreen, ui.ButtonStatePending, "Green Menu (Pending)"),
          #(ui.ColorGreen, ui.ButtonStateDisabled, "Green Menu (Disabled)"),
        ], fn(btn_var) { let #(color, state, text) = btn_var ui.button_menu(text, color, state, Panic) })),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("form-components", "Form Components", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Input Fields")]),
        html.div([attr.class("max-w-md space-y-6")], [
          ui.form_input("Email", "user@example.com", "Enter your email", "email", True, None, fn(_) { Panic }),
          ui.form_input("Error State", "", "This field has an error", "text", True, Some("This field is required"), fn(_) { Panic }),
          ui.form_textarea("Description", "Sample content", "Enter description", "h-32", False, None, fn(_) { Panic }),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("status-feedback", "Status & Feedback", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Status Badges")]),
        html.div([attr.class("flex flex-wrap gap-4 mb-8")], [
          ui.status_badge("Neutral", ui.ColorNeutral),
          ui.status_badge("Active", ui.ColorGreen),
          ui.status_badge("Pending", ui.ColorOrange),
          ui.status_badge("Error", ui.ColorRed),
          ui.status_badge("Info", ui.ColorTeal),
          ui.status_badge("Primary", ui.ColorPink),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Notices")]),
        html.div([attr.class("space-y-4")], [
          ui.notice("Neutral message", ui.ColorNeutral, True, Some(Panic)),
          ui.notice("Success message", ui.ColorGreen, True, Some(Panic)),
          ui.notice("Warning message", ui.ColorOrange, True, Some(Panic)),
          ui.notice("Error message", ui.ColorRed, True, Some(Panic)),
          ui.notice("Info message", ui.ColorTeal, True, Some(Panic)),
          ui.notice("Primary message", ui.ColorPink, False, None),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("error-states", "Error States", [
        html.div([attr.class("space-y-8")], [
          ui.error_state(ui.ErrorNetwork, "Network Error", "Failed to connect to server", None),
          ui.error_state(ui.ErrorNotFound, "Not Found", "The requested resource was not found", None),
          ui.error_state(ui.ErrorPermission, "Access Denied", "You don't have permission to access this resource", None),
          ui.error_state(ui.ErrorGeneric, "Something Went Wrong", "An unexpected error occurred", None),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("modals", "Modals", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Modal Example")]),
        html.div([attr.class("space-y-4")], [
          ui.button("Open Modal", ui.ColorTeal, ui.ButtonStateNormal, Panic),
          html.p([attr.class("text-zinc-400 text-sm")], [html.text("Click the button above to see a modal in action.")]),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("layout-components", "Layout Components", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Cards")]),
        html.div([attr.class("space-y-0")], [
          ui.card_with_title("card-with-title", "Card with Title", [html.p([attr.class("text-zinc-300")], [html.text("This is a card with a title section.")])]),
          ui.glass_panel([html.h4([attr.class("text-lg font-medium text-zinc-100 mb-2")], [html.text("Glass Panel")]), html.p([attr.class("text-zinc-300")], [html.text("This panel has a glass-like effect.")])]),
        ]),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Empty States")]),
        ui.empty_state("No Items Found", "There are no items to display at the moment.", Some(ui.button("Create New", ui.ColorTeal, ui.ButtonStateNormal, Panic))),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("skeleton-loaders", "Skeleton Loaders", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Loading Placeholders")]),
        html.div([attr.class("space-y-6")], [
          html.div([], [html.h4([attr.class("text-md font-medium text-zinc-200 mb-4")], [html.text("Text Skeleton")]), ui.skeleton_text(3)]),
          html.div([], [html.h4([attr.class("text-md font-medium text-zinc-200 mb-4")], [html.text("Card Skeleton")]), ui.skeleton_card()]),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("page-headers", "Page Headers", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Page Header with Subtitle")]),
        ui.page_header("Example Page Title", Some("This is a subtitle that provides additional context")),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Page Title Only")]),
        ui.page_title("Simple Page Title"),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("typography-links", "Typography & Links", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Text Styles")]),
        html.div([attr.class("space-y-4")], [
          html.p([attr.class("text-zinc-300")], [html.text("Regular text with "), ui.link_primary("primary link", Panic), html.text(" embedded.")]),
        ]),
      ]),
    ]),
    html.section([attr.class("space-y-6")], [
      ui.card_with_title("layout-helpers", "Layout Helpers", [
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4")], [html.text("Flex Between Layout")]),
        ui.flex_between(html.span([attr.class("text-zinc-300")], [html.text("Left content")]), html.span([attr.class("text-zinc-300")], [html.text("Right content")])),
        html.h3([attr.class("text-lg font-medium text-zinc-100 mb-4 mt-8")], [html.text("Content Container")]),
        ui.content_container([html.p([attr.class("text-zinc-300")], [html.text("This content is wrapped in a container with consistent spacing.")]), html.p([attr.class("text-zinc-300")], [html.text("Multiple elements get proper spacing between them.")])]),
      ]),
    ]),
  ]
}

