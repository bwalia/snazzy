import { defineConfig } from "vite";

// Tauri serves the built files; in development it loads the Vite server.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: "es2022", outDir: "dist", emptyOutDir: true },
});
