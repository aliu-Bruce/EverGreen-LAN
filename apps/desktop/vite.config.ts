import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 要求固定端口，并且不清屏，以便其自身日志保持可见。
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
  build: {
    target: "chrome110",
    sourcemap: false,
  },
});
