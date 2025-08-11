# Structure

## Model 

```gleam
pub type Model {
  Model(
    session: Session,
    route: Route,
    notices: List(Notice),
    modal: Option(Modal),
    keyboard: keyboard.Model,

    // Persistent data
    short_urls: RemoteData(ShortUrl),
    articles: RemoteData(Article),
  )
}
```

## Msg

```gleam
pub type Msg {
  LinkInternalClicked(Route),
  LinkExternalClicked(uri.Uri),
  Pages(pages.Msg),
  Notices(notice.Msg),
  Keyboard(keyboard.Msg),

  Modal(modal.Msg),
  ModalAction(modal.Action),
  ModalClose,

  ArticleGot(List(Article)),
  ArticleGotError(error.HttpError),
  ArticleEdit(article.Field),

  ShortUrlGot(List(ShortUrl)),
  ShortUrlGotError(error.HttpError),
  ShortUrlEdit(short_url.Field),

  Tick(byrl.Time),

  // Debug
  DebugModeSet(Bool),
}
```

## View

```gleam
pub fn view(model: Model) -> Element(Msg) {
  let content = case model.page {
    pages.PageIndex -> index.view()
    pages.PageAbout -> about.view()
    pages.PageProfile(session) -> profile.view(session)
    pages.PageError(error) -> error.view(error)
    pages.PageNotFound(uri) -> not_found.view(uri)
    _ -> todo as "unhandled page"
  }
  // Wrap main content in layout (header/footer can still read full model)
  layout.view(content)
}
```

## Update

```gleam
pub fn update(msg: Msg, model: Model) -> #(Model, Effect(Msg)) {
  case msg {
    LinkInternalClicked(new_route) ->
      #(Model(..model, route: new_route), Effect.none)

    ModalClose ->
      #(Model(..model, modal: None), Effect.none)

    ArticleGot(new_articles) ->
      #(Model(..model, articles: Success(new_articles)), Effect.none)
    ArticleGotError(err) ->
      #(Model(..model, articles: Failure(err)), Effect.none)

    ShortUrlGot(new_short_urls) ->
      #(Model(..model, short_urls: Success(new_short_urls)), Effect.none)
    ShortUrlGotError(err) ->
      #(Model(..model, short_urls: Failure(err)), Effect.none)

    _ ->
      #(model, Effect.none)
  }
}
```

### Navigation & Ephemeral State

- On route changes, reset ephemeral UI fields while keeping persistent data:
  - Reset: `profile_menu_open`, `notice`, `delete_confirmation`, `copy_feedback`, `expanded_urls`, `login_form_open`, `login_username`, `login_password`, `login_loading`.
  - Keep: `articles`, `short_urls`, `session`, `keyboard`, `base_uri`.