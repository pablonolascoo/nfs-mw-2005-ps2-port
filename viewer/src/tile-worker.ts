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
  // Modo de dibujo de cada material según tools/src/lib/materials.ts (alphaFor): extras.blend + alphaMode + muestreador.
  type GlMat = { name: string; alphaMode?: string; alphaCutoff?: number; extras?: { blend?: string }; pbrMetallicRoughness?: { baseColorFactor?: number[]; baseColorTexture?: { index: number } } };
  const materials = (json.materials ?? []).map((m: GlMat) => {
    const tex = m.pbrMetallicRoughness?.baseColorTexture ? json.textures[m.pbrMetallicRoughness.baseColorTexture.index] : null;
    const smp = tex && json.samplers?.[tex.sampler ?? -1];
    const blend = m.extras?.blend;
    return {
      name: m.name, alphaMode: m.alphaMode ?? "OPAQUE", cutoff: m.alphaCutoff ?? 0.5,
      additive: blend === "aditiva", shadow: blend === "sombra", water: blend === "agua", decal: m.alphaMode === "BLEND" && (blend === "mezcla" || blend === "recorte_mezcla"),
      color: m.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1],
      // TilableUV del juego → CLAMP_TO_EDGE (33071) por eje; por defecto se repite.
      clampU: smp?.wrapS === 33071, clampV: smp?.wrapT === 33071,
      image: tex ? images[tex.source] : null,
    };
  });
  const extras = json.nodes?.find((n: { mesh?: number; extras?: unknown }) => n.mesh !== undefined && n.extras)?.extras ?? null;
  return { result: { meshes, materials, extras }, transfer };
}

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
type Kind = "opaque" | "mask" | "decal" | "additive" | "shadow" | "water";
type Mat = { name: string; alphaMode: string; cutoff: number; additive: boolean; shadow: boolean; water: boolean; decal: boolean; color: number[]; clampU: boolean; clampV: boolean; image: string | null };
const kindOf = (m: Mat): Kind => m.water ? "water" : m.shadow ? "shadow" : m.additive ? "additive" : m.decal || m.alphaMode === "BLEND" ? "decal" : m.alphaMode === "MASK" ? "mask" : "opaque";
const MAX_LAYERS = 256; // límite por defecto de WebGPU (maxTextureArrayLayers): más capas = textura inválida y casilla invisible

/** Rellena el RGB de los texeles transparentes con el de sus vecinos opacos: sin esto el filtrado bilineal y los mipmaps
 *  mezclan el negro de los texeles vacíos y salen bordes oscuros en hojas, vallas y pintadas. No cambia el alfa. */
function dilate(px: Uint8Array, w: number, h: number, passes = 4) {
  let known = new Uint8Array(w * h); for (let i = 0; i < w * h; i++) known[i] = px[i * 4 + 3] > 8 ? 1 : 0;
  for (let p = 0; p < passes; p++) {
    const next = known.slice(); let changed = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = y * w + x; if (known[i]) continue;
      let r = 0, g = 0, b = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const j = ((y + dy + h) % h) * w + ((x + dx + w) % w);
        if (known[j]) { r += px[j * 4]; g += px[j * 4 + 1]; b += px[j * 4 + 2]; n++; }
      }
      if (n) { px[i * 4] = r / n; px[i * 4 + 1] = g / n; px[i * 4 + 2] = b / n; next[i] = 1; changed++; }
    }
    known = next;
    if (!changed) break;
  }
}

/**
 * Casilla cercana empaquetada: las texturas se agrupan por tamaño exacto (sin reescalar: misma nitidez que el juego) en
 * arrays de capas de hasta 256, y la geometría en una malla por (array, modo de dibujo). Cada vértice lleva su capa
 * ("layer") y si su textura se recorta en U/V ("wrapc", TilableUV del juego).
 */
