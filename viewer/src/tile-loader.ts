// Construye en el hilo principal las casillas que descodifica tile-worker.ts. Coste aquí: crear objetos, no parsear.
import * as THREE from "three/webgpu";
import { texture as texNode, uv, attribute, vertexColor, time, vec2, float } from "three/tsl";

type Msg = { id: number; ok: boolean; result?: any; error?: string };
const workers = Array.from({ length: Math.max(2, Math.min(4, (navigator.hardwareConcurrency || 4) - 2)) }, () => new Worker(new URL("./tile-worker.ts", import.meta.url), { type: "module" }));
let seq = 0, rr = 0;
const pending = new Map<number, { res: (v: any) => void; rej: (e: Error) => void }>();
for (const w of workers) w.onmessage = (e: MessageEvent<Msg>) => { const p = pending.get(e.data.id); if (!p) return; pending.delete(e.data.id); e.data.ok ? p.res(e.data.result) : p.rej(new Error(e.data.error)); };
const call = <T>(kind: "glb" | "img" | "tile", url: string) => new Promise<T>((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); workers[rr++ % workers.length].postMessage({ id, kind, url }); });

/** Texturas compartidas por URL: se descodifican una vez (en el hilo de carga) y se suben una vez a la GPU. */
const textures = new Map<string, Promise<THREE.Texture>>();
function texture(url: string) {
  let t = textures.get(url);
  if (!t) {
    t = call<ImageBitmap>("img", url).then(bmp => {
      const tex = new THREE.Texture(bmp);
      tex.flipY = false; tex.colorSpace = THREE.SRGBColorSpace; tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
      tex.anisotropy = 4; tex.needsUpdate = true;
      return tex;
    });
    textures.set(url, t);
  }
  return t;
}

const GL2THREE: Record<string, string> = { POSITION: "position", NORMAL: "normal", TEXCOORD_0: "uv", COLOR_0: "color", _ID: "_id" };

export async function loadTile(url: string, materialCache: Map<string, THREE.Material>): Promise<THREE.Object3D> {
  const data = await call<{ meshes: { name: string; prims: { material: number; index: Uint32Array; attrs: Record<string, Float32Array> }[] }[]; materials: { name: string; alphaMode: string; cutoff: number; additive: boolean; shadow: boolean; water: boolean; color: number[]; image: string | null }[]; extras: Record<string, unknown> | null }>("glb", url);
  const mats = await Promise.all(data.materials.map(async m => {
    const key = `${m.name}|${m.image ?? ""}|${m.alphaMode}`;
    let mat = materialCache.get(key);
    if (!mat) {
      const mb = new THREE.MeshBasicMaterial({ name: m.name, color: new THREE.Color(m.color[0], m.color[1], m.color[2]), side: THREE.DoubleSide, vertexColors: true });
      if (m.image) mb.map = await texture(m.image);
      if (m.alphaMode === "MASK") mb.alphaTest = m.cutoff;
      if (m.water) { mb.transparent = true; mb.depthWrite = false; mb.opacity = 0.7; }
      if (m.shadow) { mb.transparent = true; mb.depthWrite = false; mb.polygonOffset = true; mb.polygonOffsetFactor = -1; mb.polygonOffsetUnits = -4; }
      if (m.additive) { mb.transparent = true; mb.depthWrite = false; mb.blending = THREE.AdditiveBlending; }
      mat = mb; materialCache.set(key, mat);
    }
    return mat;
  }));
  const root = new THREE.Group();
  root.rotation.x = Math.PI / 2; // el contenido ya está en coordenadas del juego tras deshacer la rotación glTF
  const inner = new THREE.Group();
  inner.rotation.x = -Math.PI / 2; // rotación del nodo raíz del GLB (Z-arriba → Y-arriba)
  root.add(inner);
  for (const m of data.meshes) {
    const g = new THREE.Group(); g.name = m.name; if (data.extras) g.userData = data.extras;
    for (const p of m.prims) {
      if (!p.index.length) continue; // casillas lejanas vacías
      const geo = new THREE.BufferGeometry();
      for (const [k, arr] of Object.entries(p.attrs)) geo.setAttribute(GL2THREE[k] ?? k.toLowerCase(), new THREE.BufferAttribute(arr, k === "POSITION" || k === "NORMAL" ? 3 : k === "TEXCOORD_0" ? 2 : k === "COLOR_0" ? 4 : 1));
      if (!p.attrs.COLOR_0) { const n = (p.attrs.POSITION.length / 3); geo.setAttribute("color", new THREE.BufferAttribute(new Float32Array(n * 4).fill(1), 4)); }
      geo.setIndex(new THREE.BufferAttribute(p.index, 1));
      geo.computeBoundingSphere();
      const mesh = new THREE.Mesh(geo, mats[p.material]);
      mesh.matrixAutoUpdate = false; mesh.updateMatrix();
      g.add(mesh);
    }
    inner.add(g);
  }
  return root;
}

