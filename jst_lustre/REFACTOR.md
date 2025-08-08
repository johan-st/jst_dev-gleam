## Refactor proposal for jst_lustre (Lustre/Gleam frontend)

### Executive summary

- **Monolithic app**: `Model`, `Msg`, `init`, `update`, `view` live almost entirely in `src/jst_lustre.gleam` and cover many domains (articles, auth, url shortener, notifications, profile, keyboard, window events). This hurts cohesion, testing, and change velocity.
- **Route-side effects mixed in navigation**: Data fetching and page wiring happen in `update_navigation` alongside route changes.
- **Persistence concerns mixed into update**: LocalStorage writes are sprinkled via a wrapper update.
- **Large global Msg**: Page/feature messages are flattened into one big sum type.

Recommended: modularize by page and/or by feature slice, isolate effects behind service modules, and adopt child TEA composition. Two concrete architectures below.

## Observations and issues

- **LocalStorage mix-in update wrapper**: Persistence is coupled to specific messages only, making it easy to miss writes and hard to test.

```276:308:jst_lustre/src/jst_lustre.gleam
fn update_with_localstorage(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case model.debug_use_local_storage {
    True -> {
      let #(new_model, effect) = update(model, msg)
      let persistent_model = fn(model: Model) -> PersistentModel {
        PersistentModelV1(articles: case model.articles {
          NotInitialized -> []
          Pending -> []
          Loaded(articles) -> articles
          Optimistic(_) -> []
          Errored(_) -> []
        })
      }
      case msg {
        ArticleMetaGot(_) -> {
          persist.localstorage_set(
            persist.model_localstorage_key,
            persist.encode(persistent_model(new_model)),
          )
        }
        ArticleGot(_, _) -> {
          persist.localstorage_set(
            persist.model_localstorage_key,
            persist.encode(persistent_model(new_model)),
          )
        }
        _ -> Nil
      }
      #(new_model, effect)
    }
    False -> update(model, msg)
  }
}
```

Problems:
- **Partial persistence**: Only writes for two message kinds; other mutations (create/update/delete/publish) won’t persist unless remembered.
- **Side-effects hidden in wrapper**: Surprising for new contributors; complicates tests because behavior depends on a debug flag.

- **Route handling triggers data fetching inline**: `update_navigation` both updates route and dispatches multiple feature fetches. This couples routing to data flows and scatters feature logic.

```1509:1619:jst_lustre/src/jst_lustre.gleam
fn update_navigation(model: Model, uri: Uri) -> #(Model, Effect(Msg)) {
  let route = routes.from_uri(uri)
  case route {
    routes.Article(slug) -> {
      case model.articles {
        NotInitialized -> #(
          Model(..model, route:, articles: Pending),
          article.article_metadata_get(ArticleMetaGot, model.base_uri),
        )
        Loaded(articles) -> {
          let #(effect, articles_updated) =
            list.map_fold(
              over: articles,
              from: effect.none(),
              with: fn(eff, art) {
                case art.slug == slug, art.content {
                  True, NotInitialized -> #(
                    effect.batch([
                      eff,
                      article.article_get(
                        ArticleGot(art.id, _),
                        art.id,
                        model.base_uri,
                      ),
                    ]),
                    ArticleV1(..art, content: Pending),
                  )
                  _, _ -> #(eff, art)
                }
              },
            )
          #(Model(..model, route:, articles: Loaded(articles_updated)), effect)
        }
        _ -> #(Model(..model, route:), effect.none())
      }
    }
    ...
  }
}
```

Problems:
- **Feature logic in router**: Article-specific loading and short-url bootstrapping live here, creating a hub for many domains.
- **Hard to reuse**: Fetch logic can’t be reused by a different page or component without duplicating.

- **Global view composes all pages**: Single `view` matches every page variant and renders UI. This makes the file long and editing risky.

```1625:1657:jst_lustre/src/jst_lustre.gleam
fn view(model: Model) -> Element(Msg) {
  let page = page_from_model(model)
  let content = case page {
    pages.Loading(_) -> view_loading()
    pages.PageIndex -> view_index()
    pages.PageArticleList(articles, session) ->
      view_article_listing(articles, session)
    pages.PageArticleListLoading -> view_article_listing_loading()
    pages.PageArticle(article, session) -> view_article(article, session)
    pages.PageArticleEdit(article, _) -> view_article_edit(model, article)
    pages.PageError(error) -> { ... }
    pages.PageAbout -> view_about()
    pages.PageUrlShortIndex(_) -> view_url_index(model)
    pages.PageUrlShortInfo(short, _) -> view_url_info_page(model, short)
    pages.PageDjotDemo(content) -> view_djot_demo(content)
    pages.PageUiComponents(_) -> view_ui_components()
    pages.PageNotifications(_) -> view_notifications(model)
    pages.PageProfile(_) -> view_profile(model)
    pages.PageNotFound(uri) -> view_not_found(uri)
  }
  ...
}
```

- **Probable compile issue in `pages.gleam`**: The module uses `remote_data.*` constructors without importing the module alias. Consider importing `utils/remote_data as remote_data` or importing constructors directly.

```154:168:jst_lustre/src/pages/pages.gleam
case articles {
  remote_data.Pending -> PageArticleListLoading
  remote_data.NotInitialized -> PageArticleListLoading
  remote_data.Errored(error) ->
    PageError(HttpError(error, "Failed to load article list"))
  remote_data.Loaded(articles_list)
  | remote_data.Optimistic(articles_list) -> {
    let allowed_articles =
      articles_list
      |> list.filter(article.can_view(_, session))
    PageArticleList(allowed_articles, session)
  }
}
```

