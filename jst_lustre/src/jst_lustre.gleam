// IMPORTS ---------------------------------------------------------------------

import gleam/dict.{type Dict}
import gleam/function
import gleam/int
import gleam/list
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// Modem is a package providing effects and functionality for routing in SPAs.
// This means instead of links taking you to a new page and reloading everything,
// they are intercepted and your `update` function gets told about the new URL.
import modem

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    posts: Dict(Int, Post),
    posts_md: Dict(Int, PostMarkdown),
    route: Route,
    websocket_status: String,
  )
}

type Post {
  Post(id: Int, title: String, subtitle: String, summary: String, text: String)
}

type PostMarkdown {
  PostMarkdown(id: Int, title: String, summary: String, content: String)
}

/// In a real application, we'll likely want to show different views depending on
/// which URL we are on:
///
/// - /      - show the home page
/// - /posts - show a list of posts
/// - /about - show an about page
/// - ...
///
/// We could store the `Uri` or perhaps the path as a `String` in our model, but
/// this can be awkward to work with and error prone as our application grows.
///
/// Instead, we _parse_ the URL into a nice Gleam custom type with just the
/// variants we need! This lets us benefit from Gleam's pattern matching,
/// exhaustiveness checks, and LSP features, while also serving as documentation
/// for our app: if you can get to a page, it must be in this type!
///
type Route {
  Index
  Posts
  PostById(id: Int)
  Markdown
  MarkdownById(id: Int)
  About
  /// It's good practice to store whatever `Uri` we failed to match in case we
  /// want to log it or hint to the user that maybe they made a typo.
  NotFound(uri: Uri)
}

fn parse_route(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Index

    ["posts"] -> Posts

    ["post", post_id] ->
      case int.parse(post_id) {
        Ok(post_id) -> PostById(id: post_id)
        Error(_) -> NotFound(uri:)
      }

    ["md"] -> Markdown

    ["md", post_id] ->
      case int.parse(post_id) {
        Ok(post_id) -> MarkdownById(id: post_id)
        Error(_) -> NotFound(uri:)
      }

    ["about"] -> About
    _ -> NotFound(uri:)
  }
}

/// We also need a way to turn a Route back into a an `href` attribute that we
/// can then use on `html.a` elements. It is important to keep this function in
/// sync with the parsing, but once you do, all links are guaranteed to work!
///
fn href(route: Route) -> Attribute(msg) {
  let url = case route {
    Index -> "/"
    About -> "/about"
    Posts -> "/posts"
    PostById(post_id) -> "/post/" <> int.to_string(post_id)
    Markdown -> "/md"
    MarkdownById(post_id) -> "/md/" <> int.to_string(post_id)
    NotFound(_) -> "/404"
  }

  attribute.href(url)
}

