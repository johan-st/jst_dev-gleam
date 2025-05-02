# jst_lustre

## build

```sh
# install javascript dependencies
npm i 
# or if no package.json is present
npm i marked
npm i dompurify
```

## Development

### Commands

```sh
gleam run -m lustre/dev start  --tailwind-entry=./src/styles.css
gleam run -m lustre/dev build --minify --outdir=priv/static # MIGHT NEED --tailwind-entry=./src/styles.css
gleam test 


```


## TODO

- fix local storage
- dict key should be slug
- links should be by slug?
  - or presta way. id <>"_"<>slug where only the id is used for routing
- try listening to nats for articles?