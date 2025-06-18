# jst_lustre

## Development

```sh
gleam run -m lustre/dev start  --tailwind-entry=./src/styles.css
gleam run -m lustre/dev build --minify --outdir=priv/static # MIGHT NEED --tailwind-entry=./src/styles.css
gleam test 


```

## TODO

- Page type was a worse abstraction than Route. Recreate Route.
- try listening to nats for articles
- add states for initial load of article meta and local storage data

### Done

- article content should probably be RemoteData(List(Content), HttpError) to simplify states where we are loading or failed to load the content.

### Dismissed

- Consider: Route might need to be simplified to not contain the entire article. If the article does not yet exist we might be better off handling that in a page type or with the RemoteData(a,b) type.

```gleam

// CHECK "making impossible states impossible"-lecture again..
type ModelLoadState {
  NotLoaded
  LoadedFromLocalStorage(local_storage_model: Model)
  LoadedFromServer(server_model: Model)
  LoadedBoth(local_storage_model: Model, server_model: Model)

}

```
