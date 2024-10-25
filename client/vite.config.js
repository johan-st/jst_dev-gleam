import gleam, { build } from "vite-gleam";

export default {
  build: {
    outDir: "../server/priv/static",
    emptyOutDir: false,
  },
  plugins: [gleam()],
};