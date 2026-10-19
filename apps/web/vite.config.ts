import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";

// One .env for the whole repo lives at the root (see .env.example).
const envDir = fileURLToPath(new URL("../..", import.meta.url));

// VITE_ variables are compiled into the public bundle. Refuse to build if one
// looks like a secret, so a mis-named key can never ship to the browser.
const SECRET_NAME = /PRIVATE|SECRET|MNEMONIC|SEED|PASSWORD|API_KEY/i;

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, envDir, "VITE_");
  const leaked = Object.keys(env).filter((name) => SECRET_NAME.test(name));
  if (leaked.length > 0) {
    throw new Error(
      `Refusing to build: these VITE_ variables look like secrets and would be public: ${leaked.join(", ")}`,
    );
  }

  return {
    envDir,
    envPrefix: "VITE_",
    plugins: [react()],
    worker: { format: "es" },
    server: { port: 5173, strictPort: true },
    preview: { port: 4173, strictPort: true },
    build: { target: "es2022", sourcemap: true },
  };
});
