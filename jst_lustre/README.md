# jst_lustre

## Development

```sh
gleam run -m lustre/dev start  --tailwind-entry=./src/styles.css
gleam run -m lustre/dev build --minify  --tailwind-entry=./src/styles.css --outdir=../server/web/static
gleam test 

```

## Development Priorities

### High Priority
- [ ] Clean up routes/pages code (remove duplicates, clarify usage)
- [ ] Implement NATS article listening
- [ ] Add proper states for initial article meta and localStorage data loading
- [ ] Fix navigation inconsistencies (direct links vs page loads)
- [ ] Implement hash-based anchor scrolling

### Medium Priority
- [ ] Enable LocalStorage functionality
- [ ] Add retry mechanism for failed article fetches
- [ ] Improve error messages for article loading failures

### Low Priority
- [ ] Add timestamps to articles
- [ ] Implement progressive loading for article metadata
- [ ] Fix history duplication and navigation handling

### Done

- Page type was a worse abstraction than Route. Recreate Route.
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
