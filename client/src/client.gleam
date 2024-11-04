import gleam/dynamic
import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/attribute
import decipher
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/event
import lustre/element/html

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model =
  List(#(String, Int))

fn init(_) -> #(Model, Effect(Msg)) {
  let model = []
  let effect = effect.none()

  #(model, effect)
}

type Msg {
  ServerSavedList(Result(Nil, String))
  UserAddedProduct(name: String)
  UserSavedList
  UserUpdatedQuantity(name: String, amount: Int)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ServerSavedList(_) -> todo
    UserAddedProduct(_) -> todo
    UserSavedList -> todo
    UserUpdatedQuantity(_, _) -> todo
  }
}

fn view(model: Model) -> Element(Msg) {
  let styles = [
    #("max-width", "30ch"),
    #("margin", "0 auto"),
    #("display", "flex"),
    #("flex-direction", "column"),
    #("gap", "1em"),
  ]

  html.div([attribute.style(styles)], [
    view_grocery_list(model),
    view_new_item(),
    html.div([], [html.button([], [html.text("Sync")])]),
  ])
}

fn view_new_item() -> Element(Msg) {
  let handle_click = fn(event) {
    let path = ["target", "previousElementSibling", "value"]

    event
    |> decipher.at(path, dynamic.string)
    |> result.map(UserAddedProduct)
  }

  html.div([], [
    html.input([]),
    html.button([event.on("click", handle_click)], [html.text("Add")]),
  ])
}

fn view_grocery_list(model: Model) -> Element(Msg) {
  let styles = [#("display", "flex"), #("flex-direction", "column-reverse")]

  element.keyed(html.div([attribute.style(styles)], _), {
    use #(name, quantity) <- list.map(model)
    let item = view_grocery_item(name, quantity)

    #(name, item)
  })
}

fn view_grocery_item(name: String, quantity: Int) -> Element(Msg) {
  let handle_input = fn(e) {
    event.value(e)
    |> result.nil_error
    |> result.then(int.parse)
    |> result.map(UserUpdatedQuantity(name, _))
    |> result.replace_error([])
  }

  html.div([attribute.style([#("display", "flex"), #("gap", "1em")])], [
    html.span([attribute.style([#("flex", "1")])], [html.text(name)]),
    html.input([
      attribute.style([#("width", "4em")]),
      attribute.type_("number"),
      attribute.value(int.to_string(quantity)),
      attribute.min("0"),
      event.on("input", handle_input),
    ]),
  ])
}