/** Casilla cercana en 2 llamadas de dibujo: array de texturas + atributo de capa por vértice (ver tile-worker.ts). */
export async function loadPackedTile(url: string, renderer: THREE.WebGPURenderer): Promise<THREE.Object3D> {
  type G = { pos: Float32Array; uv: Float32Array; col: Float32Array; layer: Float32Array; id: Float32Array; idx: Uint32Array } | null;
  const d = await call<{ S: number; layers: number; data: Uint8Array; mips: Uint8Array[]; groups: Record<"opaque" | "mask50" | "mask30" | "additive" | "shadow" | "water", G>; extras: Record<string, unknown> | null; layerNames: string[] }>("tile", url);
  const arr = new THREE.DataArrayTexture(d.data as Uint8Array<ArrayBuffer>, d.S, d.S, d.layers);
  arr.colorSpace = THREE.SRGBColorSpace; arr.wrapS = arr.wrapT = THREE.RepeatWrapping;
  arr.magFilter = THREE.LinearFilter; arr.minFilter = THREE.LinearMipmapLinearFilter; arr.anisotropy = 4;
  // Three no sube mipmaps propios en arrays: se reservan los niveles (mipmaps no vacío, sin generación en GPU)
  // y se escriben a mano con writeTexture, ya calculados en el hilo de carga.
  arr.generateMipmaps = false;
  const noMips = new URLSearchParams(location.search).get("mips") === "0";
  if (noMips) { arr.minFilter = THREE.LinearFilter; d.mips = []; }
  if (!noMips) arr.mipmaps = [{ data: d.data, width: d.S, height: d.S }, ...d.mips.map((m, i) => ({ data: m, width: d.S >> (i + 1), height: d.S >> (i + 1) }))] as unknown as typeof arr.mipmaps;
  arr.needsUpdate = true;
  renderer.initTexture(arr);
  const backend = renderer.backend as unknown as { device: GPUDevice; get(t: unknown): { texture?: GPUTexture } };
  const gpuTex = backend.get(arr).texture;
  (globalThis as unknown as { __mipStats?: { ok: number; missing: number } }).__mipStats ??= { ok: 0, missing: 0 };
  (globalThis as unknown as { __mipStats: { ok: number; missing: number } }).__mipStats[gpuTex ? "ok" : "missing"]++;
  if (gpuTex) d.mips.forEach((m, i) => { const w = d.S >> (i + 1); backend.device.queue.writeTexture({ texture: gpuTex, mipLevel: i + 1 }, m as Uint8Array<ArrayBuffer>, { bytesPerRow: w * 4, rowsPerImage: w }, { width: w, height: w, depthOrArrayLayers: d.layers }); });
  const root = new THREE.Group();
  root.userData = { ...(d.extras ?? {}), capas: d.layerNames };
  for (const [kind, g] of Object.entries(d.groups) as ["opaque" | "mask50" | "mask30" | "additive" | "shadow" | "water", G][]) {
    if (!g) continue;
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(g.pos, 3));
    geo.setAttribute("uv", new THREE.BufferAttribute(g.uv, 2));
    geo.setAttribute("color", new THREE.BufferAttribute(g.col, 4));
    geo.setAttribute("layer", new THREE.BufferAttribute(g.layer, 1));
    geo.setAttribute("_id", new THREE.BufferAttribute(g.id, 1));
    geo.setIndex(new THREE.BufferAttribute(g.idx, 1));
    geo.computeBoundingSphere();
    let mesh_renderOrder = 0;
    const mat = new THREE.MeshBasicNodeMaterial({ side: THREE.DoubleSide, name: `array ${kind}` });
    // El agua desplaza sus UV con el tiempo (en el juego es una animación de 14 texturas).
    const tex = kind === "water" ? texNode(arr, uv().add(vec2(time.mul(0.03), time.mul(0.017)))).depth(attribute("layer", "float")) : texNode(arr, uv()).depth(attribute("layer", "float"));
    mat.colorNode = tex.rgb.mul(vertexColor().rgb);
    if (kind === "mask50" || kind === "mask30") { mat.opacityNode = tex.a; mat.alphaTest = kind === "mask50" ? 0.5 : 0.3; }
    if (kind === "water") { mat.opacityNode = vertexColor().a.mul(float(1.4)).min(1); mat.transparent = true; mat.depthWrite = false; mesh_renderOrder = 2; }
    if (kind === "shadow") { mat.opacityNode = tex.a; mat.transparent = true; mat.depthWrite = false; mat.polygonOffset = true; mat.polygonOffsetFactor = -1; mat.polygonOffsetUnits = -4; mesh_renderOrder = 1; }
    if (kind === "additive") { mat.opacityNode = tex.a; mat.transparent = true; mat.depthWrite = false; mat.blending = THREE.AdditiveBlending; }
    const mesh = new THREE.Mesh(geo, mat);
    mesh.matrixAutoUpdate = false; mesh.renderOrder = mesh_renderOrder;
    root.add(mesh);
  }
  return root;
}
