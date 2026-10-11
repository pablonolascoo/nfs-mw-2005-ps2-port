import { BufferGeometry, BufferAttribute } from "three";
import { MeshBVH } from "three-mesh-bvh";
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
  const materials = (json.materials ?? []).map((m: { name: string; alphaMode?: string; alphaCutoff?: number; extras?: { blend?: string }; pbrMetallicRoughness?: { baseColorFactor?: number[]; baseColorTexture?: { index: number } } }) => ({
    name: m.name, alphaMode: m.alphaMode ?? "OPAQUE", cutoff: m.alphaCutoff ?? 0.5, additive: m.extras?.blend === "aditiva", shadow: m.extras?.blend === "sombra", water: m.extras?.blend === "agua", color: m.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1],
    image: m.pbrMetallicRoughness?.baseColorTexture ? images[json.textures[m.pbrMetallicRoughness.baseColorTexture.index].source] : null,
  }));
  const extras = json.nodes?.find((n: { mesh?: number; extras?: unknown }) => n.mesh !== undefined && n.extras)?.extras ?? null;
  return { result: { meshes, materials, extras }, transfer };
}

/**
 * Casilla cercana empaquetada: todas sus texturas en un array de capas (mismo tamaño) y toda la geometría en
 * dos mallas (opaca y con recorte alfa). Cada vértice lleva su capa en el atributo "layer". 2 llamadas de dibujo por casilla.
 */
/**
 * Descodifica un PNG RGBA de 8 bits (los que genera tools/src/lib/png.ts) sin lienzo 2D: el lienzo premultiplica
 * por el alfa y destruye el color de las texturas "moduladas" (alfa ≈ 0 pero opacas en el juego).
 */
async function decodePng(buf: ArrayBuffer): Promise<{ w: number; h: number; px: Uint8Array }> {
  const b = new Uint8Array(buf), dv = new DataView(buf);
  let o = 8, w = 0, h = 0; const idat: Uint8Array[] = [];
  while (o < b.length) {
    const len = dv.getUint32(o), type = String.fromCharCode(...b.subarray(o + 4, o + 8));
    if (type === "IHDR") { w = dv.getUint32(o + 8); h = dv.getUint32(o + 12); if (b[o + 16] !== 8 || b[o + 17] !== 6) throw new Error("PNG no RGBA8"); }
    else if (type === "IDAT") idat.push(b.subarray(o + 8, o + 8 + len));
    o += 12 + len;
  }
  const raw = new Uint8Array(await new Response(new Blob(idat as BlobPart[]).stream().pipeThrough(new DecompressionStream("deflate"))).arrayBuffer());
  const px = new Uint8Array(w * h * 4), stride = w * 4;
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], src = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)), dst = px.subarray(y * stride, (y + 1) * stride), up = y ? px.subarray((y - 1) * stride, y * stride) : null;
    for (let i = 0; i < stride; i++) {
      const a = i >= 4 ? dst[i - 4] : 0, c = up ? up[i] : 0, bb = up && i >= 4 ? up[i - 4] : 0;
      let v = src[i];
      if (f === 1) v += a; else if (f === 2) v += c; else if (f === 3) v += (a + c) >> 1;
      else if (f === 4) { const p = a + c - bb, pa = Math.abs(p - a), pb = Math.abs(p - c), pc = Math.abs(p - bb); v += pa <= pb && pa <= pc ? a : pb <= pc ? c : bb; }
      dst[i] = v & 255;
    }
  }
  return { w, h, px };
}
/** Reescala a S×S (caja si reduce, vecino si amplía) sin premultiplicar. */
function resize(img: { w: number; h: number; px: Uint8Array }, S: number, out: Uint8Array, off: number) {
  const sx = img.w / S, sy = img.h / S;
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const x0 = Math.floor(x * sx), y0 = Math.floor(y * sy), x1 = Math.max(x0 + 1, Math.floor((x + 1) * sx)), y1 = Math.max(y0 + 1, Math.floor((y + 1) * sy));
    let r = 0, g = 0, b = 0, a = 0, n = 0;
    for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) { const i = (yy * img.w + xx) * 4; r += img.px[i]; g += img.px[i + 1]; b += img.px[i + 2]; a += img.px[i + 3]; n++; }
    const o = off + (y * S + x) * 4; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n; out[o + 3] = a / n;
  }
}