## Architecture alternative A: Page-as-child TEA (Elm style)

- **Goal**: Each page owns its `Model`, `Msg`, `init/load`, `update`, `view`. The app is a small shell: global chrome, session, and routing.
- **Benefits**: Localized state, smaller global `Msg`, easier testing and code ownership.

Suggested structure:

```
src/
  app/
    shell.gleam         // ShellModel, ShellMsg, init, update, view, route->child
    router.gleam        // parse/format routes only
  pages/
    index_page.gleam    // Model/Msg/init/update/view
    article_list.gleam
    article_page.gleam
    article_edit_page.gleam
    short_url_page.gleam
    notifications_page.gleam
    profile_page.gleam
```

API sketch for a page module:

```gleam
pub type Model
pub type Msg

pub fn init(route_params, session, services) -> #(Model, Effect(Msg))
pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg))
pub fn view(msg_map: fn(Msg) -> parent_msg, model: Model) -> Element(parent_msg)
```

- **Routing flow**:
  - On `RouteChanged`, the shell picks a page module, calls its `init` (or `load`), and stores child model in `ShellModel.child`.
  - Child effects are mapped via `Effect.map(child_msg_to_parent)`.
- **Data fetching**: Pages fetch their own data in `init`/`update` rather than in `update_navigation`.
- **Persistence**: Provide a `persist` helper once in shell that subscribes to model changes and writes to LocalStorage (see B below), removing wrapper update.

## Architecture alternative B: Feature-sliced + services

- **Goal**: Organize by domain and separate HTTP/services from UI state. Pages compose features.

Suggested structure:

```
src/
  app/
    shell.gleam
    router.gleam
  features/
    article/
      types.gleam         // Article, Draft, decoders/encoders
      service.gleam       // Effects: get_metadata, get, save, publish, delete
      list_component.gleam// Small TEA for list
      editor_component.gleam
      viewer_component.gleam
    auth/
      session.gleam       // existing session split into types + service
    short_url/
      types.gleam
      service.gleam
      list_component.gleam
    profile/
      service.gleam
      form_component.gleam
  shared/
    ui.gleam              // existing components
    remote_data.gleam     // existing
    persist.gleam         // cross-cutting persistence
```

Pattern:
- Pages compose feature components; components bubble `Msg` up with `Msg = ArticleListMsg(article_list.Msg) | EditorMsg(editor.Msg) | ...`.
- Services are the only place that talk HTTP/FFI; pages/components call services and receive domain types.
- Tests can target services (pure decoders) and components (update/view) independently.

## Cross-cutting improvements (apply to both A and B)

- **Persistence as a single concern**:
  - Replace `update_with_localstorage` with a small state observer in shell: detect when parts of the model changed and write once, e.g. after `update` returns.
  - Example wrapper:
    ```gleam
    fn update_shell(msg, model) {
      let #(m, eff) = update(model, msg)
      let write = persist.encode(to_persistent(m))
      #(m, effect.batch([ eff, persist.localstorage_set(key, write) ]))
    }
    ```
- **Guarded routing**:
  - Centralize auth checks per route before constructing page modules (return a `PageError(AuthenticationRequired)` or a redirect msg).
- **Msg size reduction**:
  - Use nested messages per page/component; map child effects back into parent. This shrinks the global `Msg` and reduces match arms.
- **State machines for long-running flows**:
  - For editor and profile forms, model transitions explicitly: NotLoaded -> Loading -> Loaded -> Saving -> Saved/Error. This removes many ad-hoc boolean flags.

## Quick wins (low risk)

- Fix `pages.gleam` imports for `remote_data.*` constructors (import the module or constructors explicitly).
- Move HTTP decode/encode functions into their domain service modules (`features/article/service.gleam`, `features/profile/service.gleam`).
- Extract `update_navigation` branches into page/feature-specific functions now, then migrate to child-TEA incrementally.
- Wrap LocalStorage persistence in one place; remove `debug_use_local_storage` branching inside the update path.

## Example: Child page wiring (incremental step)

```gleam
// in app/shell.gleam
pub type Child {
  ArticleList(article_list.Model)
  ArticlePage(article_page.Model)
  // ...
}

pub type Msg {
  RouteChanged(Route)
  ArticleListMsg(article_list.Msg)
  ArticlePageMsg(article_page.Msg)
  // ...
}

fn update(msg, model) {
  case msg {
    RouteChanged(route) -> route_to_child(route, model)
    ArticleListMsg(m) ->
      let #(cm, eff) = article_list.update(m, model.child_article_list)
      #(Model(..model, child: ArticleList(cm)), Effect.map(ArticleListMsg, eff))
    // ...
  }
}
```

## Migration plan (suggested order)

- **Week 1**
  - Extract article list/page/edit view + update into `pages/article_*` while keeping old `Msg` mapped.
  - Introduce `features/article/service.gleam`; move HTTP effects there.
  - Fix `pages.gleam` import issues.

- **Week 2**
  - Introduce shell module; route to child pages; map child messages/effects. Delete old `update_navigation` branches as pages take over data fetching.
  - Replace `update_with_localstorage` with single persistence point in shell.

## Risks and mitigations

- **Temporary duplication**: During extraction, some types/effects will be duplicated; keep modules small and delete old branches promptly.
- **Msg mapping boilerplate**: Use a consistent naming pattern `FeatureMsg` and helpers to map effects to reduce friction.

## Final note

Both alternatives drastically reduce the size and responsibility of `src/jst_lustre.gleam`, isolate effects, and make routing, state, and persistence explicit. Start by extracting one page to validate the pattern, then proceed feature-by-feature.

