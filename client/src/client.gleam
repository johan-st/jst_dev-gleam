import decipher
import gleam/dynamic
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import page/page.{type Page}
import user/user.{type User}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model {
  Model(page: Page, user: User)
}

fn initial_model() -> Model {
  Model(page.Loading, user.Guest)
}

fn init(_) -> #(Model, Effect(Msg)) {
  let model = initial_model()
  let effect = effect.none()

  #(model, effect)
}

type Msg {
  PageLoaded(Result(User, String))
  UserClickedReload
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let _ = io.debug(msg)
  case msg {
    UserClickedReload -> {
      let model = Model(page.Loading, model.user)
      let effect = effect.none()

      #(model, effect)
    }
    PageLoaded(Ok(user)) -> {
      let model = Model(page.Home, user)
      let effect = effect.none()

      #(model, effect)
    }
    PageLoaded(Error(error)) -> {
      let model = Model(page.Error(error), model.user)
      let effect = effect.none()

      #(model, effect)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.page {
    page.Loading -> view_loading()
    page.Home -> view_home(model)
    page.Error(error) -> view_error(error)
  }
}

fn view_loading() -> Element(Msg) {
  let handle_click_ok = fn(_event) { Ok(PageLoaded(Ok(user.Guest))) }
  let handle_click_err = fn(_event) {
    Ok(PageLoaded(Error("you chose violence")))
  }

  html.div([], [
    html.text("Loading..."),
    html.button([event.on("click", handle_click_err)], [html.text("error")]),
    html.button([event.on("click", handle_click_ok)], [
      html.text("ok, with guest"),
    ]),
  ])
}

fn view_home(model: Model) -> Element(Msg) {
  let handle_click = fn(_event) { Ok(UserClickedReload) }

  html.div([], [
    view_user(model.user),
    html.button([event.on("click", handle_click)], [html.text("Reload")]),
  ])
}

fn view_user(user: User) -> Element(Msg) {
  case user {
    user.Guest -> html.div([], [html.text("Hello, guest!")])
  }
}

fn view_error(error: String) -> Element(Msg) {
  let handle_click = fn(_event) { Ok(UserClickedReload) }

  html.div([], [
    html.div([], [html.text("error, " <> error)]),
    html.button([event.on("click", handle_click)], [html.text("Reload")]),
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