async function packTile(url: string) {
  const { result } = await parseGlb(url);
  const mats = result.materials as Mat[];
  const imgUrls = [...new Set(mats.map(m => m.image).filter((x): x is string => !!x))];
  const alphaUse = new Map<string, boolean>(); for (const m of mats) if (m.image) alphaUse.set(m.image, alphaUse.get(m.image) || kindOf(m) !== "opaque");
  const decoded = await Promise.all(imgUrls.map(async u => ({ u, ...(await decodePng(await (await fetch(u)).arrayBuffer())) })));
  // Cubos por tamaño; el cubo 0 es una capa blanca de 4×4 para materiales sin textura.
  type Bucket = { w: number; h: number; imgs: typeof decoded };
  const buckets: Bucket[] = [{ w: 4, h: 4, imgs: [] }];
  const where = new Map<string, { b: number; layer: number }>();
  for (const img of decoded.sort((a, b) => a.w - b.w || a.h - b.h)) {
    let b = buckets.findIndex((k, i) => i > 0 && k.w === img.w && k.h === img.h && k.imgs.length < MAX_LAYERS);
    if (b < 0) { buckets.push({ w: img.w, h: img.h, imgs: [] }); b = buckets.length - 1; }
    buckets[b].imgs.push(img); where.set(img.u, { b, layer: buckets[b].imgs.length - 1 });
  }
  const transfer: ArrayBuffer[] = [];
  const arrays = buckets.map((bk, bi) => {
    const layers = bi === 0 ? 1 : bk.imgs.length, size = bk.w * bk.h * 4;
    const data = new Uint8Array(size * layers);
    if (bi === 0) data.fill(255);
    const weighted: boolean[] = [];
    bk.imgs.forEach((img, l) => { const px = img.px; const a = alphaUse.get(img.u) ?? false; if (a) dilate(px, img.w, img.h); data.set(px, l * size); weighted.push(a); });
    // Mipmaps (caja 2×2) calculados aquí; en texturas con alfa útil el RGB se pondera por el alfa (sin halos oscuros).
    const mips: Uint8Array[] = [];
    for (let pw = bk.w, ph = bk.h, prev = data; pw > 1 || ph > 1;) {
      const w = Math.max(1, pw >> 1), h = Math.max(1, ph >> 1), m = new Uint8Array(w * h * 4 * layers);
      for (let l = 0; l < layers; l++) {
        const src = l * pw * ph * 4, dst = l * w * h * 4;
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
          const x0 = Math.min(x * 2, pw - 1), x1 = Math.min(x * 2 + 1, pw - 1), y0 = Math.min(y * 2, ph - 1), y1 = Math.min(y * 2 + 1, ph - 1);
          const q = [src + (y0 * pw + x0) * 4, src + (y0 * pw + x1) * 4, src + (y1 * pw + x0) * 4, src + (y1 * pw + x1) * 4], o = dst + (y * w + x) * 4;
          const as = q.map(i => prev[i + 3]), sa = as[0] + as[1] + as[2] + as[3];
          for (let k = 0; k < 3; k++) m[o + k] = weighted[l] && sa > 0 ? Math.round((prev[q[0] + k] * as[0] + prev[q[1] + k] * as[1] + prev[q[2] + k] * as[2] + prev[q[3] + k] * as[3]) / sa) : (prev[q[0] + k] + prev[q[1] + k] + prev[q[2] + k] + prev[q[3] + k] + 2) >> 2;
          m[o + 3] = (sa + 2) >> 2;
        }
      }
      mips.push(m); prev = m; pw = w; ph = h;
    }
    transfer.push(data.buffer, ...mips.map(m => m.buffer as ArrayBuffer));
    return { w: bk.w, h: bk.h, layers, data, mips, names: bi === 0 ? ["(sin textura)"] : bk.imgs.map(i => mats.find(m => m.image === i.u)!.name) };
  });
  const mk = () => ({ pos: [] as number[], uv: [] as number[], col: [] as number[], layer: [] as number[], wrapc: [] as number[], id: [] as number[], idx: [] as number[] });
  const groups = new Map<string, ReturnType<typeof mk>>();
  for (const mesh of result.meshes as { prims: { material: number; index: Uint32Array; attrs: Record<string, Float32Array> }[] }[]) for (const p of mesh.prims) {
    const mt = mats[p.material], loc = mt.image ? where.get(mt.image)! : { b: 0, layer: 0 };
    const key = `${loc.b}|${kindOf(mt)}`;
    const g = groups.get(key) ?? groups.set(key, mk()).get(key)!, base = g.pos.length / 3, n = p.attrs.POSITION.length / 3;
    const mc = mt.color, cu = mt.clampU ? 1 : 0, cv = mt.clampV ? 1 : 0;
    for (let i = 0; i < n; i++) {
      g.pos.push(p.attrs.POSITION[i * 3], p.attrs.POSITION[i * 3 + 1], p.attrs.POSITION[i * 3 + 2]);
      g.uv.push(p.attrs.TEXCOORD_0?.[i * 2] ?? 0, p.attrs.TEXCOORD_0?.[i * 2 + 1] ?? 0);
      const c = p.attrs.COLOR_0; g.col.push((c?.[i * 4] ?? 1) * mc[0], (c?.[i * 4 + 1] ?? 1) * mc[1], (c?.[i * 4 + 2] ?? 1) * mc[2], c?.[i * 4 + 3] ?? 1);
      g.layer.push(loc.layer); g.wrapc.push(cu, cv); g.id.push(p.attrs._ID?.[i] ?? 0);
    }
    for (let t = 0; t < p.index.length; t++) g.idx.push(base + p.index[t]);
  }
  // Colisionador (BVH) construido aquí, en modo indirecto (no reordena los índices) y serializado: el hilo principal no lo calcula.
  const bvhOf = (pos: Float32Array, idx: Uint32Array) => {
    const g = new BufferGeometry(); g.setAttribute("position", new BufferAttribute(pos, 3)); g.setIndex(new BufferAttribute(idx, 1));
    const ser = MeshBVH.serialize(new MeshBVH(g, { indirect: true, maxLeafTris: 12 }), { cloneBuffers: true });
    for (const r of ser.roots) transfer.push(r as ArrayBuffer);
    if (ser.indirectBuffer) transfer.push(ser.indirectBuffer.buffer as ArrayBuffer);
    return ser;
  };
  const out = [...groups].map(([key, g]) => {
    const [b, kind] = key.split("|") as [string, Kind];
    const r = { pos: new Float32Array(g.pos), uv: new Float32Array(g.uv), col: new Float32Array(g.col), layer: new Float32Array(g.layer), wrapc: new Float32Array(g.wrapc), id: new Float32Array(g.id), idx: new Uint32Array(g.idx) };
    const bvh = kind === "opaque" || kind === "mask" ? bvhOf(r.pos, r.idx) : null;
    transfer.push(...Object.values(r).map(a => a.buffer as ArrayBuffer));
    return { array: +b, kind, cutoff: kind === "mask" ? Math.min(...mats.filter(m => kindOf(m) === "mask").map(m => m.cutoff)) : 0, ...r, bvh };
  });
  return { result: { arrays, groups: out, extras: result.extras }, transfer };
}

self.onmessage = async (e: MessageEvent<Req>) => {
  const r = e.data;
  try {
    if (r.kind === "tile") { const { result, transfer } = await packTile(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else if (r.kind === "glb") { const { result, transfer } = await parseGlb(r.url); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result }, transfer); }
    else { const bmp = await createImageBitmap(await (await fetch(r.url)).blob(), { imageOrientation: "none", premultiplyAlpha: "none", colorSpaceConversion: "none" }); (self as unknown as Worker).postMessage({ id: r.id, ok: true, result: bmp }, [bmp]); }
  } catch (err) { (self as unknown as Worker).postMessage({ id: r.id, ok: false, error: String(err) }); }
};
