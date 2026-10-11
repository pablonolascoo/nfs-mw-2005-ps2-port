// Escritor GLB (glTF 2.0 binario) mínimo: mallas indexadas, materiales PBR simples y texturas PNG.
// Convención: los datos del juego son Z-arriba; el nodo raíz rota -90° en X para cumplir glTF (Y-arriba).
export interface GlbPrimitive { positions: Float32Array; normals?: Float32Array; uvs?: Float32Array; colors?: Float32Array; ids?: Float32Array; indices: Uint32Array; material: number }
export interface GlbMesh { name: string; primitives: GlbPrimitive[]; extras?: Record<string, unknown>; matrix?: number[] }
export interface GlbMaterial { name: string; color: [number, number, number, number]; texture?: number; alphaMode?: "OPAQUE" | "MASK" | "BLEND"; doubleSided?: boolean; unlit?: boolean }
export interface GlbImage { name: string; png?: Uint8Array; uri?: string }
export interface GlbNode { name: string; mesh: number; matrix?: number[]; extras?: Record<string, unknown> }

export function writeGlb(meshes: GlbMesh[], materials: GlbMaterial[], images: GlbImage[] = [], rootName = "root", nodes?: GlbNode[]): Uint8Array {
  const chunks: Uint8Array[] = [];
  let byteLength = 0;
  const bufferViews: object[] = [], accessors: object[] = [];
  const push = (data: ArrayBufferView, target?: number) => {
    const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    const pad = (4 - (byteLength % 4)) % 4;
    if (pad) { chunks.push(new Uint8Array(pad)); byteLength += pad; }
    bufferViews.push({ buffer: 0, byteOffset: byteLength, byteLength: bytes.length, ...(target ? { target } : {}) });
    chunks.push(bytes); byteLength += bytes.length;
    return bufferViews.length - 1;
  };
  const acc = (arr: Float32Array | Uint32Array, type: "VEC2" | "VEC3" | "VEC4" | "SCALAR", target: number, minmax = false) => {
    const n = { VEC2: 2, VEC3: 3, VEC4: 4, SCALAR: 1 }[type];
    const view = push(arr, target);
    const a: Record<string, unknown> = { bufferView: view, componentType: arr instanceof Float32Array ? 5126 : 5125, count: arr.length / n, type };
    if (minmax) {
      const mn = Array(n).fill(Infinity), mx = Array(n).fill(-Infinity);
      for (let i = 0; i < arr.length; i++) { const c = i % n; mn[c] = Math.min(mn[c], arr[i]); mx[c] = Math.max(mx[c], arr[i]); }
      a.min = mn; a.max = mx;
    }
    accessors.push(a);
    return accessors.length - 1;
  };
  const gltfMeshes = meshes.map(m => ({
    name: m.name,
    primitives: m.primitives.map(p => ({
      attributes: { POSITION: acc(p.positions, "VEC3", 34962, true), ...(p.normals ? { NORMAL: acc(p.normals, "VEC3", 34962) } : {}), ...(p.uvs ? { TEXCOORD_0: acc(p.uvs, "VEC2", 34962) } : {}), ...(p.colors ? { COLOR_0: acc(p.colors, "VEC4", 34962) } : {}), ...(p.ids ? { _ID: acc(p.ids, "SCALAR", 34962) } : {}) },
      indices: acc(p.indices, "SCALAR", 34963), material: p.material, mode: 4,
    })),
  }));
  const imageDefs = images.map(img => img.uri ? { name: img.name, uri: img.uri } : { name: img.name, mimeType: "image/png", bufferView: push(img.png!) });
  const nodeList = nodes ?? meshes.map((m, i) => ({ name: m.name, mesh: i, matrix: m.matrix, extras: m.extras }));
  const gltf = {
    asset: { version: "2.0", generator: "nfsmw-tools (Rockport Dispatch)" },
    scene: 0,
    scenes: [{ nodes: [0] }],
    nodes: [{ name: rootName, rotation: [-Math.SQRT1_2, 0, 0, Math.SQRT1_2], children: nodeList.map((_, i) => i + 1) }, ...nodeList.map(n => ({ name: n.name, mesh: n.mesh, ...(n.extras ? { extras: n.extras } : {}), ...(n.matrix ? { matrix: n.matrix } : {}) }))],
    meshes: gltfMeshes,
    ...(materials.some(m => m.unlit) ? { extensionsUsed: ["KHR_materials_unlit"] } : {}),
    materials: materials.map(m => ({ name: m.name, ...(m.unlit ? { extensions: { KHR_materials_unlit: {} } } : {}), doubleSided: m.doubleSided ?? true, alphaMode: m.alphaMode ?? "OPAQUE", ...(m.alphaMode === "MASK" ? { alphaCutoff: 0.5 } : {}), pbrMetallicRoughness: { baseColorFactor: m.color, metallicFactor: 0, roughnessFactor: 0.85, ...(m.texture !== undefined ? { baseColorTexture: { index: m.texture } } : {}) } })),
    ...(images.length ? { images: imageDefs, textures: images.map((_, i) => ({ source: i, sampler: 0 })), samplers: [{ magFilter: 9729, minFilter: 9987, wrapS: 10497, wrapT: 10497 }] } : {}),
    accessors, bufferViews, buffers: [{ byteLength }],
  };
  let json = new TextEncoder().encode(JSON.stringify(gltf));
  const jpad = (4 - (json.length % 4)) % 4;
  if (jpad) { const j = new Uint8Array(json.length + jpad).fill(0x20); j.set(json); json = j; }
  const bpad = (4 - (byteLength % 4)) % 4;
  const total = 12 + 8 + json.length + 8 + byteLength + bpad;
  const out = new Uint8Array(total), dv = new DataView(out.buffer);
  dv.setUint32(0, 0x46546c67, true); dv.setUint32(4, 2, true); dv.setUint32(8, total, true);
  dv.setUint32(12, json.length, true); dv.setUint32(16, 0x4e4f534a, true); out.set(json, 20);
  let o = 20 + json.length;
  dv.setUint32(o, byteLength + bpad, true); dv.setUint32(o + 4, 0x004e4942, true); o += 8;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}
