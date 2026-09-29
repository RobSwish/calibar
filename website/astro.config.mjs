import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://calibar.app",
  output: "static",
  devToolbar: { enabled: false },
  build: { format: "directory", inlineStylesheets: "always" },
  vite: { server: { strictPort: true } },
});
