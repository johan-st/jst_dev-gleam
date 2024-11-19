// import decipher
// import gleam/dynamic
// import gleam/int
// import gleam/list
// import gleam/result
// import gleam/string
// import gleam/uri.{type Uri}
import gleam/io
import lustre
import lustre/attribute.{href}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, div, footer, header, input, nav, text, form}

import lustre/event

// import modem
// import page/page.{type Page}
// import page/url_shortener
// import user/user.{type User}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model {
  Model(url_to_shorten: String, url_shortened: String, submitted: Bool)
}

fn init(_) -> #(Model, Effect(Msg)) {
  let model = Model(url_to_shorten: "", url_shortened: "", submitted: False)
  let effects = effect.none()
  #(model, effects)
}

type Msg {
  UserUpdatedLong(String)
  UserUpdatedShort(String)
  UserClickedSubmit
}

// fn(Dynamic) -> Result(Msg, List(DecodeError))

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case io.debug(msg) {
    UserUpdatedLong(url) -> {
      let model = Model(url, model.url_shortened, model.submitted)
      let effect = effect.none()
      #(model, effect)
    }

    UserUpdatedShort(url) -> {
      let model = Model(model.url_to_shorten, url, model.submitted)
      let effect = effect.none()
      #(model, effect)
    }

    UserClickedSubmit -> {
      let model = Model(model.url_to_shorten, model.url_shortened, True)
      let effect = effect.none()
      #(model, effect)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  let main_content = view_url_shortener(model)

  div([], [
    header([], [
      nav([], [
        a([href("/")], [text("Go home")]),
        a([href("/dbg")], [text("Go to debug")]),
        a([href("/url")], [text("Go to url shortener")]),
      ]),
    ]),
    main_content,
    footer([], [text("Footer")]),
  ])
}

fn view_url_shortener(model: Model) -> Element(Msg) {
  form([attribute.class("url_shortener__form")], [
    text("Url shortener"),
    view_input_text(
      "url_to_shorten",
      "Original",
      model.url_to_shorten,
      UserUpdatedLong,
    ),
    view_input_text(
      "url_shortened",
      "Short",
      model.url_shortened,
      UserUpdatedShort,
    ),
    input([
      event.on_submit(UserClickedSubmit),
      attribute.type_("submit"),
      attribute.value("Submit"),
    ]),
  ])
}

fn view_input_text(
  id: String,
  lable: String,
  value: String,
  msg: fn(String) -> Msg,
) -> Element(Msg) {
  element.fragment([
    html.label([attribute.for(id)], [html.text(lable)]),
    input([
      attribute.id(id),
      attribute.type_("text"),
      attribute.value(value),
      event.on_input(msg),
    ]),
  ])
}
// fn view_grocery_item(name: String, quantity: Int) -> Element(Msg) {
//   let handle_input = fn(e) {
//     event.value(e)
//     |> result.nil_error
//     |> result.then(int.parse)
//     |> result.map(UserUpdatedQuantity(name, _))
//     |> result.replace_error([])
//   }

//   html.div([attribute.style([#("display", "flex"), #("gap", "1em")])], [
//     html.span([attribute.style([#("flex", "1")])], [html.text(name)]),
//     html.input([
//       attribute.style([#("width", "4em")]),
//       attribute.type_("number"),
//       attribute.value(int.to_string(quantity)),
//       attribute.min("0"),
//       event.on("input", handle_input),
//     ]),
//   ])
// }
