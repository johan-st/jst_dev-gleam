# jst_lustre

## Development

```sh
gleam run -m lustre/dev start  --tailwind-entry=./src/styles.css
gleam run -m lustre/dev build --minify --outdir=priv/static # MIGHT NEED --tailwind-entry=./src/styles.css
gleam test 


```

## TODO

- try listening to nats for articles
- add states for initial load of article meta and local storage data
- make sure load and navigation are handled the same way. There are currentlly some inconsistencies. (e.g. navigating by link to "/article/test-article#booop" vs loading the same page)
- Navigation to a page with a hash should scroll to the corresponding anchor. (html: `<a href="#boop">` should scroll to the tag `<a id="boop">`)
- Enable LocalStorage
- Add retry mechanism for failed article fetches. currently we retry on reload or navigation to the article.
- Add proper error messages for article loading failures. (MID)
- Consider adding timestamps to article. (LOW)
- Consider implementing progressive loading or article metadata. (LOW)

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
