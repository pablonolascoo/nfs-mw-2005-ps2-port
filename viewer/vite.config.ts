import { defineConfig } from "vite";
// Los datos convertidos viven en ../map-data (fuera del visor) y se sirven tal cual.
// "three" apunta a la versión WebGPU para que addons y núcleo compartan clases.
export default defineConfig({
  publicDir: "../map-data",
  server: { port: 5181 },
  resolve: { alias: [{ find: /^three$/, replacement: "three/webgpu" }] },
});
