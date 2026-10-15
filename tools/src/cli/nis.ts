// Escenas NIS (cinemáticas con el motor) → map-data/<ID>/nis/ (no se sube a git).
// Uso: bun src/cli/nis.ts <iso> <ID>
//
// Salida:
//   nis/index.json        lista de escenas (de la tabla AnimDirectory de GLOBAL\INGAMEB.BUN), audio NIS, candidatos y resumen
//   nis/<ESCENA>.json     cabecera, duración, actores (coches, policías, personajes), cámaras ICE (claves + muestreo a 30 fps),
//                         eventos (máquina de estados CARP + línea de tiempo), revoluciones del motor (NISREVDATA) y audio
//   nis/<ESCENA>.glb      nodos animados (coches, esqueletos de personajes) y cámaras glTF animadas, Z-arriba bajo un nodo raíz
//                         girado −90° en X (misma convención que los GLB del mundo). Sin mallas: los coches los pone el juego.
// Formatos y etiquetas [V]/[D]/[I]: tools/src/lib/nis.ts y docs/es/23-escenas-nis.md.
import { mkdirSync, writeFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { outDir } from "../lib/paths";
import { parseChunks, walk, type Chunk } from "../lib/bchunk";
import { bStringHash } from "../lib/hash";
import { findSchlClips, parseSchl } from "../lib/microtalk";
import { readSolidListsDeep, type Solid } from "../lib/solid-ps2";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { solidToMesh } from "../lib/mesh-build";
import { encodePng } from "../lib/png";
import {
  parseNisSceneHeader, parseNisEntity, parseAnimBank, parseSkeletons, parseIceGroup, parseIceShakes, parseCarp, parseNisRevData,
  parseAnimDirectory, parseAnimCandidates, parseNisAudioIdx, sampleIceTrack, curvesByBone, NIS_AUDIO_MAP, ICE_SPACES,
  type NisAnim, type NisSkeleton, type IceGroup, type IceTrack, type CarpSequence,
} from "../lib/nis";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/nis.ts <iso> <ID>"); process.exit(1); }
const t0 = performance.now();
const disc = await GameDisc.open(iso);
const out = `${outDir(id)}/nis`;
mkdirSync(out, { recursive: true });
const r4 = (x: number) => Math.round(x * 1e4) / 1e4;
const hx = (h: number) => `0x${(h >>> 0).toString(16).padStart(8, "0")}`;
const sub = (buf: Uint8Array, c: Chunk) => buf.subarray(c.dataOffset, c.dataOffset + c.size);

// ── GLOBAL\INGAMEB.BUN: directorio de escenas, candidatos, cámaras ICE y esqueleto ROOT de los coches ──
const ingame = await disc.readEntry(disc.find("GLOBAL\\INGAMEB.BUN")!);
const igChunks = parseChunks(ingame);
let directory: ReturnType<typeof parseAnimDirectory> = [], candidates: ReturnType<typeof parseAnimCandidates> | null = null, shakes: ReturnType<typeof parseIceShakes> | null = null;
const iceGroups: IceGroup[] = [];
let rootSkeleton: NisSkeleton | undefined;
for (const [c] of walk(igChunks)) {
  if (c.id === 0x00037060) directory = parseAnimDirectory(sub(ingame, c));
  else if (c.id === 0x00037070) candidates = parseAnimCandidates(sub(ingame, c));
  else if (c.id === 0x0003b211) shakes = parseIceShakes(sub(ingame, c));
  else if (c.id === 0x00e34009) rootSkeleton = parseSkeletons(sub(ingame, c)).find(s => s.name === "ROOT");
  else if (((c.id & 0xfffffff0) >>> 0) === 0x8003b200) for (const g of c.children ?? []) if (g.id === 0x0003b210) iceGroups.push(parseIceGroup(sub(ingame, g), c.id & 0xf));
}
const iceByHandle = new Map<number, IceGroup[]>();
for (const g of iceGroups) iceByHandle.set(g.handle, [...(iceByHandle.get(g.handle) ?? []), g]);

// ── Audio NIS: bancos de NISAUDIO.IDX → nº de pista (= audio/escenas/NNN.flac de cli/audio.ts) ──
const bigE = disc.find("SOUND\\STREAMS\\NISAUDIO.BIG"), idxE = disc.find("SOUND\\STREAMS\\NISAUDIO.IDX");
let audioBanks: ReturnType<typeof parseNisAudioIdx> = [];
const clipSeconds: number[] = [];
if (bigE && idxE) {
  const big = await disc.readEntry(bigE);
  const offs = findSchlClips(big);
  for (const o of offs) { const s = parseSchl(big.subarray(o, o + 256)); clipSeconds.push(s && s.sampleRate ? r4(s.numSamples / s.sampleRate) : 0); }
  audioBanks = parseNisAudioIdx(await disc.readEntry(idxE), offs);
}
const audioFor = (scene: string, cameraTrack = 0) => {
  const m = NIS_AUDIO_MAP.find(e => e[0] === scene);
  if (!m) return null;
  const [, kind, bit] = m;
  const bank = audioBanks.find(b => b.event === { start: "NIS_Select_Start", blacklist: "NIS_Select_Blacklist", end: "NIS_Select_End" }[kind]);
  if (!bank) return null;
  // Parámetros del clip: [escena, pista de cámara, sección]; pista 13 = Track00, 0 = Track01 (solo GenericStart usa la pista) [D: QueueNISStream]
  const track = scene === "GenericStart" ? (cameraTrack === 1 ? 0 : 13) : 13;
  const pick = (section: number) => bank.clips.find(c => c.values[0] === bit && c.values[1] === track && (c.values.length < 3 || c.values[2] === section))?.clip ?? -1;
  const full = pick(0), end = pick(2);
  const file = (n: number) => (n >= 0 ? { clip: n, file: `audio/escenas/${String(n).padStart(3, "0")}.flac`, seconds: clipSeconds[n] } : null);
  return { csisEvent: bank.event, sceneBit: bit, complete: file(full), buttonThroughEnd: file(end) };
};

// ── glTF mínimo con animaciones y cámaras ──
const pngCache = new Map<string, Uint8Array>(); // los personajes se repiten entre escenas (ArrestX / ArrestXb)
type GNode = { name: string; children?: number[]; translation?: number[]; rotation?: number[]; scale?: number[]; matrix?: number[]; camera?: number; mesh?: number; extras?: unknown };
class AnimGlb {
  nodes: GNode[] = []; cameras: object[] = []; animations: { name: string; channels: object[]; samplers: object[] }[] = [];
  meshes: object[] = []; materials: object[] = []; textures: object[] = []; images: object[] = []; matByTex = new Map<number, number>();
  bin: Uint8Array[] = []; len = 0; views: object[] = []; accessors: object[] = [];
  node(n: GNode, parent?: number) { this.nodes.push(n); const i = this.nodes.length - 1; if (parent !== undefined) (this.nodes[parent].children ??= []).push(i); return i; }
  view(bytes: Uint8Array) {
    const pad = (4 - (this.len % 4)) % 4; if (pad) { this.bin.push(new Uint8Array(pad)); this.len += pad; }
    this.views.push({ buffer: 0, byteOffset: this.len, byteLength: bytes.byteLength });
    this.bin.push(bytes); this.len += bytes.byteLength;
    return this.views.length - 1;
  }
  acc(arr: Float32Array | Uint32Array, type: "SCALAR" | "VEC2" | "VEC3" | "VEC4", minmax = false) {
    const v = this.view(new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength));
    const n = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[type], a: Record<string, unknown> = { bufferView: v, componentType: arr instanceof Uint32Array ? 5125 : 5126, count: arr.length / n, type };
    if (minmax) { const mn = Array(n).fill(Infinity), mx = Array(n).fill(-Infinity); for (let i = 0; i < arr.length; i++) { mn[i % n] = Math.min(mn[i % n], arr[i]); mx[i % n] = Math.max(mx[i % n], arr[i]); } a.min = mn; a.max = mx; }
    this.accessors.push(a); return this.accessors.length - 1;
  }
  /** Material por textura (PNG incrustado) o gris si no está en el paquete. */
  material(texHash: number | undefined, tex: Map<number, Texture>) {
    const key = texHash ?? -1, got = this.matByTex.get(key);
    if (got !== undefined) return got;
    const t = texHash !== undefined ? tex.get(texHash) : undefined, m: Record<string, unknown> = { name: t?.name ?? "sin_textura", pbrMetallicRoughness: { baseColorFactor: [0.6, 0.6, 0.6, 1], metallicFactor: 0, roughnessFactor: 1 } };
    if (t) {
      const key = `${t.nameHash}:${t.width}x${t.height}`;
      if (!pngCache.has(key)) pngCache.set(key, encodePng(t.rgba, t.width, t.height));
      this.images.push({ name: t.name, mimeType: "image/png", bufferView: this.view(pngCache.get(key)!) });
      this.textures.push({ source: this.images.length - 1 });
      m.pbrMetallicRoughness = { baseColorTexture: { index: this.textures.length - 1 }, metallicFactor: 0, roughnessFactor: 1 };
      if (t.alphaUsage) { m.alphaMode = "MASK"; m.alphaCutoff = 0.5; }
    }
    this.materials.push(m); this.matByTex.set(key, this.materials.length - 1); return this.materials.length - 1;
  }
  mesh(so: Solid, tex: Map<number, Texture>) {
    const m = solidToMesh(so, h => this.material(h, tex));
    this.meshes.push({ name: m.name, primitives: m.primitives.map(p => ({ attributes: { POSITION: this.acc(p.positions, "VEC3", true), ...(p.normals ? { NORMAL: this.acc(p.normals, "VEC3") } : {}), ...(p.uvs ? { TEXCOORD_0: this.acc(p.uvs, "VEC2") } : {}) }, indices: this.acc(p.indices, "SCALAR"), material: p.material, mode: 4 })) });
    return this.meshes.length - 1;
  }
  anim(name: string) { let a = this.animations.find(x => x.name === name); if (!a) { a = { name, channels: [], samplers: [] }; this.animations.push(a); } return a; }
  channel(animName: string, node: number, path: "translation" | "rotation" | "scale", times: Float32Array, values: Float32Array) {
    const a = this.anim(animName);
    a.samplers.push({ input: this.acc(times, "SCALAR", true), output: this.acc(values, path === "rotation" ? "VEC4" : "VEC3"), interpolation: "LINEAR" });
    a.channels.push({ sampler: a.samplers.length - 1, target: { node, path } });
  }
  write(rootName: string) {
    const json = { asset: { version: "2.0", generator: "nfsmw-tools nis.ts" }, scene: 0, scenes: [{ name: rootName, nodes: [0] }], nodes: this.nodes,
      ...(this.cameras.length ? { cameras: this.cameras } : {}), ...(this.meshes.length ? { meshes: this.meshes, materials: this.materials } : {}),
      ...(this.images.length ? { images: this.images, textures: this.textures } : {}), ...(this.animations.length ? { animations: this.animations.filter(a => a.channels.length) } : {}),
      buffers: [{ byteLength: this.len }], bufferViews: this.views, accessors: this.accessors };
    const enc = new TextEncoder().encode(JSON.stringify(json)), jl = (enc.length + 3) & ~3, bl = (this.len + 3) & ~3;
    const outB = new Uint8Array(12 + 8 + jl + 8 + bl), dv = new DataView(outB.buffer);
    dv.setUint32(0, 0x46546c67, true); dv.setUint32(4, 2, true); dv.setUint32(8, outB.length, true);
    dv.setUint32(12, jl, true); dv.setUint32(16, 0x4e4f534a, true); outB.set(enc, 20); outB.fill(0x20, 20 + enc.length, 20 + jl);
    dv.setUint32(20 + jl, bl, true); dv.setUint32(24 + jl, 0x004e4942, true);
    let o = 28 + jl; for (const b of this.bin) { outB.set(b, o); o += b.length; }
    return outB;
  }
}
/** Cuaternión (x,y,z,w) de una base ortonormal dada por columnas. */
function quatFromBasis(x: number[], y: number[], z: number[]) {
  const [m00, m10, m20] = x, [m01, m11, m21] = y, [m02, m12, m22] = z, tr = m00 + m11 + m22;
  let q: number[];
  if (tr > 0) { const s = Math.sqrt(tr + 1) * 2; q = [(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4]; }
  else if (m00 > m11 && m00 > m22) { const s = Math.sqrt(1 + m00 - m11 - m22) * 2; q = [s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s]; }
  else if (m11 > m22) { const s = Math.sqrt(1 + m11 - m00 - m22) * 2; q = [(m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s]; }
  else { const s = Math.sqrt(1 + m22 - m00 - m11) * 2; q = [(m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s]; }
  const n = Math.hypot(...q); return q.map(v => v / n);
}
const norm = (v: number[]) => { const n = Math.hypot(...v) || 1; return v.map(x => x / n); };
const cross = (a: number[], b: number[]) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
/** Orientación glTF de una cámara (mira por −Z local, +Y arriba) en el marco Z-arriba del juego, con giro «dutch» en radianes [I: valores ±0,07]. */
function cameraQuat(eye: number[], look: number[], dutchRad: number) {
  const f = norm(look.map((v, i) => v - eye[i]));
  let r = cross(f, [0, 0, 1]); if (Math.hypot(...r) < 1e-6) r = [1, 0, 0]; r = norm(r);
  let u = cross(r, f);
  const a = dutchRad, c = Math.cos(a), s = Math.sin(a);
  [r, u] = [r.map((v, i) => v * c + u[i] * s), u.map((v, i) => u[i] * c - r[i] * s)];
  return quatFromBasis(r, u, f.map(v => -v));
}

// ── escenas ──
const sceneFiles = directory.length ? directory.flatMap(d => d.files) : [];
type SceneSummary = Record<string, unknown>;
const index: SceneSummary[] = [];
const tally = { scenes: 0, cameraTracks: 0, cameraKeys: 0, anims: 0, animsDecoded: 0, carActors: 0, characters: 0, events: 0, revSets: 0, audio: 0, glb: 0, bytes: 0 };
const chunkBytes: Record<string, number> = {};
const CAR_SLOTS = ["Car1", "Car2", "Car3", "Car4", "Car5", "Car6", "Car7", "Car8", "Cop1", "Cop2", "Cop3", "Cop4", "Cop5", "Cop6", "Cop7", "Cop8"];
const SCENE_TYPES = ["salida de carrera", "escena libre (origen = mundo)", "arresto / NIS con coches del juego", "salida con el jugador en el coche 1", "otra (origen = mundo)"];

for (const path of sceneFiles) {
  const e = disc.find(path);
  if (!e) { index.push({ file: path, missing: true }); continue; }
  const buf = await disc.readEntry(e);
  const chunks = parseChunks(buf);
  let header: ReturnType<typeof parseNisSceneHeader> | null = null;
  const entities: ReturnType<typeof parseNisEntity>[] = [], anims: NisAnim[] = [], skeletons: NisSkeleton[] = [];
  let carp: CarpSequence | null = null, solids = 0, texturePacks = 0;
  const models: Solid[] = [], textures = new Map<number, Texture>();
  for (const [c] of walk(chunks)) {
    const k = c.id.toString(16).padStart(8, "0"); if (!(c.id & 0x80000000)) chunkBytes[k] = (chunkBytes[k] ?? 0) + c.size;
    if (c.id === 0x00037030) header = parseNisSceneHeader(sub(buf, c));
    else if (c.id === 0x00037040) entities.push(parseNisEntity(sub(buf, c)));
    else if (c.id === 0x00e34010) anims.push(...parseAnimBank(sub(buf, c)));
    else if (c.id === 0x00e34009) skeletons.push(...parseSkeletons(sub(buf, c)));
    else if (c.id === 0x0003b811) carp = parseCarp(sub(buf, c));
    else if (c.id === 0x80134000) { solids++; models.push(...readSolidListsDeep(buf, [c])); }
    else if (c.id === 0xb3300000) texturePacks++;
  }
  if (!header) { index.push({ file: path, error: "sin cabecera 0x00037030" }); continue; }
  // Texturas de los personajes: readTexturePack necesita el BUN entero (alineación absoluta de los píxeles a 128 B)
  if (texturePacks) for (const t of readTexturePack(buf).textures) textures.set(t.nameHash, t);
  const name = header.name, duration = r4(header.vanishFrame / 30), start = r4(header.startFrame / 30);
  const byHash = new Map(anims.map(a => [a.nameHash, a] as const));
  tally.scenes++; tally.anims += anims.length; tally.animsDecoded += anims.filter(a => a.channels.every(c => c.decoded)).length;

  // Actores coche/policía: <escena>ZPM_<Ranura>_t/_q (+ _s), hueso 1 del esqueleto ROOT, fotograma = t·30·0,5 [D: CreateCarAnimationControllers]
  const cars = CAR_SLOTS.map((slot, i) => {
    const pre = `${name}ZPM_${slot}`, tA = byHash.get(bStringHash(`${pre}_t`)), qA = byHash.get(bStringHash(`${pre}_q`)), sA = byHash.get(bStringHash(`${pre}_s`));
    if (!tA && !qA) return null;
    const bones = curvesByBone([...(tA?.curves ?? []), ...(qA?.curves ?? []), ...(sA?.curves ?? [])]), b = bones.get(1) ?? bones.get(0);
    const frames = Math.max(tA?.numFrames ?? 0, qA?.numFrames ?? 0);
    const tr = b?.t, q = b?.q;
    return { slot: slot.toLowerCase(), index: i, channel: i < 8 ? `car${i + 1}` : `cop${i - 7}`, anims: [tA?.name, qA?.name, sA?.name].filter(Boolean), frames, fps: 15,
      seconds: r4((frames - 1) / 15), start: tr ? [...tr.slice(0, 3)].map(r4) : null, end: tr ? [...tr.slice(-3)].map(r4) : null,
      startRotation: q ? [...q.slice(0, 4)].map(r4) : null, t: tr, q, s: b?.s };
  }).filter(Boolean) as { slot: string; index: number; channel: string; anims: string[]; frames: number; fps: number; seconds: number; start: number[] | null; end: number[] | null; startRotation: number[] | null; t?: Float32Array; q?: Float32Array; s?: Float32Array }[];
  tally.carActors += cars.length;

  // Personajes (BasicCharacter) y props
  const chars = entities.map(en => {
    const skel = skeletons.find(s => s.nameHash === en.skelHash);
    const skelAnim = en.skelAnimHash ? byHash.get(en.skelAnimHash) : undefined;
    const model = models.find(m => m.nameHash === en.lodHashes[0]);
    return { ...en, model: model?.name ?? null, skeleton: skel?.name ?? null, bones: skel?.bones.length ?? 0, skelAnim: skelAnim?.name ?? null, frames: skelAnim?.numFrames ?? 0,
      fps: 30 * (en.playSpeed || 1) * (skel && skelAnim ? 0.5 : 1), lodHashes: en.lodHashes.map(hx), instanceHash: hx(en.instanceHash), skelHash: en.skelHash ? hx(en.skelHash) : null };
  });
  tally.characters += chars.filter(c => c.type === 1).length;

  // Cámaras ICE del grupo cuyo handle es el hash de la escena
  const groups = iceByHandle.get(header.nameHash) ?? [];
  const cams = groups.flatMap(g => g.tracks.map((tr, ti) => ({ g, tr, ti })));
  const camJson = cams.map(({ g, tr, ti }) => {
    tally.cameraTracks++; tally.cameraKeys += tr.keys.length;
    const n = Math.max(2, Math.round(duration * 30) + 1), samples = [];
    for (let f = 0; f < n; f++) {
      const p = g.context === 0 ? f / (n - 1) : Math.min(1, (f / 30 - tr.start) / (tr.length || duration || 1));
      const s = sampleIceTrack(tr, p);
      samples.push([r4(f / 30), ...s.eye.map(r4), ...s.look.map(r4), r4(s.fovDeg), r4(s.dutch)]);
    }
    return { context: g.contextName, track: ti, name: tr.name, start: r4(tr.start), length: r4(tr.length),
      spaces: [...new Set(tr.keys.flatMap(k => [ICE_SPACES[k.spaceEye], ICE_SPACES[k.spaceLook]]))],
      keys: tr.keys.map(k => ({ ...k, eye: k.eye.map(v => v.map(r4)), look: k.look.map(v => v.map(r4)), parameter: r4(k.parameter), lens: k.lens.map(r4), fovDeg: k.lens.map(l => r4(2 * Math.atan2(15.96, l) * 180 / Math.PI)) })),
      sampleFormat: ["time", "eyeX", "eyeY", "eyeZ", "lookX", "lookY", "lookZ", "fovDeg", "dutch"], samples };
  });

  // Eventos: línea de tiempo suponiendo que todas las acciones arrancan con el estímulo inicial (START) en t = 0 [I]
  const timeline: { time: number; actor: string; action: string; event: string; data: unknown }[] = [];
  if (carp) for (const sys of carp.systems) {
    const init = sys.states.find(s => s.name === sys.initialState);
    for (const r of init?.responses ?? []) {
      const act = carp.actions.find(a => a.name === r.action);
      for (const tm of act?.timed ?? []) for (const ev of tm.events) timeline.push({ time: tm.time, actor: sys.name, action: act!.name, event: ev.name, data: ev.data });
    }
  }
  timeline.sort((a, b) => a.time - b.time);
  tally.events += timeline.length;

  // Revoluciones del motor
  const revE = disc.find(`SOUND\\NISREVDATA\\${name.toUpperCase()}.BIN`);
  const rev = revE ? parseNisRevData(await disc.readEntry(revE)) : null;
  if (rev) tally.revSets += rev.sets.length;
  const audio = audioFor(name);
  // GenericStart tiene audio por pista de cámara (pista 0 → bit 13, pista 1 → bit 0) [V: banco 0x4023]
  if (audio && name === "GenericStart") Object.assign(audio, { cameraTrack1: audioFor(name, 1) });
  if (audio?.complete) tally.audio++;

  const json = {
    disc: id, scene: name, file: path, nameHash: hx(header.nameHash), description: header.description,
    sceneType: header.sceneType, sceneTypeName: SCENE_TYPES[header.sceneType] ?? null,
    origin: header.sceneOriginAtStartLine
      ? "línea de salida / posición de la actividad: matriz = traslación(origen en el suelo) · rotZ(ángulo − 90°) [D: CAnimLocator::GetInitialAnimMatricies]"
      : "mundo (0,0,0): las coordenadas de escena son del mundo [D]",
    coordinates: "Z arriba, metros, espacio de render del juego (como world.json). Sim (Y arriba) = (−y, z, x) [D: NISActivity::GetNISStartLocation]",
    startSeconds: start, duration, haveLayout: header.haveLayout, haveCarAnimation: header.haveCarAnimation, numberOfCars: header.numberOfCars, overlay: header.overlay || null,
    bundle: { solids, texturePacks, models: models.map(m => ({ name: m.name, hash: hx(m.nameHash), strips: m.strips.length, polys: m.numPolys, aabb: [m.aabbMin.map(r4), m.aabbMax.map(r4)] })), textures: [...textures.values()].map(t => `${t.name} ${t.width}×${t.height}`), skeletons: skeletons.map(s => ({ name: s.name, bones: s.bones.map(b => ({ name: b.name, parent: b.parent, t: b.t.map(r4), q: b.q.map(r4), s: b.s.map(r4) })) })) },
    actors: {
      cars: cars.map(({ t, q, s, ...c }) => ({ ...c, track: t ? { t: Array.from(t, r4), q: q ? Array.from(q, r4) : null, s: s ? Array.from(s, r4) : null } : null })),
      characters: chars,
    },
    animations: anims.map(a => ({ name: a.name, frames: a.numFrames, channels: a.channels, warnings: a.warnings.length ? a.warnings : undefined })),
    cameras: camJson,
    events: carp ? { engine: carp.engine, systems: carp.systems, actions: carp.actions.map(a => ({ ...a, tags: a.tags, timed: a.timed.map(t => ({ time: t.time, events: t.events.map(({ raw, ...ev }) => ({ ...ev, raw })) })) })), timeline, warnings: carp.warnings } : null,
    engineRevs: rev ? { file: `SOUND\\NISREVDATA\\${name.toUpperCase()}.BIN`, format: "[tiempo s, RPM, acelerador %] por punto; conjunto 0–7 = car1–8, 8–15 = cop1–8", sets: rev.sets } : null,
    audio,
  };
  const text = JSON.stringify(json);
  await Bun.write(`${out}/${name}.json`, text);
  tally.bytes += text.length;

  // GLB: actores y cámaras animados
  const g = new AnimGlb();
  const root = g.node({ name: `NIS_${name}`, rotation: [-Math.SQRT1_2, 0, 0, Math.SQRT1_2], extras: { scene: name, duration, zUp: true } });
  const sceneNode = g.node({ name: "scene_origin", extras: { note: header.sceneOriginAtStartLine ? "colocar en la línea de salida (ver JSON.origin)" : "origen del mundo" } }, root);
  for (const c of cars) {
    const nd = g.node({ name: c.channel, extras: { slot: c.slot, anims: c.anims } }, sceneNode);
    const times = new Float32Array(c.frames).map((_, i) => i / 15);
    if (c.t) g.channel("actors", nd, "translation", times, c.t);
    if (c.q) g.channel("actors", nd, "rotation", times, c.q);
  }
  for (const ch of chars) {
    const skel = skeletons.find(s => s.name === ch.skeleton);
    const ent = g.node({ name: ch.model ?? `entity_${ch.instanceHash}`, matrix: ch.localMatrix, extras: { lods: ch.lodHashes, skeleton: ch.skeleton, skelAnim: ch.skelAnim } }, sceneNode);
    const so = models.find(m => m.nameHash === parseInt(ch.lodHashes[0], 16));
    if (so) g.node({ name: `${so.name}_bind_pose`, mesh: g.mesh(so, textures), extras: { note: "malla en postura de reposo, sin piel (pesos de huesos sin descifrar)" } }, ent);
    if (!skel) continue;
    const ids = skel.bones.map(b => g.node({ name: b.name, translation: b.t, rotation: b.q, scale: b.s }));
    skel.bones.forEach((b, i) => { if (b.parent >= 0) (g.nodes[ids[b.parent]].children ??= []).push(ids[i]); else (g.nodes[ent].children ??= []).push(ids[i]); });
    const anim = ch.skelAnim ? anims.find(a => a.name === ch.skelAnim) : undefined;
    if (anim) {
      const times = new Float32Array(anim.numFrames).map((_, i) => (ch.playDelay ?? 0) + i / ch.fps);
      for (const [bone, cur] of curvesByBone(anim.curves)) {
        if (bone >= ids.length) continue;
        if (cur.t) g.channel("actors", ids[bone], "translation", times, cur.t.subarray(0, anim.numFrames * 3));
        if (cur.q) g.channel("actors", ids[bone], "rotation", times, cur.q.subarray(0, anim.numFrames * 4));
        if (cur.s) g.channel("actors", ids[bone], "scale", times, cur.s.subarray(0, anim.numFrames * 3));
      }
    }
  }
  for (const cam of camJson) {
    const tr = cams[camJson.indexOf(cam)].tr as IceTrack, world = tr.keys.every(k => k.spaceEye === 1 && k.spaceLook === 1);
    const hfov = cam.samples[0][7] as number, aspect = 4 / 3;
    g.cameras.push({ name: `${cam.context}_${cam.name}`, type: "perspective", perspective: { yfov: 2 * Math.atan(Math.tan(hfov * Math.PI / 360) / aspect), aspectRatio: aspect, znear: 0.5, zfar: 5000 } });
    const nd = g.node({ name: `camera_${cam.context}_${String(cam.track).padStart(2, "0")}`, camera: g.cameras.length - 1, extras: { spaces: cam.spaces, carSpace: cam.spaces.includes("car") || cam.spaces.includes("hybrid") } }, world ? root : sceneNode);
    const n = cam.samples.length, times = new Float32Array(n), pos = new Float32Array(n * 3), rot = new Float32Array(n * 4);
    cam.samples.forEach((s, i) => { times[i] = s[0] as number; pos.set(s.slice(1, 4) as number[], i * 3); rot.set(cameraQuat(s.slice(1, 4) as number[], s.slice(4, 7) as number[], s[8] as number), i * 4); });
    g.channel(`camera_${cam.context}_${String(cam.track).padStart(2, "0")}`, nd, "translation", times, pos);
    g.channel(`camera_${cam.context}_${String(cam.track).padStart(2, "0")}`, nd, "rotation", times, rot);
  }
  if (g.animations.length || g.cameras.length) { await Bun.write(`${out}/${name}.glb`, g.write(name)); tally.glb++; }

  index.push({
    scene: name, file: path, json: `nis/${name}.json`, glb: g.animations.length || g.cameras.length ? `nis/${name}.glb` : null, description: header.description,
    sceneType: header.sceneType, duration, cars: cars.map(c => c.channel), characters: chars.filter(c => c.type === 1).length, cameraTracks: camJson.length,
    events: timeline.length, engineRevs: rev?.sets.length ?? 0, audio: audio?.complete?.file ?? null,
  });
}

// Grupos ICE sin escena (FMV / REPLAY / GENERIC y escenas que no están en el disco)
const used = new Set(index.map(s => (s.scene ? bStringHash(String(s.scene)) : -1)));
const otherGroups = iceGroups.filter(g => !used.has(g.handle)).map(g => ({ context: g.contextName, handle: hx(g.handle), tracks: g.tracks.map(t => ({ name: t.name, keys: t.keys.length, length: r4(t.length), spaces: [...new Set(t.keys.map(k => ICE_SPACES[k.spaceEye]))] })) }));
const sceneByHash = new Map([...NIS_AUDIO_MAP.map(e => e[0]), ...index.filter(s => s.scene).map(s => String(s.scene))].map(n => [bStringHash(n), n] as const));
await Bun.write(`${out}/index.json`, JSON.stringify({
  disc: id, source: "GLOBAL\\INGAMEB.BUN (AnimDirectory 0x00037060, CAnimCandidateData 0x00037070, cámaras ICE 0x8003B200–03) + NIS\\SCENE_*_BUNDLEB.BUN + SOUND\\NISREVDATA + SOUND\\STREAMS\\NISAUDIO.*",
  scenes: index,
  audioBanks: audioBanks.map(b => ({ event: b.event, phrase: `0x${b.phrase.toString(16)}`, clips: b.clips.map(c => ({ clip: c.clip, values: c.values, seconds: clipSeconds[c.clip] })) })),
  candidates: candidates && { ...candidates, moments: candidates.moments.map(m => ({ ...m, scene: sceneByHash.get(m.sceneHash) ?? hx(m.sceneHash) })), special: candidates.special.map(m => ({ ...m, scene: sceneByHash.get(m.sceneHash) ?? hx(m.sceneHash) })) },
  iceGroupsWithoutScene: otherGroups, iceShakes: shakes && { tracks: shakes.tracks.length, bytesRead: shakes.bytesRead, size: shakes.size, names: shakes.tracks.map(t => `${t.name}:${t.keys.length}`) },
  rootSkeleton: rootSkeleton?.bones.map(b => b.name), chunkBytes, tally,
}, null, 1));
console.log(`NIS: ${tally.scenes} escenas · ${tally.cameraTracks} pistas de cámara (${tally.cameraKeys} claves) · ${tally.carActors} coches · ${tally.characters} personajes · ${tally.animsDecoded}/${tally.anims} animaciones · ${tally.events} eventos · ${tally.audio} con audio · ${tally.glb} GLB · ${((performance.now() - t0) / 1000).toFixed(1)} s`);
