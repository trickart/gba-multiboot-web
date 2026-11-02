import { defineConfig } from "vite";

// GitHub Pages (https://<user>.github.io/<repo>/) 向け。
// リポジトリ名が違う場合は BASE_PATH 環境変数で上書きする。
export default defineConfig({
  base: process.env.BASE_PATH ?? "/gba-multiboot-web/",
  build: {
    target: "es2022",
    outDir: "dist",
  },
});
