// Hilo de carga: descarga y descodifica GLB de casillas e imágenes fuera del hilo principal.
// Solo entiende el subconjunto de glTF que genera tools/src/lib/glb.ts (mallas indexadas, sin nodos anidados).
interface Prim { material: number; attrs: Record<string, ArrayBufferView>; index: Uint32Array }
type Req = { id: number; kind: "glb"; url: string } | { id: number; kind: "img"; url: string } | { id: number; kind: "tile"; url: string };

const COMP: Record<number, { ctor: typeof Float32Array | typeof Uint32Array | typeof Uint16Array | typeof Uint8Array }> = { 5126: { ctor: Float32Array }, 5125: { ctor: Uint32Array }, 5123: { ctor: Uint16Array }, 5121: { ctor: Uint8Array } };
const SIZE: Record<string, number> = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 };

async function parseGlb(url: string) {
  const buf = await (await fetch(url)).arrayBuffer();
  const dv = new DataView(buf);
  if (dv.getUint32(0, true) !== 0x46546c67) throw new Error(`no es GLB: ${url}`);
  const jsonLen = dv.getUint32(12, true);
  const json = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 20, jsonLen)));
  const binStart = 20 + jsonLen + 8;
  const transfer: ArrayBuffer[] = [];
  const accessor = (i: number) => {
    const a = json.accessors[i], v = json.bufferViews[a.bufferView], C = COMP[a.componentType].ctor;
    const n = a.count * SIZE[a.type];
    const out = new C(n); // copia compacta y transferible
    out.set(new C(buf, binStart + (v.byteOffset ?? 0) + (a.byteOffset ?? 0), n));
    transfer.push(out.buffer as ArrayBuffer);
    return out;
  };
  const meshes = json.meshes.map((m: { name: string; primitives: { attributes: Record<string, number>; indices: number; material: number }[] }) => ({
    name: m.name,
    prims: m.primitives.map(p => ({ material: p.material, index: accessor(p.indices) as Uint32Array, attrs: Object.fromEntries(Object.entries(p.attributes).map(([k, i]) => [k, accessor(i)])) })) as Prim[],
  }));
  const base = url.slice(0, url.lastIndexOf("/") + 1);
  const images = (json.images ?? []).map((im: { uri?: string }) => (im.uri ? new URL(im.uri, new URL(base, self.location.href)).href : null));
  const materials = (json.materials ?? []).map((m: { name: string; alphaMode?: string; pbrMetallicRoughness?: { baseColorFactor?: number[]; baseColorTexture?: { index: number } } }) => ({
    name: m.name, alphaMode: m.alphaMode ?? "OPAQUE", color: m.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1],
    image: m.pbrMetallicRoughness?.baseColorTexture ? images[json.textures[m.pbrMetallicRoughness.baseColorTexture.index].source] : null,
  }));
  const extras = json.nodes?.find((n: { mesh?: number; extras?: unknown }) => n.mesh !== undefined && n.extras)?.extras ?? null;
  return { result: { meshes, materials, extras }, transfer };
}

/**
 * Casilla cercana empaquetada: todas sus texturas en un array de capas (mismo tamaño) y toda la geometría en
 * dos mallas (opaca y con recorte alfa). Cada vértice lleva su capa en el atributo "layer". 2 llamadas de dibujo por casilla.
 */
