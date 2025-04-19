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
