## TEA (Elm Architecture) for jst_lustre

This document proposes a TEA-first structure for jst_lustre. It organizes the app into a small shell and page modules that each own their Model/Msg/init/update/view, with services handling IO.

### Goals
- **Cohesion**: Each page encapsulates its state and logic.
- **Predictability**: One place to route, one place to persist, clear message flow.
- **Testability**: Pure `update` and `view` per page; services are isolated.

### Directory structure (proposed)
```text
src/
  app/
    main.gleam            # entrypoint, start Lustre app
    shell.gleam           # ShellModel, ShellMsg, init, update, view; child wiring
    router.gleam          # Route type + parse/format
    subscriptions.gleam   # global subscriptions (keyboard, window, history)

  pages/
    index/page.gleam              # Model/Msg/init/update/view
    article_list/page.gleam       # "Articles" landing
    article/page.gleam            # Article viewer
    article_edit/page.gleam       # Article editor
    url_short_index/page.gleam    # URL shortener index
    url_short_info/page.gleam     # URL info/details
    notifications/page.gleam      # Notifications list
    profile/page.gleam            # Profile page
    about/page.gleam              # Static page
    not_found/page.gleam          # 404

  features/
    article/
      types.gleam         # Article, Draft, decoders/encoders
      service.gleam       # HTTP effects: get_metadata, get, save, publish, delete
    short_url/
      types.gleam
      service.gleam       # Effects for short URLs
    auth/
      session.gleam       # Session types + service (login/logout/me)

  shared/
    remote_data.gleam     # RemoteData type
    persist.gleam         # LocalStorage helpers, encode/decode PersistentModel
    http.gleam            # Thin HTTP helpers
    ui.gleam              # Reusable UI components
    window_events.gleam   # Window focus/resize/visibility abstractions
    keyboard.gleam        # Key handling utilities
    icon.gleam            # Icon helpers
    dom_utils.gleam       # Small DOM-related helpers
```

### App shell
- **Owns**: global chrome, current `Route`, active child page model, session, and persistence wiring.
- **Does not own**: page-specific state machines (leave to page modules), or feature IO (leave to services).

Suggested types and API:
```gleam
// app/shell.gleam
pub type Child {
  Index(pages.index.Model)
  ArticleList(pages.article_list.Model)
  Article(pages.article.Model)
  ArticleEdit(pages.article_edit.Model)
  UrlShortIndex(pages.url_short_index.Model)
  UrlShortInfo(pages.url_short_info.Model)
  Notifications(pages.notifications.Model)
  Profile(pages.profile.Model)
  About(pages.about.Model)
  NotFound(pages.not_found.Model)
}

pub type Model {
  Model(
    route: app/router.Route,
    child: Child,
    session: auth/session.Session,
    // ... other truly global fields
  )
}

pub type Msg {
  RouteChanged(app/router.Route)
  IndexMsg(pages.index.Msg)
  ArticleListMsg(pages.article_list.Msg)
  ArticleMsg(pages.article.Msg)
  ArticleEditMsg(pages.article_edit.Msg)
  UrlShortIndexMsg(pages.url_short_index.Msg)
  UrlShortInfoMsg(pages.url_short_info.Msg)
  NotificationsMsg(pages.notifications.Msg)
  ProfileMsg(pages.profile.Msg)
  AboutMsg(pages.about.Msg)
  NotFoundMsg(pages.not_found.Msg)
  // Global messages (session updated, etc.)
}

pub fn init(/* flags */) -> #(Model, Effect(Msg))
pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg))
pub fn view(model: Model) -> Element(Msg)
```

- On `RouteChanged`, pick the page module, call its `init` or `load`, store `child`, and `Effect.map/2` child effects back to `ShellMsg`.
- In `view`, delegate to child page views using a `msg_map` function per child: `page.view(ShellMsgFromChild, child_model)`.

### Routing
- Keep routing pure and small.
- `app/router.gleam`: `Route` type, `from_uri/1`, `to_href/1` helpers. No IO, no fetching.
- Navigation messages should be `RouteChanged(parsed)`; fetching is owned by the page `init`/`update` after the shell selects the child.

### Subscriptions
- `app/subscriptions.gleam` exposes `fn subscriptions(model: Model) -> Effect(Msg)`.
- Shell aggregates global subscriptions (visibility, resize, keyboard, history popstate) and maps to `ShellMsg`.
- Child pages expose `fn subscriptions(model: Model) -> Effect(Msg)` if they need per-page subs; shell maps them with `Effect.map`.

### Page module contract
Each page is a small TEA app:
```gleam
pub type Model
pub type Msg

pub fn init(params, session, services) -> #(Model, Effect(Msg))
pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg))
pub fn view(map: fn(Msg) -> parent_msg, model: Model) -> Element(parent_msg)
// Optional
pub fn subscriptions(model: Model) -> Effect(Msg)
```
- `params` are route params specific to the page.
- `services` are functions from `features/*/service.gleam` that return `Effect(Msg)`.
- Handle long-running flows with explicit state machines, e.g. `NotLoaded -> Loading -> Loaded -> Saving -> Saved/Error`.

### Services (effects/IO)
- Only services perform HTTP/FFI. They’re parameterized by success/failure message constructors to keep pages pure.
- Move decode/encode logic to the service’s domain module.

Example:
```gleam
// features/article/service.gleam
pub fn get_metadata(on_ok: fn(List(Article)) -> msg, on_err: fn(HttpError) -> msg, base_uri: String) -> Effect(msg)
```

### Persistence
- Single write point in the shell after `update` returns.
- Detect changes in the parts of the model you persist and batch a `persist.localstorage_set` effect.
- Avoid scattering LocalStorage writes in many message branches.

Sketch:
```gleam
let #(m1, eff1) = update(msg, model)
let persist_eff = persist.localstorage_set(key, persist.encode(to_persistent(m1)))
#(m1, effect.batch([eff1, persist_eff]))
```

### Testing
- Unit test each page’s `update` and `view` with small models and messages.
- Test services’ decoders separately with fixture JSON.
- Route tests cover `from_uri` and `to_href`.

### Anti-patterns to avoid
- Triggering data fetching inside router or URL parsing.
- Global `Msg` handling page concerns directly; prefer nested child messages and `Effect.map`.
- Hidden side-effects (e.g. persistence) in ad-hoc wrappers; centralize in the shell.
- Mixing decode/encode with view code; keep in services.

### Migration notes (from current layout)
- Extract `update_navigation` branches into page `init/load` and `update`.
- Replace `update_with_localstorage` with shell-level persistence.
- Move HTTP decode/encode to `features/*/service.gleam`.
- Introduce child `Msg` mapping in shell, delete global page-specific arms as pages adopt ownership.

### Why this matches TEA
- A single top-level TEA (shell) composes child TEAs (pages) via message mapping.
- Pages are pure and encapsulated; services isolate side effects.
- Routing selects pages; fetching is initiated by pages, not by router.
- Subscriptions are explicit and mapped from child to parent.

## NEXT

Create a PLAN.md where you outline what a refactor with the following goals would look like.

- keep Model and Msg in jst_lustre.gleam
- keep update and view functions in jst_lustre.gleam
- move page view and exclusive state to their respective page/<name>.gleam
- keep things that we want to prefetch 