fn init(_) -> #(Model, Effect(Msg)) {
  // The server for a typical SPA will often serve the application to *any*
  // HTTP request, and let the app itself determine what to show. Modem stores
  // the first URL so we can parse it for the app's initial route.
  let route = case modem.initial_uri() {
    Ok(uri) -> parse_route(uri)
    Error(_) -> Index
  }

  let posts =
    posts
    |> list.map(fn(post) { #(post.id, post) })
    |> dict.from_list

  let posts_md =
    posts_md
    |> list.map(fn(post) { #(post.id, post) })
    |> dict.from_list

  let model =
    Model(route:, posts:, posts_md:, websocket_status: "not connected")

  let effect =
    // We need to initialise modem in order for it to intercept links. To do that
    // we pass in a function that takes the `Uri` of the link that was clicked and
    // turns it into a `Msg`.
    modem.init(fn(uri) {
      uri
      |> parse_route
      |> UserNavigatedTo
    })

  #(model, effect)
}

// UPDATE ----------------------------------------------------------------------

type Msg {
  UserNavigatedTo(route: Route)
  InjectMarkdownResult(result: Result(Nil, Nil))
  ClickedConnectButton
  WebsocketConnetionResult(result: Result(Nil, Nil))
  WebsocketOnMessage(data: String)
  WebsocketOnClose(data: String)
  WebsocketOnError(data: String)
  WebsocketOnOpen(data: String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserNavigatedTo(route:) -> {
      let effect = case route {
        MarkdownById(id) -> {
          let posts_md = dict.get(model.posts_md, id)
          case posts_md {
            Error(_) -> effect.none()
            Ok(post) -> effect_inject_markdown("markdown-content", post.content)
          }
        }
        _ -> effect.none()
      }
      #(Model(..model, route:), effect)
    }
    InjectMarkdownResult(_) -> {
      #(model, effect.none())
    }
    ClickedConnectButton -> {
      #(
        Model(..model, websocket_status: "connecting..."),
        effect_setup_websocket(),
      )
    }
    WebsocketConnetionResult(result:) -> {
      case result {
        Ok(_) -> {
          #(Model(..model, websocket_status: "connected"), effect.none())
        }
        Error(_) -> {
          #(
            Model(..model, websocket_status: "failed to connect"),
            effect.none(),
          )
        }
      }
    }
    WebsocketOnMessage(data:) -> {
      #(Model(..model, websocket_status: "data: " <> data), effect.none())
    }
    WebsocketOnClose(data:) -> {
      #(Model(..model, websocket_status: "closed: " <> data), effect.none())
    }
    WebsocketOnError(data:) -> {
      #(Model(..model, websocket_status: "error: " <> data), effect.none())
    }
    WebsocketOnOpen(data:) -> {
      #(Model(..model, websocket_status: "open: " <> data), effect.none())
    }
  }
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./app.ffi.mjs", "inject_markdown")
fn inject_markdown(_element_id: String, _markdown: String) -> Result(Nil, Nil) {
  Error(Nil)
}

fn effect_inject_markdown(element_id: String, markdown: String) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(InjectMarkdownResult(inject_markdown(element_id, markdown)))
}

@external(javascript, "./app.ffi.mjs", "setup_websocket")
fn setup_websocket(
  _path: String,
  _on_open: fn(String) -> Nil,
  _on_message: fn(String) -> Nil,
  _on_close: fn(String) -> Nil,
  _on_error: fn(String) -> Nil,
) -> Result(Nil, Nil) {
  Error(Nil)
}

fn effect_setup_websocket() -> Effect(Msg) {
  use dispatch <- effect.from
  let on_open = fn(data: String) { dispatch(WebsocketOnOpen(data)) }
  let on_message = fn(data: String) { dispatch(WebsocketOnMessage(data)) }
  let on_close = fn(data: String) { dispatch(WebsocketOnClose(data)) }
  let on_error = fn(data: String) { dispatch(WebsocketOnError(data)) }
  dispatch(
    WebsocketConnetionResult(setup_websocket(
      "ws://localhost:8080/ws",
      on_open,
      on_message,
      on_close,
      on_error,
    )),
  )
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.class("text-zinc-400 h-full w-full text-lg font-thin mx-auto")],
    [
      view_header(model),
      html.main([attribute.class("px-10 py-4 max-w-screen-md mx-auto")], {
        // Just like we would show different HTML based on some other state in the
        // model, we can also pattern match on our Route value to show different
        // views based on the current page!
        case model.route {
          Index -> view_index()
          Posts -> view_posts(model)
          PostById(id) -> view_post(model, id)
          Markdown -> view_markdowns(model)
          MarkdownById(id) -> view_markdown(model, id)
          About -> view_about()
          NotFound(_) -> view_not_found()
        }
      }),
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(Msg) {
  html.nav(
    [attribute.class("py-2 border-b bg-zinc-800 border-pink-700 font-mono ")],
    [
      html.div(
        [
          attribute.class(
            "flex justify-between px-10 items-center max-w-screen-md mx-auto",
          ),
        ],
        [
          html.div([], [
            html.a([attribute.class("font-light"), href(Index)], [
              html.text("jst.dev"),
            ]),
          ]),
          html.div([], [html.text(model.websocket_status)]),
          html.ul([attribute.class("flex space-x-8 pr-2")], [
            html.button(
              [
                attribute.class("font-light"),
                event.on_click(ClickedConnectButton),
              ],
              [html.text("Connect")],
            ),
            view_header_link(current: model.route, to: Posts, label: "Posts"),
            view_header_link(
              current: model.route,
              to: Markdown,
              label: "Markdown",
            ),
            view_header_link(current: model.route, to: About, label: "About"),
          ]),
        ],
      ),
    ],
  )
}

fn view_header_link(
  to target: Route,
  current current: Route,
  label text: String,
) -> Element(msg) {
  let is_active = case current, target {
    PostById(_), Posts -> True
    _, _ -> current == target
  }

  html.li(
    [
      attribute.classes([
        #("border-transparent border-b-2 hover:border-pink-700", True),
        #("text-pink-700", is_active),
      ]),
    ],
    [html.a([href(target)], [html.text(text)])],
  )
}

// VIEW PAGES ------------------------------------------------------------------

fn view_index() -> List(Element(msg)) {
  [
    title("Welcome to jst.dev!"),
    subtitle(
      "...or, A lession on overengineering for fun and.. 
      well just for fun.",
    ),
    leading(
      "This site and it's underlying IT-infrastructure is the primary 
      place for me to experiment with technologies and topologies. I 
      also share some of my thoughts and learnings here.",
    ),
    html.p([attribute.class("mt-14")], [
      html.text(
        "This site and it's underlying IT-infrastructure is the primary 
        place for me to experiment with technologies and topologies. I 
        also share some of my thoughts and learnings here. Feel free to 
        check out my overview, ",
      ),
      link(Posts, "NATS all the way down ->"),
    ]),
    paragraph(
      "It to is a work in progress and I mostly keep it here for my own reference.",
    ),
    paragraph(
      "I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband. I'm also a software developer and a writer.",
    ),
  ]
}

fn view_posts(model: Model) -> List(Element(msg)) {
  let posts =
    model.posts
    |> dict.values
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.map(fn(post) {
      html.article([attribute.class("mt-14")], [
        html.h3([attribute.class("text-xl text-pink-700 font-light")], [
          html.a([attribute.class("hover:underline"), href(PostById(post.id))], [
            html.text(post.title),
          ]),
        ]),
        html.p([attribute.class("mt-1")], [html.text(post.summary)]),
      ])
    })

  [title("Posts"), ..posts]
}

fn view_post(model: Model, post_id: Int) -> List(Element(msg)) {
  case dict.get(model.posts, post_id) {
    Error(_) -> view_not_found()
    Ok(post) -> [
      html.article([], [
        title(post.title),
        leading(post.summary),
        paragraph(post.text),
      ]),
      html.p([attribute.class("mt-14")], [link(Posts, "<- Go back?")]),
    ]
  }
}

fn view_markdowns(model: Model) -> List(Element(msg)) {
  let posts_md =
    model.posts_md
    |> dict.values
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
    |> list.map(fn(post_md) {
      html.article([attribute.class("mt-14")], [
        html.h3([attribute.class("text-xl text-pink-700 font-light")], [
          html.a(
            [attribute.class("hover:underline"), href(MarkdownById(post_md.id))],
            [html.text(post_md.title)],
          ),
        ]),
        html.p([attribute.class("mt-1")], [html.text(post_md.summary)]),
      ])
    })

  [title("Markdown"), ..posts_md]
}

fn view_markdown(model: Model, post_id: Int) -> List(Element(msg)) {
  case dict.get(model.posts_md, post_id) {
    Error(_) -> view_not_found()
    Ok(post) -> [
      html.article([attribute.id("markdown-content")], [html.text("rendering...")]),
      html.p([attribute.class("mt-14")], [link(Posts, "<- Go back?")]),
    ]
  }
}

fn view_about() -> List(Element(msg)) {
  [
    title("About"),
    paragraph(
      "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
    ),
    paragraph(
      "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
    ),
  ]
}

fn view_not_found() -> List(Element(msg)) {
  [
    title("Not found"),
    paragraph(
      "You glimpse into the void and see -- nothing?
       Well that was somewhat expected.",
    ),
  ]
}

// VIEW HELPERS ----------------------------------------------------------------

fn title(title: String) -> Element(msg) {
  html.h1([attribute.class("text-3xl pt-8 text-pink-700 font-light")], [
    html.text(title),
  ])
}

fn subtitle(title: String) -> Element(msg) {
  html.h2([attribute.class("text-md text-zinc-600 font-light")], [
    html.text(title),
  ])
}

fn leading(text: String) -> Element(msg) {
  html.p([attribute.class("font-bold pt-12")], [html.text(text)])
}

fn paragraph(text: String) -> Element(msg) {
  html.p([attribute.class("pt-8")], [html.text(text)])
}

/// In other frameworks you might see special `<Link />` components that are
/// used to handle navigation logic. Using modem, we can just use normal HTML
/// `<a>` elements and pass in the `href` attribute. This means we have the option
/// of rendering our app as static HTML in the future!
///
fn link(target: Route, title: String) -> Element(msg) {
  html.a(
    [
      href(target),
      attribute.class("text-pink-700 hover:underline cursor-pointer"),
    ],
    [html.text(title)],
  )
}

// DATA ------------------------------------------------------------------------

const posts: List(Post) = [
  Post(
    id: 1,
    title: "The Empty Chair",
    subtitle: "A guide to uninvited furniture and its temporal implications",
    summary: "A guide to uninvited furniture and its temporal implications",
    text: "
      There's an empty chair in my home that wasn't there yesterday. When I sit
      in it, I start to remember things that haven't happened yet. The chair is
      getting closer to my bedroom each night, though I never caught it move.
      Last night, I dreamt it was watching me sleep. This morning, it offered
      me coffee.
    ",
  ),
  Post(
    id: 2,
    title: "The Library of Unwritten Books",
    subtitle: "Warning: Reading this may shorten your narrative arc",
    summary: "Warning: Reading this may shorten your narrative arc",
    text: "
      Between the shelves in the public library exists a thin space where
      books that were never written somehow exist. Their pages change when you
      blink. Forms shifting to match the souls blueprint. Librarians warn
      against reading the final chapter of any unwritten book – those who do
      find their own stories mysteriously concluding. Yourself is just another
      draft to be rewritten.
    ",
  ),
  Post(
    id: 3,
    title: "The Hum",
    subtitle: "or, A frequency analysis of the collective forgetting",
    summary: "A frequency analysis of the collective forgetting",
    text: "
      The citywide hum started Tuesday. Not everyone can hear it, but those who
      can't are slowly being replaced by perfect copies who smile too widely.
      The hum isn't sound – it's the universe forgetting our coordinates.
      Reports suggest humming back in harmony might postpone whatever comes
      next. Or perhaps accelerate it.
    ",
  ),
]

const posts_md: List(PostMarkdown) = [
  PostMarkdown(
    id: 1,
    title: "MVU is event driven architecture",
    summary: "Musings on shoehorning the MVU loop into a service",
    content: "
    ## MVU -> Model View Update

    I learned of this pattern through Elm which is why The Elm Architecture (TEA) is synonymous with MVU to me. The fact that Elm is a pure functional language gives us Super powers. The fact that the state at any given time is a function of the initial state and the events up to that point enables replays, forking timelines, point-in-time snapshots and excellent visibility. All powered by events. For actions outside of our pure functional world, such as requests, we rely on the runtime for managed effects ( the`Cmd` that is paired with the model ) 

    It is based on a simple idea, the **model** or state (`Model`) is a function of the initial `Model` and the `Msg`s (events). Messages are handled by the **update** function  (`update -> Model -> Msg -> (Model, Cmd)`). **View** (the ui, the markup in the web world) is based purely on the current `Model`.

    For example we could have a form with a single text input. The `Model` for it would be a single string (i.e. `Model String`). A change to the input would be emit a message to the update function  (e.g. `InputChanged String`).  Now the update function would take in the current model (`\"Jo\"`) and the update (`InputChanged \"Joh\"`). The update function will return a new model (`\"Joh\"`). The view function would render this something like this..
    ```html
    <form>
      <input type=\"text\" value=\"Joh\">
    </form>
    ```

    If we want to be able also submit the types would be something like
    ```elm
    type alias Model {
      value String
      submitStatus SubmitStatus
    } 

    type SubmitStatus {
      NotSubmitted
      Pending
      SubmitFailed HttpError
      SubmitValidation InputValidation
      SubmitOk
    }

    type alias InputValidation {
        fieldId String
        value String 
        validationError Maybe String
    }

    type Msg {
      InputChanged String
      Submit
      SubmitResult (List InputValidation, Maybe HttpError)
    }

    initialModel -> (Model, Cmd)

    update -> Model -> Msg -> (Model, Cmd)

    view -> Model -> Html
    ```

    ## isn't this complicated? 

    I would argue, no. For Elm, the code needed to facilitate the architecture is less that 30KB in payload. It is not nothing.. but also not a lot for any moderately complex website. 

    There is wisdom in striving for solutions that make the difficult problems easier. The easier problems are not where we get stuck or create bugs that are hard to find and fix. 

    ### isolated complexity
    A pure functional MVU isolates updates to one event at a time. The mental overhead, when everything that can affect the outcome is clearly defined in the scope of the update function, is usually very manageable. In other applications I find myself guessing and trying, hoping I didn't miss anything way too often. 

    ### knowning the world 
    Something that took me some time to put my finger on is the benefits of narrowing the scope of all possible states. When we have a Model crafted specifically for our purposes we can also limit all possible states to only valid ones. (Richard Feldman has an excellent lecture on \"*making impossible states impossible*\" **check quote**.)

    When what we return from the update function is a the state we want the app to be in any effect we want the runtime to handle for us. Responses from the runtime are simply `Msg`'s for our update function. 

    ## What does this all have to do with event driven architecture? 
    Well, if we squint on the MVU loop it looks very much like a service reading an event stream and posting messages back. It maintains a local state based on the messages it has received.

    What would a e-commerce site look like in this paradigm? 

    I honestly do not know but it had been something I've been thinking of for quite some time now.. 

    Let's sketch some types..

    ```elm

    type alias Model {
      stock List Product
      blog List Article
      users List User
      admins List Admin
      categories  List Category
      sessions List UserSession
      orders List Order
      ... etc.
    }

    type Msg {
      {- Session -}
      SessionNew
      SessionVisitPage Session Url
      SessionLogin Session User
      SessionAddToCart Session Product Int
      ...
      {- Order -}
      OrderNew Session
      OrderSetAddressBilling Order Address 
      OrderSetAddressDelivery Order 
      OrderPay Order Payment
      OrderValidate Orde
      ...
      {- ADMIN -}
      AdminLogin Session 
      AdminLoginResult Maybe Admin
      {- Product -}
      ProductNew Admin Product
      ProductUpdate Admin Product
      ...
    }```

    > note that Admin messages need an Admin attached to them. Type check fails otherwise.

    ### ​Wow! That's a loooong type definition! 

    But the these types have more than 100 subtypes! 

    Yes, is that an issue?

    We could have something like ￼￼MsgStock Stock.Model Stock.Msg￼￼ that we map to ￼￼Stock.update￼￼ which returns a new Stock.Model. We can even use an opaque type to isolate the Stock module and control the API we expose. Maybe if we have many teams working in parallel.

    This might be what we want but then again.. as we don't need to load a lot of state into our heades to follow the update function, it's usually just as easy to list all the state and state changes. Maybe use comments to organise it. 

    #### ​Stock Service
    ```elm
    module Stock

    ​type alias Model {
      stock List StockItem 
      reservations List Reservation
      inbound List StockItem
    }

    type alias StockItem {
      uuid Uuid
      manufacturerRef String
      count Int
      desc String
      ...
    }

    type alias Reservation {
      cartId Int
      list ( ItemId, Int )
      timeCreated Time
      timeExpires Maybe Time
      priority Prio
    }

    type Prio {
      Low
      Standard
      High
      Critical 
    }
```
    ",
  ),
  PostMarkdown(
    id: 2,
    title: "MVU is event driven architecture",
    summary: "Musings on shoehorning the MVU loop into a service",
    content: "
    ## MVU -> Model View Update

    I learned of this pattern through Elm which is why The Elm Architecture (TEA) is synonymous with MVU to me. The fact that Elm is a pure functional language gives us Super powers. The fact that the state at any given time is a function of the initial state and the events up to that point enables replays, forking timelines, point-in-time snapshots and excellent visibility. All powered by events. For actions outside of our pure functional world, such as requests, we rely on the runtime for managed effects ( the \\`Cmd\\` that is paired with the model )     ",
  ),
]
// COMPONENTS ------------------------------------------------------------------

// Header
// <header class="bg-gray-900">
//   <nav class="mx-auto flex max-w-7xl items-center justify-between p-6 lg:px-8" aria-label="Global">
//     <div class="flex lg:flex-1">
//       <a href="#" class="-m-1.5 p-1.5">
//         <span class="sr-only">Your Company</span>
//         <img class="h-8 w-auto" src="https://tailwindcss.com/plus-assets/img/logos/mark.svg?color=indigo&shade=500" alt="">
//       </a>
//     </div>
//     <div class="flex lg:hidden">
//       <button type="button" class="-m-2.5 inline-flex items-center justify-center rounded-md p-2.5 text-gray-400">
//         <span class="sr-only">Open main menu</span>
//         <svg class="size-6" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
//           <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5" />
//         </svg>
//       </button>
//     </div>
//     <div class="hidden lg:flex lg:gap-x-12">
//       <a href="#" class="text-sm/6 font-semibold text-white">Product</a>
//       <a href="#" class="text-sm/6 font-semibold text-white">Features</a>
//       <a href="#" class="text-sm/6 font-semibold text-white">Marketplace</a>
//       <a href="#" class="text-sm/6 font-semibold text-white">Company</a>
//     </div>
//     <div class="hidden lg:flex lg:flex-1 lg:justify-end">
//       <a href="#" class="text-sm/6 font-semibold text-white">Log in <span aria-hidden="true">&rarr;</span></a>
//     </div>
//   </nav>
//   <!-- Mobile menu, show/hide based on menu open state. -->
//   <div class="lg:hidden" role="dialog" aria-modal="true">
//     <!-- Background backdrop, show/hide based on slide-over state. -->
//     <div class="fixed inset-0 z-10"></div>
//     <div class="fixed inset-y-0 right-0 z-10 w-full overflow-y-auto bg-gray-900 px-6 py-6 sm:max-w-sm sm:ring-1 sm:ring-white/10">
//       <div class="flex items-center justify-between">
//         <a href="#" class="-m-1.5 p-1.5">
//           <span class="sr-only">Your Company</span>
//           <img class="h-8 w-auto" src="https://tailwindcss.com/plus-assets/img/logos/mark.svg?color=indigo&shade=500" alt="">
//         </a>
//         <button type="button" class="-m-2.5 rounded-md p-2.5 text-gray-400">
//           <span class="sr-only">Close menu</span>
//           <svg class="size-6" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
//             <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
//           </svg>
//         </button>
//       </div>
//       <div class="mt-6 flow-root">
//         <div class="-my-6 divide-y divide-gray-500/25">
//           <div class="space-y-2 py-6">
//             <a href="#" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-white hover:bg-gray-800">Product</a>
//             <a href="#" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-white hover:bg-gray-800">Features</a>
//             <a href="#" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-white hover:bg-gray-800">Marketplace</a>
//             <a href="#" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-white hover:bg-gray-800">Company</a>
//           </div>
//           <div class="py-6">
//             <a href="#" class="-mx-3 block rounded-lg px-3 py-2.5 text-base/7 font-semibold text-white hover:bg-gray-800">Log in</a>
//           </div>
//         </div>
//       </div>
//     </div>
//   </div>
// </header>