async function packTile(url: string) {
  const { result } = await parseGlb(url);
  const mats = result.materials as { name: string; alphaMode: string; cutoff: number; additive: boolean; shadow: boolean; water: boolean; color: number[]; image: string | null }[];
  const imgs = [...new Set(mats.map(m => m.image).filter((x): x is string => !!x))];
  const S = imgs.length <= 32 ? 256 : 128;
  const layers = 1 + imgs.length; // capa 0 = blanco (materiales sin textura)
  const data = new Uint8Array(S * S * 4 * layers);
  data.fill(255, 0, S * S * 4);

  type K = "opaque" | "mask50" | "mask30" | "additive" | "shadow" | "water";
  const kindOf = (m: (typeof mats)[number]): K => m.water ? "water" : m.shadow ? "shadow" : m.additive ? "additive" : m.alphaMode === "MASK" ? (m.cutoff >= 0.45 ? "mask50" : "mask30") : "opaque";
  await Promise.all(imgs.map(async (u, i) => resize(await decodePng(await (await fetch(u)).arrayBuffer()), S, data, (i + 1) * S * S * 4)));
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
  const mk = () => ({ pos: [] as number[], uv: [] as number[], col: [] as number[], layer: [] as number[], id: [] as number[], idx: [] as number[] });
  const out: Record<K, ReturnType<typeof mk>> = { opaque: mk(), mask50: mk(), mask30: mk(), additive: mk(), shadow: mk(), water: mk() };
  for (const mesh of result.meshes as { prims: { material: number; index: Uint32Array; attrs: Record<string, Float32Array> }[] }[]) for (const p of mesh.prims) {
    const g = out[kindOf(mats[p.material])], base = g.pos.length / 3, n = p.attrs.POSITION.length / 3;
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
  // Colisionador (BVH) construido aquí, en modo indirecto (no reordena los índices) y serializado: el hilo principal no lo calcula.
  const bvhOf = (pos: Float32Array, idx: Uint32Array) => {
    const g = new BufferGeometry(); g.setAttribute("position", new BufferAttribute(pos, 3)); g.setIndex(new BufferAttribute(idx, 1));
    const ser = MeshBVH.serialize(new MeshBVH(g, { indirect: true, maxLeafTris: 12 }), { cloneBuffers: true });
    for (const r of ser.roots) transfer.push(r as ArrayBuffer);
    if (ser.indirectBuffer) transfer.push(ser.indirectBuffer.buffer as ArrayBuffer);
    return ser;
  };
  const pack = (g: typeof out.opaque, collide = false) => { if (!g.idx.length) return null; const r = { pos: new Float32Array(g.pos), uv: new Float32Array(g.uv), col: new Float32Array(g.col), layer: new Float32Array(g.layer), id: new Float32Array(g.id), idx: new Uint32Array(g.idx) }; const bvh = collide ? bvhOf(r.pos, r.idx) : null; transfer.push(...Object.values(r).map(a => a.buffer as ArrayBuffer)); return { ...r, bvh }; };
  return { result: { S, layers, data, mips, groups: { opaque: pack(out.opaque, true), mask50: pack(out.mask50, true), mask30: pack(out.mask30), additive: pack(out.additive), shadow: pack(out.shadow), water: pack(out.water) }, extras: result.extras, layerNames: ["(sin textura)", ...imgs.map(u => mats.find(m => m.image === u)!.name)] }, transfer };
}

self.onmessage = async (e: MessageEvent<Req>) => {
  const r = e.data;
  try {
    if (r.kind === "tile") { const { result, transfer } = await packTile(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else if (r.kind === "glb") { const { result, transfer } = await parseGlb(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else { const bmp = await createImageBitmap(await (await fetch(r.url)).blob(), { imageOrientation: "none", premultiplyAlpha: "none", colorSpaceConversion: "none" }); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result: bmp }, [bmp]); }
  } catch (err) { (self as unknown as Worker).postMessage({ id: r.id, ok: false, error: String(err) }); }
};
