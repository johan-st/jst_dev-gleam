import decipher
import gleam/dynamic
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import page/page.{type Page}
import page/url_shortener
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
  let page = case modem.initial_uri() {
    Ok(uri) -> page.from_uri(uri)
    Error(_) -> page.Loading
  }
  let user = user.Guest

  Model(page, user)
}

fn init(_) -> #(Model, Effect(Msg)) {
  let model = initial_model()
  let effect = modem.init(on_route_change)

  #(model, effect)
}

fn on_route_change(uri: Uri) -> Msg {
  let page = page.from_uri(uri)
  OnRouteChange(page)
}

type Msg {
  OnRouteChange(page.Page)
  PageLoaded(Result(User, String))
  UserClickedReload
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let _ = io.debug(msg)
  case msg {
    OnRouteChange(page) -> #(Model(..model, page: page), effect.none())
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
  let main_content = case model.page {
    page.Loading -> view_loading()
    page.Home -> view_home(model)
    page.Debug -> html.text(string.inspect(model))
    page.Error(error) -> view_error(error)
    page.UrlShortener(model) -> view_url_shortener(model)
  }
  html.div([], [
    html.header([], [
      html.nav([], [
        html.a([attribute.href("/")], [element.text("Go home")]),
        html.a([attribute.href("/dbg")], [element.text("Go to debug")]),
        html.a([attribute.href("/url")], [element.text("Go to url shortener")]),
      ]),
    ]),
    main_content,
    html.footer([], [html.text("Footer")]),
  ])
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
    user.Authenticated(user_info) ->
      html.div([], [html.text("Hello, " <> string.inspect(user_info))])
  }
}

fn view_error(error: String) -> Element(Msg) {
  let handle_click = fn(_event) { Ok(UserClickedReload) }

  html.div([], [
    html.div([], [html.text("error, " <> error)]),
    html.button([event.on("click", handle_click)], [html.text("Reload")]),
  ])
}

fn view_url_shortener(model: url_shortener.Model) -> Element(Msg) {
  html.div([], [
    html.text("Url shortener"),
    html.text("Model: " <> string.inspect(model)),
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