async function packTile(url: string) {
  const { result } = await parseGlb(url);
  const mats = result.materials as { name: string; alphaMode: string; color: number[]; image: string | null }[];
  const imgs = [...new Set(mats.map(m => m.image).filter((x): x is string => !!x))];
  const S = imgs.length <= 32 ? 256 : 128;
  const layers = 1 + imgs.length; // capa 0 = blanco (materiales sin textura)
  const data = new Uint8Array(S * S * 4 * layers);
  data.fill(255, 0, S * S * 4);
  const canvas = new OffscreenCanvas(S, S), ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  const masked = new Set<number>();
  await Promise.all(imgs.map(async (u, i) => {
    const bmp = await createImageBitmap(await (await fetch(u)).blob(), { resizeWidth: S, resizeHeight: S, resizeQuality: "high", premultiplyAlpha: "none", colorSpaceConversion: "none" });
    return { i, bmp };
  })).then(list => { for (const { i, bmp } of list) { ctx.clearRect(0, 0, S, S); ctx.drawImage(bmp, 0, 0); data.set(ctx.getImageData(0, 0, S, S).data, (i + 1) * S * S * 4); bmp.close(); } });
  // Cadena de mipmaps calculada aquí (filtro de caja 2×2) para no generar cientos de pasadas en la GPU al subirla.
  const mips: Uint8Array[] = [];
  for (let size = S >> 1, prev = data, ps = S; size >= 1; ps = size, size >>= 1) {
    const m = new Uint8Array(size * size * 4 * layers);
    for (let l = 0; l < layers; l++) {
      const src = l * ps * ps * 4, dst = l * size * size * 4;
      for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
        const a = src + ((y * 2) * ps + x * 2) * 4, b = a + 4, c = a + ps * 4, d = c + 4, o = dst + (y * size + x) * 4;
        for (let k = 0; k < 4; k++) m[o + k] = (prev[a + k] + prev[b + k] + prev[c + k] + prev[d + k] + 2) >> 2;
      }
    }
    mips.push(m); prev = m;
  }
  const layerOf = mats.map(m => (m.image ? imgs.indexOf(m.image) + 1 : 0));
  mats.forEach((m, k) => { if (m.alphaMode === "MASK") masked.add(k); });
  const out: Record<"opaque" | "masked", { pos: number[]; uv: number[]; col: number[]; layer: number[]; id: number[]; idx: number[] }> = { opaque: { pos: [], uv: [], col: [], layer: [], id: [], idx: [] }, masked: { pos: [], uv: [], col: [], layer: [], id: [], idx: [] } };
  for (const mesh of result.meshes as { prims: { material: number; index: Uint32Array; attrs: Record<string, Float32Array> }[] }[]) for (const p of mesh.prims) {
    const g = out[masked.has(p.material) ? "masked" : "opaque"], base = g.pos.length / 3, n = p.attrs.POSITION.length / 3;
    const mc = mats[p.material].color, L = layerOf[p.material];
    for (let i = 0; i < n; i++) {
      g.pos.push(p.attrs.POSITION[i * 3], p.attrs.POSITION[i * 3 + 1], p.attrs.POSITION[i * 3 + 2]);
      g.uv.push(p.attrs.TEXCOORD_0?.[i * 2] ?? 0, p.attrs.TEXCOORD_0?.[i * 2 + 1] ?? 0);
      const c = p.attrs.COLOR_0; g.col.push((c?.[i * 4] ?? 1) * mc[0], (c?.[i * 4 + 1] ?? 1) * mc[1], (c?.[i * 4 + 2] ?? 1) * mc[2], c?.[i * 4 + 3] ?? 1);
      g.layer.push(L); g.id.push(p.attrs._ID?.[i] ?? 0);
    }
    for (let t = 0; t < p.index.length; t++) g.idx.push(base + p.index[t]);
  }
  const transfer: ArrayBuffer[] = [data.buffer, ...mips.map(m => m.buffer as ArrayBuffer)];
  const pack = (g: typeof out.opaque) => { if (!g.idx.length) return null; const r = { pos: new Float32Array(g.pos), uv: new Float32Array(g.uv), col: new Float32Array(g.col), layer: new Float32Array(g.layer), id: new Float32Array(g.id), idx: new Uint32Array(g.idx) }; transfer.push(...Object.values(r).map(a => a.buffer as ArrayBuffer)); return r; };
  return { result: { S, layers, data, mips, opaque: pack(out.opaque), masked: pack(out.masked), extras: result.extras, layerNames: ["(sin textura)", ...imgs.map(u => mats.find(m => m.image === u)!.name)] }, transfer };
}

self.onmessage = async (e: MessageEvent<Req>) => {
  const r = e.data;
  try {
    if (r.kind === "tile") { const { result, transfer } = await packTile(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else if (r.kind === "glb") { const { result, transfer } = await parseGlb(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else { const bmp = await createImageBitmap(await (await fetch(r.url)).blob(), { imageOrientation: "none", premultiplyAlpha: "none", colorSpaceConversion: "none" }); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result: bmp }, [bmp]); }
  } catch (err) { (self as unknown as Worker).postMessage({ id: r.id, ok: false, error: String(err) }); }
};
