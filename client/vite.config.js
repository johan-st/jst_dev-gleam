import { defineConfig } from "vite";
import gleam from "vite-gleam";

export default defineConfig({
    build: {
        outDir: "../server/priv/client",
        emptyOutDir: true,
        rollupOptions: {
            // input: {
            //     main: "./src/client.gleam"
            // }
        }
    },
    plugins: [gleam()]
})