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
  Model(posts: Dict(Int, Post), route: Route)
}

type Post {
  Post(id: Int, title: String, subtitle: String, summary: String, text: String)
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

    // case int.parse(id_or_slug) {
    //   Ok(id) ->
    //     case dict.get(posts, id) {
    //       Ok(post) -> PostById(id: post.id)
    //       Error(_) -> NotFound(uri:)
    //     }
    //   Error(_) ->
    //     case dict.get(posts, id_or_slug) {
    //   Ok(post) -> PostById(id: post.id)
    //   Error(_) -> NotFound(uri:)
    // }
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

  let model = Model(route:, posts:)

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
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserNavigatedTo(route:) -> #(Model(..model, route:), effect.none())
  }
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
          About -> view_about()
          NotFound(_) -> view_not_found()
        }
      }),
    ],
  )
}

// VIEW HEADER ----------------------------------------------------------------
fn view_header(model: Model) -> Element(msg) {
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
          html.ul([attribute.class("flex space-x-8 pr-2")], [
            view_header_link(current: model.route, to: Posts, label: "Posts"),
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
    subtitle: "",
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
