// Escenas NIS (cinemáticas con el motor): lectores de los chunks de NIS\SCENE_*_BUNDLEB.BUN, de las cámaras ICE
// (GLOBAL\INGAMEB.BUN), del directorio de escenas, de SOUND\NISREVDATA\*.BIN y del enlace con SOUND\STREAMS\NISAUDIO.*.
// Etiquetas: [V] verificado en bytes de SLES-53559 · [D] decomp (dbalatoni13/nfsmw, fuente o ensamblador) · [I] inferido.
// Documentación: docs/es/23-escenas-nis.md · docs/en/23-nis-scenes.md.
//
// Chunks:
//   0x80037020 NisScene (contenedor) → 0x00037030 cabecera NisScene + descripción, 0x00037040 entidades (personajes/props) [D: AnimScene.hpp]
//   0x00E34010 EAGLAnimations: imagen ELF MIPS reubicable con un EAGL4Anim::AnimBank (símbolo __AnimationBank:::bank) [D+V]
//   0x00E34009 EAGLSkeletons:  imagen ELF con EAGL4Anim::SkeletonData (símbolo __Skeleton:::<nombre>) [D+V]
//   0x0003B811 EventSequence ("CARP"): máquina de estados con acciones temporizadas y listas de eventos [D: tipos EventSeq*] [V]
//   0x8003B200..0x8003B203 + 0x0003B210: grupos de cámaras ICE por contexto (NIS, FMV, REPLAY, GENERIC) [D: ICEData.hpp] [V]
//   0x0003B211 ICEShakeTracks: pistas de vibración de cámara [D]
//   0x00037060 AnimDirectory (escena → BUN) y 0x00037070 CAnimCandidateData, ambos en GLOBAL\INGAMEB.BUN [D] [V]
import { attribHash } from "./vlt";
import { bStringHash } from "./hash";

// ───────────────────────────── utilidades ─────────────────────────────
const cstr = (b: Uint8Array, o: number, max = 1 << 20) => { let s = ""; for (let i = o; i < b.length && i < o + max && b[i]; i++) s += String.fromCharCode(b[i]); return s; };
const view = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
/** Quita el relleno 0x11 de alineación que precede a muchos chunks (GetAlignedData) [V]. */
export function stripPad(b: Uint8Array) { let o = 0; while (o < b.length && b[o] === 0x11) o++; return b.subarray(o); }

// ───────────────────────────── NisScene (0x00037030 / 0x00037040) ─────────────────────────────
/** SceneType: 0 = salida de carrera, 3 = salida con el jugador forzado al coche 1, 2 = arresto (coches del NIS), 1/4 = otras.
 *  Con 0, 2 y 3 el origen de la escena es la línea de salida / posición de la actividad; con 1 y 4 el origen es (0,0,0) [D: CAnimScene::Init]. */
export interface NisSceneHeader { nameHash: number; name: string; description: string; sceneType: number; haveLayout: number; haveCarAnimation: number; numberOfCars: number; startFrame: number; vanishFrame: number; overlay: string; sceneOriginAtStartLine: boolean }
export function parseNisSceneHeader(raw: Uint8Array): NisSceneHeader {
  const b = stripPad(raw), dv = view(b);
  const sceneType = dv.getInt32(0x18, true);
  return {
    nameHash: dv.getUint32(0, true), name: cstr(b, 4, 16), description: cstr(b, 0x40),
    sceneType, haveLayout: dv.getInt32(0x1c, true), haveCarAnimation: dv.getInt32(0x20, true), numberOfCars: dv.getInt32(0x24, true),
    startFrame: dv.getInt32(0x28, true), vanishFrame: dv.getInt32(0x2c, true), overlay: cstr(b, 0x30, 16),
    sceneOriginAtStartLine: sceneType === 0 || sceneType === 2 || sceneType === 3,
  };
}

/** Entidad animada de la escena: personaje (tipo 1, 0x90 B) o prop (tipo 2, 0x60 B) [D: AnimEntity_BasicCharacter.hpp / AnimEntity_Prop.hpp]. */
export interface NisEntity { type: number; typeName: string; instanceHash: number; parentHash: number; playFlags: number; localMatrix: number[]; lodHashes: number[];
  transAnimHash?: number; quatsAnimHash?: number; scaleAnimHash?: number; skelAnimHash?: number; skelHash?: number; playSpeed?: number; playDelay?: number; worldObjectTypeHash?: number; loopStart?: number; loopEnd?: number }
export function parseNisEntity(raw: Uint8Array): NisEntity {
  const b = stripPad(raw), dv = view(b), u = (o: number) => dv.getUint32(o, true);
  const type = u(0);
  const e: NisEntity = { type, typeName: ["none", "character", "prop", "worldAnimNode"][type] ?? `type${type}`, instanceHash: u(4), parentHash: u(8), playFlags: u(0xc),
    localMatrix: Array.from({ length: 16 }, (_, i) => dv.getFloat32(0x10 + 4 * i, true)), lodHashes: [u(0x50), u(0x54), u(0x58), u(0x5c)] };
  if (type === 1 && b.length >= 0x90) Object.assign(e, { transAnimHash: u(0x60), quatsAnimHash: u(0x64), scaleAnimHash: u(0x68), skelAnimHash: u(0x6c), skelHash: u(0x70),
    playSpeed: dv.getFloat32(0x74, true), playDelay: dv.getFloat32(0x78, true), worldObjectTypeHash: u(0x7c), loopStart: u(0x80), loopEnd: u(0x84) });
  return e;
}

// ───────────────────────────── imágenes ELF de EAGL4 ─────────────────────────────
export interface EaglElf { data: Uint8Array; dv: DataView; symbols: { name: string; value: number; size: number }[] }
/** Imagen ELF32 LE (MIPS, ET_REL) con una sección .data, .symtab y .rel.data. Los punteros de .data son desplazamientos dentro
 *  de .data reubicados con R_MIPS_32 contra el símbolo de sección (valor 0) [V: 112 bancos y 29 esqueletos del disco]. */
export function parseEaglElf(raw: Uint8Array): EaglElf {
  const b = stripPad(raw), dv = view(b);
  if (dv.getUint32(0, false) !== 0x7f454c46) throw new Error("EAGL: no es ELF");
  const shoff = dv.getUint32(0x20, true), shentsize = dv.getUint16(0x2e, true), shnum = dv.getUint16(0x30, true), shstrndx = dv.getUint16(0x32, true);
  const secs = Array.from({ length: shnum }, (_, i) => { const s = shoff + i * shentsize;
    return { name: dv.getUint32(s, true), type: dv.getUint32(s + 4, true), off: dv.getUint32(s + 16, true), size: dv.getUint32(s + 20, true), link: dv.getUint32(s + 24, true), info: dv.getUint32(s + 28, true), nm: "" }; });
  for (const s of secs) s.nm = cstr(b, secs[shstrndx].off + s.name);
  const dataSec = secs.findIndex(s => s.nm === ".data"), symSec = secs.find(s => s.type === 2), relSec = secs.find(s => s.type === 9 && s.info === dataSec);
  if (dataSec < 0 || !symSec) throw new Error("EAGL: faltan .data o .symtab");
  const data = new Uint8Array(b.subarray(secs[dataSec].off, secs[dataSec].off + secs[dataSec].size)); // copia: se reubica
  const ddv = view(data);
  const strtab = secs[symSec.link];
  const symbols = Array.from({ length: symSec.size / 16 }, (_, i) => { const s = symSec.off + 16 * i;
    return { name: cstr(b, strtab.off + dv.getUint32(s, true)), value: dv.getUint32(s + 4, true), size: dv.getUint32(s + 8, true) }; });
  if (relSec) for (let r = relSec.off; r < relSec.off + relSec.size; r += 8) {
    const off = dv.getUint32(r, true), info = dv.getUint32(r + 4, true);
    if ((info & 0xff) !== 2) throw new Error(`EAGL: reubicación de tipo ${info & 0xff}`);
    ddv.setUint32(off, (ddv.getUint32(off, true) + symbols[info >>> 8].value) >>> 0, true);
  }
  return { data, dv: ddv, symbols };
}

// ───────────────────────────── esqueletos (0x00E34009) ─────────────────────────────
/** BoneData (0x70 B): S(3) padre Q(4) T(3) izq/der, matriz inversa de base [D: SkeletonData.h]. */
export interface NisBone { name: string; parent: number; s: number[]; q: number[]; t: number[]; leftRight: number; invBase: number[] }
export interface NisSkeleton { name: string; nameHash: number; checksum: number; flags: number; bones: NisBone[] }
export function parseSkeletons(raw: Uint8Array): NisSkeleton[] {
  const { data, dv, symbols } = parseEaglElf(raw);
  const out: NisSkeleton[] = [];
  for (const sk of symbols.filter(s => s.name.startsWith("__Skeleton:::"))) {
    const name = sk.name.slice(13), o = sk.value, n = dv.getInt32(o + 8, true);
    const boneNames = new Map<number, string>();
    // __Bone:::<esqueleto>.<hueso> apunta a un u32 con el índice del hueso [V]
    for (const s of symbols) if (s.name.startsWith(`__Bone:::${name}.`)) boneNames.set(dv.getInt32(s.value, true), s.name.slice(10 + name.length));
    const bones: NisBone[] = [];
    for (let i = 0; i < n; i++) {
      const p = o + 0x10 + i * 0x70, f = (k: number) => dv.getFloat32(p + k, true);
      bones.push({ name: boneNames.get(i) ?? `bone${i}`, s: [f(0), f(4), f(8)], parent: dv.getInt32(p + 0xc, true), q: [f(0x10), f(0x14), f(0x18), f(0x1c)],
        t: [f(0x20), f(0x24), f(0x28)], leftRight: dv.getInt32(p + 0x2c, true), invBase: Array.from({ length: 16 }, (_, k) => f(0x30 + 4 * k)) });
    }
    out.push({ name, nameHash: bStringHash(name), checksum: dv.getUint16(o + 4, true), flags: dv.getUint16(o + 6, true), bones });
  }
  void data;
  return out;
}

// ───────────────────────────── animaciones (0x00E34010) ─────────────────────────────
/** Tipos de AnimMemoryMap [D: AnimTypeId.h]. En las NIS solo aparecen 15 (compuesto), 10, 11, 20 y 21 (y 17 una vez en INGAMEB) [V]. */
export const ANIM_TYPES: Record<number, string> = { 0: "RawPose", 1: "RawEvent", 2: "RawLinear", 3: "Cycle", 10: "DeltaLerp", 11: "DeltaQuat", 12: "KeyLerp", 13: "KeyQuat",
  15: "Compound", 16: "RawState", 17: "DeltaQ", 18: "DeltaQFast", 19: "DeltaSingleQ", 20: "DeltaF3", 21: "DeltaF1", 22: "StatelessQ", 23: "StatelessF3", 24: "CsisEvent", 25: "PoseAnim" };

/** Una curva muestreada por fotograma: `dof` = índice en el búfer SQT (12 floats por hueso: S xyz _, Q xyzw, T xyz _) [D: DeltaChan.cpp «/0xC»] [V]. */
export interface DofCurve { dof: number; width: number; values: Float32Array /* numFrames × width */ }
export interface NisAnim { name: string; nameHash: number; numFrames: number; channels: { type: number; typeName: string; decoded: boolean; dofs: number }[]; curves: DofCurve[]; warnings: string[] }

/** DeltaCompressedData [D: DeltaCompressedData.cpp]: u16 nDofs, u8 bits (4/8/16), pad; DofInfo{min, range, start}[nDofs]; deltas por fotograma.
 *  valor(f) = start + Σ_{i<f} (q_i·range + min). Devuelve nFrames × nDofs. */
function decodeDeltaCompressed(dv: DataView, o: number, numFrames: number): Float32Array {
  const nDofs = dv.getUint16(o, true), bits = dv.getUint8(o + 2);
  const info = o + 4, delta = info + nDofs * 12;
  const out = new Float32Array(numFrames * nDofs);
  const cur = new Float64Array(nDofs);
  for (let d = 0; d < nDofs; d++) cur[d] = dv.getFloat32(info + d * 12 + 8, true);
  out.set(Array.from(cur, x => Math.fround(x)), 0);
  const stride = bits === 16 ? nDofs * 2 : bits === 8 ? nDofs : (nDofs + 1) >> 1;
  for (let f = 1; f < numFrames; f++) {
    const row = delta + (f - 1) * stride;
    for (let d = 0; d < nDofs; d++) {
      const q = bits === 16 ? dv.getUint16(row + 2 * d, true) : bits === 8 ? dv.getUint8(row + d) : ((dv.getUint8(row + (d >> 1)) >> ((d & 1) * 4)) & 15);
      cur[d] += q * dv.getFloat32(info + d * 12 + 4, true) + dv.getFloat32(info + d * 12, true);
    }
    for (let d = 0; d < nDofs; d++) out[f * nDofs + d] = cur[d];
  }
  return out;
}

/** DeltaF1 / DeltaF3 [D: DeltaF1.h, DeltaF3.h, FnDeltaF3.cpp, InitBuffersAsRequired (ensamblador)]: cubos ("bins") de 2^p fotogramas,
 *  cada uno con un valor físico u16 por componente y (2^p − 1) deltas u8. MinRange: físico = q·range/65535 + min;
 *  delta = q·range·2·qRange/65535/255 + range·(2·qMin/65535 − 1). Con mTimes ≠ 0 son claves en esos tiempos (fotograma). */
function decodeDeltaF(dv: DataView, o: number, comps: 1 | 3, warnings: string[]): { dofs: number[]; frames: number; times: number[] | null; values: Float32Array; consts: { dof: number; v: number[] }[] } {
  const dofPtr = dv.getUint32(o + 4, true), timesPtr = dv.getUint32(o + 8, true), numKeys = dv.getUint16(o + 0xc, true), numBones = dv.getUint16(o + 0xe, true);
  const pow = dv.getUint8(o + 0x10), numConst = dv.getUint8(o + 0x11);
  const binLen = 1 << pow, infoSize = comps === 3 ? 0x24 : 0xc, physSize = 2 * comps * numBones, frameDelta = comps * numBones;
  const info = o + 0x14, binsStart = info + numBones * infoSize;
  const binSize = (physSize + (binLen - 1) * frameDelta + 1) & ~1;
  const mr: number[][] = []; // por componente: [physMin, physRange, deltaMin, deltaRange]
  for (let b = 0; b < numBones; b++) for (let c = 0; c < comps; c++) {
    const p = info + b * infoSize;
    const physMin = dv.getFloat32(p + 4 * c, true), physRange = dv.getFloat32(p + 4 * comps + 4 * c, true);
    const qMin = dv.getUint16(p + 8 * comps + 2 * c, true), qRange = dv.getUint16(p + 10 * comps + 2 * c, true);
    const K1 = Math.fround(1 / 65535), K2 = Math.fround(1 / 255);
    mr.push([physMin, physRange * K1, (qMin * K1 * 2) * physRange - physRange, (qRange * K1 * 2) * physRange * K2]);
  }
  const values = new Float32Array(numKeys * numBones * comps);
  for (let k = 0; k < numKeys; k++) {
    const bin = binsStart + (k >> pow) * binSize, di = k & (binLen - 1);
    for (let j = 0; j < numBones * comps; j++) {
      let v = dv.getUint16(bin + 2 * j, true) * mr[j][1] + mr[j][0];
      for (let i = 0; i < di; i++) v += dv.getUint8(bin + physSize + i * frameDelta + j) * mr[j][3] + mr[j][2];
      values[k * numBones * comps + j] = v;
    }
  }
  const dofs = Array.from({ length: numBones }, (_, i) => dv.getUint16(dofPtr + 2 * i, true));
  const times = timesPtr ? [0, ...Array.from({ length: numKeys - 1 }, (_, i) => dv.getUint16(timesPtr + 2 * i, true))] : null;
  // Huesos constantes: tras el último cubo, u16 índices SQT + floats alineados a 4 [D: GetConstBoneIdx]
  const consts: { dof: number; v: number[] }[] = [];
  if (numConst) {
    const fullBins = numKeys >> pow, rem = numKeys & (binLen - 1);
    let s = binsStart + fullBins * binSize;
    if (rem > 0) s = (s + physSize + (rem - 1) * frameDelta + 1) & ~1;
    if (numBones === 0) s = (s + 1) & ~1;
    let f = (s + 2 * numConst + 3) & ~3;
    for (let i = 0; i < numConst; i++) { consts.push({ dof: dv.getUint16(s + 2 * i, true), v: Array.from({ length: comps }, (_, c) => dv.getFloat32(f + 4 * c, true)) }); f += 4 * comps; }
  }
  if (times && times.some((t, i) => i && t <= times[i - 1])) warnings.push("DeltaF: tiempos de clave no crecientes");
  return { dofs, frames: times ? times[times.length - 1] + 1 : numKeys, times, values, consts };
}

/** Remuestrea claves (tiempos en fotogramas) a todos los fotogramas por interpolación lineal (como FnDeltaF*::EvalSQT). */
function resampleKeys(times: number[], vals: Float32Array, width: number, frames: number): Float32Array {
  const out = new Float32Array(frames * width);
  let k = 0;
  for (let f = 0; f < frames; f++) {
    while (k < times.length - 2 && times[k + 1] <= f) k++;
    const t0 = times[k], t1 = times[Math.min(k + 1, times.length - 1)], a = t1 > t0 ? Math.min(1, Math.max(0, (f - t0) / (t1 - t0))) : 0;
    for (let c = 0; c < width; c++) out[f * width + c] = vals[k * width + c] + (vals[Math.min(k + 1, times.length - 1) * width + c] - vals[k * width + c]) * a;
  }
  return out;
}

/** Banco de animaciones de un chunk 0x00E34010. Decodifica DeltaLerp (10), DeltaQuat (11), DeltaF3 (20), DeltaF1 (21);
 *  los demás tipos se listan sin curvas. */
export function parseAnimBank(raw: Uint8Array): NisAnim[] {
  const { dv, symbols } = parseEaglElf(raw);
  const out: NisAnim[] = [];
  for (const sym of symbols.filter(s => s.name.startsWith("__AnimationBank:::"))) {
    const bo = sym.value, n = dv.getInt32(bo + 4, true), anims = dv.getUint32(bo + 16, true), names = dv.getUint32(bo + 20, true);
    for (let i = 0; i < n; i++) {
      const a = dv.getUint32(anims + 4 * i, true);
      let name = ""; for (let p = dv.getUint32(names + 4 * i, true); dv.getUint8(p); p++) name += String.fromCharCode(dv.getUint8(p));
      const type = dv.getUint16(a, true);
      const anim: NisAnim = { name, nameHash: bStringHash(name), numFrames: 0, channels: [], curves: [], warnings: [] };
      const chans = type === 15 ? Array.from({ length: dv.getUint16(a + 8, true) }, (_, c) => dv.getUint32(a + 12 + 4 * c, true)) : [a];
      if (type === 15) anim.numFrames = dv.getUint16(a + 10, true);
      for (const ca of chans) {
        const t = dv.getUint16(ca, true);
        const ch = { type: t, typeName: ANIM_TYPES[t] ?? `type${t}`, decoded: false, dofs: 0 };
        if (t === 10 || t === 11) {
          const frames = dv.getUint16(ca + 8, true), data = dv.getUint32(ca + 4, true), w = t === 11 ? 4 : 1;
          const vals = decodeDeltaCompressed(dv, data, frames), nd = dv.getUint16(data, true);
          for (let k = 0; k < nd / w; k++) {
            const dof = dv.getUint16(ca + 10 + 2 * k, true), v = new Float32Array(frames * w);
            for (let f = 0; f < frames; f++) for (let c = 0; c < w; c++) v[f * w + c] = vals[f * nd + k * w + c];
            anim.curves.push({ dof, width: w, values: v });
          }
          ch.decoded = true; ch.dofs = nd; anim.numFrames ||= frames;
        } else if (t === 20 || t === 21) {
          const w = t === 20 ? 3 : 1, r = decodeDeltaF(dv, ca, w, anim.warnings);
          const frames = anim.numFrames || r.frames;
          const full = r.times ? resampleKeys(r.times, r.values, r.dofs.length * w, frames) : r.values;
          for (let k = 0; k < r.dofs.length; k++) {
            const v = new Float32Array(frames * w);
            for (let f = 0; f < frames; f++) for (let c = 0; c < w; c++) v[f * w + c] = full[Math.min(f, full.length / (r.dofs.length * w) - 1) * r.dofs.length * w + k * w + c];
            anim.curves.push({ dof: r.dofs[k], width: w, values: v });
          }
          for (const c of r.consts) { const v = new Float32Array(frames * w); for (let f = 0; f < frames; f++) v.set(c.v, f * w); anim.curves.push({ dof: c.dof, width: w, values: v }); }
          ch.decoded = true; ch.dofs = (r.dofs.length + r.consts.length) * w;
        } else anim.warnings.push(`canal ${ANIM_TYPES[t] ?? t} sin decodificar`);
        anim.channels.push(ch);
      }
      out.push(anim);
    }
  }
  return out;
}

/** Agrupa las curvas de una o varias animaciones por hueso: {bone → {s?, q?, t?}} con valores por fotograma. */
export function curvesByBone(curves: DofCurve[]) {
  const bones = new Map<number, { s?: Float32Array; q?: Float32Array; t?: Float32Array; extra: DofCurve[] }>();
  for (const c of curves) {
    const bone = Math.floor(c.dof / 12), slot = c.dof % 12;
    const e = bones.get(bone) ?? { extra: [] }; bones.set(bone, e);
    if (slot === 4 && c.width === 4) e.q = c.values;
    else if (slot === 8 && c.width === 3) e.t = c.values;
    else if (slot === 0 && c.width === 3) e.s = c.values;
    else e.extra.push(c);
  }
  // Componentes sueltos (DeltaLerp de 1 en 1) → vectores
  for (const [, e] of bones) {
    const pick = (base: number, w: number) => {
      const parts = Array.from({ length: w }, (_, c) => e.extra.find(x => x.width === 1 && x.dof % 12 === base + c));
      if (!parts.some(Boolean)) return undefined;
      const n = Math.max(...parts.map(p => p?.values.length ?? 0)), v = new Float32Array(n * w);
      for (let f = 0; f < n; f++) for (let c = 0; c < w; c++) v[f * w + c] = parts[c] ? parts[c]!.values[Math.min(f, parts[c]!.values.length - 1)] : (base === 0 ? 1 : 0);
      e.extra = e.extra.filter(x => !parts.includes(x));
      return v;
    };
    e.t ??= pick(8, 3); e.s ??= pick(0, 3);
    if (!e.q) { const q = pick(4, 4); if (q) e.q = q; }
  }
  return bones;
}

// ───────────────────────────── cámaras ICE (0x8003B20x / 0x0003B210) ─────────────────────────────
export const ICE_CONTEXTS = ["NIS", "FMV", "REPLAY", "GENERIC"] as const;
export const ICE_SPACES = ["car", "world", "hybrid", "scene"] as const;
/** ICEData (0x84 B) [D: ICEData.hpp] [V]: una clave = un tramo [fParameter, fParameter siguiente] con extremos 0 y 1. */
export interface IceKey {
  type: number; smooth: number; cubicEye: number; cubicLook: number; spaceEye: number; spaceLook: number; constrainToCars: number; constrainToWorld: number;
  ignoreOrientation: number; carSpaceLag: number; overlay: number; shakeType: number; parameter: number; tangentLength: [number, number];
  eye: [number[], number[]]; look: [number[], number[]]; dutch: [number, number]; lens: [number, number]; nearClip: [number, number];
  noiseAmplitude: [number, number]; noiseFrequency: [number, number]; focalDistance: [number, number]; aperture: [number, number]; letterbox: [number, number]; simSpeed: [number, number];
}
export interface IceTrack { name: string; start: number; length: number; keys: IceKey[] }
export interface IceGroup { context: number; contextName: string; handle: number; tracks: IceTrack[] }

/** Grupo 0x0003B210: u32 handle (hash de la escena para NIS = NisScene.mSceneNameHash), u32 nº de pistas y, por pista,
 *  la imagen de ICETrack sin el puntero al grupo: siguiente, anterior, grupo, Start, Length, s16 nKeys, s8, char[14] nombre,
 *  y nKeys × ICEData (0x84) desde +0x28 [V: los tamaños cuadran en los 85 grupos de INGAMEB]. */
export function parseIceGroup(raw: Uint8Array, context: number): IceGroup {
  const dv = view(raw), handle = dv.getUint32(0, true), n = dv.getUint32(4, true);
  const tracks: IceTrack[] = [];
  let o = 8;
  for (let t = 0; t < n; t++) {
    const nKeys = dv.getInt16(o + 0x14, true);
    const tr: IceTrack = { name: cstr(raw, o + 0x17, 14), start: dv.getFloat32(o + 0xc, true), length: dv.getFloat32(o + 0x10, true), keys: [] };
    for (let k = 0; k < nKeys; k++) {
      const p = o + 0x28 + k * 0x84, f = (x: number) => dv.getFloat32(p + x, true), u8 = (x: number) => raw[p + x];
      const pair = (x: number): [number, number] => [f(x), f(x + 4)];
      tr.keys.push({ type: u8(0), smooth: u8(1), cubicEye: u8(2), cubicLook: u8(3), spaceEye: u8(4), spaceLook: u8(5), constrainToCars: u8(6), constrainToWorld: u8(7),
        ignoreOrientation: u8(8), carSpaceLag: u8(9), overlay: u8(0xa), shakeType: dv.getUint32(p + 0xc, true), parameter: f(0x10), tangentLength: pair(0x14),
        eye: [[f(0x1c), f(0x20), f(0x24)], [f(0x28), f(0x2c), f(0x30)]], look: [[f(0x34), f(0x38), f(0x3c)], [f(0x40), f(0x44), f(0x48)]],
        dutch: pair(0x4c), lens: pair(0x54), nearClip: pair(0x5c), noiseAmplitude: pair(0x64), noiseFrequency: pair(0x6c), focalDistance: pair(0x74),
        aperture: [u8(0x7c), u8(0x7d)], letterbox: [u8(0x7e), u8(0x7f)], simSpeed: [u8(0x80), u8(0x81)] });
    }
    o += 0x28 + nKeys * 0x84;
    tracks.push(tr);
  }
  if (o !== raw.length) throw new Error(`ICE: grupo ${handle.toString(16)} ocupa ${o} B de ${raw.length}`);
  return { context, contextName: ICE_CONTEXTS[context] ?? `ctx${context}`, handle, tracks };
}

/** Pista de vibración 0x0003B211: imagen de ICEShakeGroup: u32 nº de pistas, y por pista siguiente/anterior/grupo,
 *  s16 nKeys, s8, char[14], hasta 120 ICEShakeData {q[3], p[3]} [D: ICEData.hpp]. Se lee sin garantías [I]. */
export function parseIceShakes(raw: Uint8Array) {
  const dv = view(raw), n = dv.getUint32(0, true), out: { name: string; keys: number[][] }[] = [];
  let o = 4;
  for (let t = 0; t < n && o + 0x20 <= raw.length; t++) {
    const nKeys = dv.getInt16(o + 0xc, true), keys: number[][] = [];
    for (let k = 0; k < nKeys; k++) keys.push(Array.from({ length: 6 }, (_, c) => dv.getFloat32(o + 0x20 + k * 0x18 + 4 * c, true)));
    out.push({ name: cstr(raw, o + 0xf, 14), keys });
    o += 0x20 + nKeys * 0x18;
  }
  return { tracks: out, bytesRead: o, size: raw.length };
}

/** Lente (mm) → ángulo de visión: 2·atan(15.96 / lente) [D: ConvertLensLengthToFovAngle, constante 0x417F5C2A]. Horizontal [I]. */
export const lensToFovDeg = (mm: number) => 2 * Math.atan2(15.96, mm) * 180 / Math.PI;

/** Hermite como ICE::Cubic1D [D: MakeCoeffs/GetVal]: v0, pendiente s0, v1, pendiente s1, t∈[0,1]. */
const hermite = (v0: number, s0: number, v1: number, s1: number, t: number) => {
  const d = v1 - v0, a = s0 + s1 - 2 * d, b = 3 * d - s1 - 2 * s0;
  return ((a * t + b) * t + s0) * t + v0;
};
const intervalEnd = (tr: IceTrack, k: number) => (k + 1 < tr.keys.length ? tr.keys[k + 1].parameter : 1);
const eq = (a: number[], b: number[]) => a.every((x, i) => Math.abs(x - b[i]) < 1e-5);

/** Pendientes en un extremo (n = 0 inicio, 1 final) como ICEManager::GetSlope [D: ensamblador 0x17d070]:
 *  si el vecino comparte ese extremo, mezcla las diferencias propias y del vecino ponderadas por la longitud de los tramos. */
function iceSlopes(tr: IceTrack, k: number, n: 0 | 1) {
  const c = tr.keys[k], tl = c.tangentLength[n];
  const diff = (key: IceKey) => ({ eye: key.eye[1].map((x, i) => x - key.eye[0][i]), look: key.look[1].map((x, i) => x - key.look[0][i]), dutch: key.dutch[1] - key.dutch[0], lens: key.lens[1] - key.lens[0] });
  if (!c.type) return { eye: [0, 0, 0], look: [0, 0, 0], dutch: 0, lens: 0 };
  const own = diff(c);
  const nk = n === 0 ? k - 1 : k + 1, nb = tr.keys[nk];
  const shared = nb && nb.type && eq(c.eye[n], nb.eye[1 - n]) && eq(c.look[n], nb.look[1 - n]) && Math.abs(c.dutch[n] - nb.dutch[1 - n]) < 1e-5 && Math.abs(c.lens[n] - nb.lens[1 - n]) < 1e-5;
  if (!shared) return { eye: own.eye.map(x => x * tl), look: own.look.map(x => x * tl), dutch: own.dutch * tl, lens: own.lens * tl };
  const cs = intervalEnd(tr, k) - c.parameter, ns = intervalEnd(tr, nk) - nb.parameter, nbd = diff(nb);
  let wn = cs / (cs + ns); const wc = (1 - wn) * tl;
  if (ns > 0) wn *= cs / ns;
  wn *= tl;
  return { eye: own.eye.map((x, i) => nbd.eye[i] * wn + x * wc), look: own.look.map((x, i) => nbd.look[i] * wn + x * wc), dutch: nbd.dutch * wn + own.dutch * wc, lens: nbd.lens * wn + own.lens * wc };
}

export interface CameraSample { t: number; key: number; eye: number[]; look: number[]; dutch: number; lens: number; fovDeg: number; nearClip: number; focalDistance: number; letterbox: number; simSpeed: number; spaceEye: number; spaceLook: number }
/** Evalúa una pista en el parámetro p∈[0,1] (NIS: p = tiempo / duración de la escena [D: ICETrack::GetParameter]).
 *  Dentro del tramo: t local lineal; ojo y mirada Hermite si bCubicEye/bCubicLook, si no lineal; giro y lente Hermite si bCubicEye
 *  [D: ICEMover::GetEye/GetLook/GetDutch/GetFOV + SetDesired]. Ruido, sacudidas y espacios de coche no se aplican. */
export function sampleIceTrack(tr: IceTrack, p: number): CameraSample {
  p = Math.min(1, Math.max(0, p));
  let k = 0; while (k + 1 < tr.keys.length && tr.keys[k + 1].parameter <= p) k++;
  const c = tr.keys[k], s = c.parameter, e = intervalEnd(tr, k);
  const t = Math.abs(e - s) > 1e-4 ? (p - s) / (e - s) : 0;
  const s0 = iceSlopes(tr, k, 0), s1 = iceSlopes(tr, k, 1);
  const vec = (v: [number[], number[]], a: number[], b: number[], cubic: number) => v[0].map((x, i) => (cubic ? hermite(x, a[i], v[1][i], b[i], t) : x + (v[1][i] - x) * t));
  const lin = (v: [number, number]) => v[0] + (v[1] - v[0]) * t;
  // La lente se interpola en ángulo (FovCubicInit convierte lente y pendiente a FOV) [D]
  const fov0 = lensToFovDeg(c.lens[0]), fov1 = lensToFovDeg(c.lens[1]);
  const dfov = (lens: number, slope: number) => (lensToFovDeg(lens + slope * 0.01) - lensToFovDeg(lens)) * 100;
  const fovDeg = c.cubicEye ? hermite(fov0, dfov(c.lens[0], s0.lens), fov1, dfov(c.lens[1], s1.lens), t) : fov0 + (fov1 - fov0) * t;
  return {
    t: p, key: k, eye: vec(c.eye, s0.eye, s1.eye, c.cubicEye), look: vec(c.look, s0.look, s1.look, c.cubicLook),
    dutch: c.cubicEye ? hermite(c.dutch[0], s0.dutch, c.dutch[1], s1.dutch, t) : lin(c.dutch), lens: 15.96 / Math.tan(fovDeg * Math.PI / 360), fovDeg,
    nearClip: lin(c.nearClip), focalDistance: lin(c.focalDistance), letterbox: lin(c.letterbox), simSpeed: lin(c.simSpeed) / 100, spaceEye: c.spaceEye, spaceLook: c.spaceLook,
  };
}

// ───────────────────────────── secuencias de eventos "CARP" (0x0003B811) ─────────────────────────────
/** Datos fijos de los eventos que aparecen en las NIS: nombre → campos (desplazamiento: tipo nombre) [D: Generated/Events/*.hpp].
 *  El id del evento es attribHash("E" + nombre) [V: los 33 tipos encontrados se resuelven]. */
const EVENT_FIELDS: Record<string, [number, "u32" | "i32" | "f32" | "str" | "hash", string][]> = {
  ENISNeutralRev: [[4, "u32", "on"], [8, "f32", "throttle"], [0xc, "f32", "speed"]], ENISBrakelock: [[4, "u32", "front"], [8, "u32", "rear"]],
  ENISCarShake: [[4, "f32", "shake"], [8, "f32", "rate"], [0xc, "f32", "ramp"], [0x10, "f32", "time"]], ENISBurnout: [[4, "f32", "speed"]], ECameraPhotoFinish: [],
  ENISNitro: [[4, "u32", "on"]], ENISMotionBlur: [[4, "i32", "enable"]], ENISCarRoll: [[4, "f32", "roll"], [8, "f32", "time"]], ENISCarPitch: [[4, "f32", "pitch"], [8, "f32", "time"]],
  ENISCopCarDoors: [[4, "i32", "door"], [8, "f32", "pos"], [0xc, "f32", "animLength"], [0x10, "f32", "endPos"]], ENISPixelate: [[4, "i32", "enable"], [8, "f32", "width"], [0xc, "f32", "height"]],
  ENISOverlayMessage: [[4, "str", "overlayName"], [8, "str", "overlayMessage"]], ENISLights: [[4, "u32", "copLights"], [8, "u32", "headLights"]],
  ENISHideCharacter: [[4, "str", "animModelName"], [8, "i32", "show"]], ENISDetach: [[4, "f32", "speed"]], ENISRain: [[4, "f32", "rainIntensity"]],
  EPlayObjectEffect: [[4, "str", "effect"], [8, "hash", "position"], [0xc, "f32", "intensity"], [0x10, "hash", "id"], [0x14, "u32", "tracking"], [0x18, "u32", "allowHiddenSpawn"]],
  ENISReattach: [[4, "i32", "repairDamage"]], ENISAeroDynamics: [[4, "f32", "aerodynamics"]], EStopObjectEffect: [[4, "hash", "id"]],
  ESpawnExplosion: [[4, "hash", "position"], [8, "f32", "speed"], [0xc, "f32", "radius"], [0x10, "f32", "startRadius"], [0x14, "u32", "effectThis"], [0x18, "u32", "doesDamage"], [0x1c, "u32", "includePlayers"], [0x20, "u32", "excludeVehicles"], [0x24, "u32", "excludeSmackables"]],
  ENISVisualLook: [[4, "f32", "desaturation"], [8, "f32", "colourBloom"], [0xc, "f32", "bleachFactor"], [0x10, "i32", "useHDR"], [0x14, "f32", "facingScale"], [0x18, "f32", "grazingScale"]],
  ENISTimeOfDay: [[4, "f32", "timeOfDay"], [8, "f32", "updateRate"], [0xc, "f32", "sunAzimuth"], [0x10, "f32", "timeOfDayOvercast"]], ENISSteering: [[4, "f32", "degrees"], [8, "f32", "blendWeight"]],
  ENISNukeSmack: [[4, "f32", "x"], [8, "f32", "y"], [0xc, "f32", "z"], [0x10, "f32", "radius"]], ECellCall: [[4, "i32", "id"]], ENISRoadNoise: [[4, "i32", "disableRoadNoise"]],
  ENISPlayEffect: [[4, "str", "effect"], [8, "f32", "x"], [0xc, "f32", "y"], [0x10, "f32", "z"], [0x14, "f32", "magnitudeX"], [0x18, "f32", "magnitudeY"], [0x1c, "f32", "magnitudeZ"]],
  ENISStopEffects: [], EDDaySpeech: [], ENISCarDamageReset: [], ENISWolrdGeometry: [[4, "str", "sceneryGroupName"], [8, "i32", "enable"]], ENISScreenFlash: [[4, "f32", "length"]],
};
const EVENT_BY_ID = new Map(Object.keys(EVENT_FIELDS).map(n => [attribHash(n), n] as const));

export interface CarpEvent { id: number; name: string; data: Record<string, number | string>; raw: string }
export interface CarpAction { name: string; duration: number; tags: { tag: string; events: CarpEvent[] }[]; timed: { time: number; events: CarpEvent[] }[] }
export interface CarpState { name: string; responses: { stimulus: string; endState: string; action: string | null }[] }
export interface CarpSystem { name: string; initialState: string; defaultState: string; states: CarpState[] }
export interface CarpSequence { engine: string; systems: CarpSystem[]; actions: CarpAction[]; strings: string[]; entryTypes: Record<string, number>; warnings: string[] }

/** Contenedor CARP [V]: cabecera bChunkCarpHeader (16 B: tamaño, sección, flags, dirección), "PRAC" {u32 ?, u32 nº de entradas + 1, u32 1},
 *  "srtS" {u16 ?, u16 bytes de texto, u32 nº de cadenas, u32 desplazamiento desde "srtS"}, y entradas de 16 B
 *  {u16 índice, char[2] tipo, u8 3, u24 tamaño, u32 hash del nombre (attribHash), u32 desplazamiento relativo a la propia entrada}.
 *  Tipos: "Ee" EventSeqEngine, "Se" EventSeqSystem, "Te" EventSeqState, "Ae" EventSeqAction, "le" EventList, "Ni" nombre del motor, "Sc" cadena de un evento.
 *  Las referencias dentro de los datos son {u16 índice, char[2] tipo} (las resuelve CarpResolver al cargar). */
export function parseCarp(raw: Uint8Array): CarpSequence {
  const b = stripPad(raw), dv = view(b), warnings: string[] = [];
  const P = 0x10;
  if (cstr(b, P, 4) !== "PRAC") throw new Error("CARP: falta PRAC");
  const nEnt = dv.getUint32(P + 8, true) - 1, S = P + 16;
  if (cstr(b, S, 4) !== "srtS") throw new Error("CARP: falta srtS");
  const nStr = dv.getUint32(S + 8, true), strOff = dv.getUint32(S + 12, true);
  const strings: string[] = []; let so = S + strOff;
  for (let i = 0; i < nStr; i++) { const s = cstr(b, so); strings.push(s); so += s.length + 1; }
  const names = new Map(strings.map(s => [attribHash(s), s] as const));
  const nm = (h: number) => names.get(h) ?? `0x${h.toString(16).padStart(8, "0")}`;
  const E = S + 16;
  const ents = Array.from({ length: nEnt }, (_, i) => { const e = E + 16 * i;
    return { idx: dv.getUint16(e, true), type: cstr(b, e + 2, 2), size: dv.getUint32(e + 4, true) >>> 8, hash: dv.getUint32(e + 8, true), at: e + dv.getUint32(e + 12, true) }; });
  const entryTypes: Record<string, number> = {};
  for (const e of ents) entryTypes[e.type] = (entryTypes[e.type] ?? 0) + 1;
  const byRef = new Map(ents.map(e => [`${e.type}${e.idx}`, e] as const));
  const ref = (o: number) => byRef.get(`${cstr(b, o + 2, 2)}${dv.getUint16(o, true)}`);
  const events = (le: ReturnType<typeof ref>): CarpEvent[] => {
    if (!le) return [];
    const n = dv.getUint32(le.at, true), out: CarpEvent[] = [];
    for (let k = 0; k < n; k++) {
      const r = le.at + 16 + 16 * k, id = dv.getUint32(r, true), size = dv.getUint32(r + 4, true), d = r + dv.getUint32(r + 8, true);
      const name = EVENT_BY_ID.get(id) ?? `0x${id.toString(16)}`, data: Record<string, number | string> = {};
      if (dv.getUint32(d, true) !== id) warnings.push(`${name}: el id del dato no coincide`);
      for (const [off, ty, field] of EVENT_FIELDS[name] ?? []) {
        if (off + 4 > size) continue;
        const v = dv.getUint32(d + off, true);
        data[field] = ty === "f32" ? +dv.getFloat32(d + off, true).toFixed(5) : ty === "i32" ? dv.getInt32(d + off, true)
          : ty === "str" ? (ref(d + off)?.type === "Sc" ? cstr(b, ref(d + off)!.at) : `0x${v.toString(16)}`)
          : ty === "hash" ? nm(v) : v;
      }
      out.push({ id, name, data, raw: Buffer.from(b.subarray(d, d + size)).toString("hex") });
    }
    return out;
  };
  const actions: CarpAction[] = ents.filter(e => e.type === "Ae").map(e => {
    const o = e.at, nTags = dv.getUint32(o + 4, true), nTimes = dv.getUint32(o + 8, true);
    const tagsAt = o + 16, timesAt = tagsAt + 4 * nTags, listsAt = timesAt + 4 * nTimes;
    return { name: nm(dv.getUint32(o, true)), duration: +dv.getFloat32(o + 12, true).toFixed(4),
      tags: Array.from({ length: nTags }, (_, i) => ({ tag: nm(dv.getUint32(tagsAt + 4 * i, true)), events: events(ref(listsAt + 4 * i)) })),
      timed: Array.from({ length: nTimes }, (_, i) => ({ time: +dv.getFloat32(timesAt + 4 * i, true).toFixed(4), events: events(ref(listsAt + 4 * (nTags + i))) })) };
  });
  const stateOf = (e: ReturnType<typeof ref>): CarpState => {
    if (!e) return { name: "?", responses: [] };
    const n = dv.getUint32(e.at, true), stim = e.at + 8, resp = stim + 4 * n;
    return { name: nm(e.hash), responses: Array.from({ length: n }, (_, i) => {
      const a = ref(resp + 8 * i + 4);
      return { stimulus: nm(dv.getUint32(stim + 4 * i, true)), endState: nm(dv.getUint32(resp + 8 * i, true)), action: a ? nm(a.hash) : null };
    }) };
  };
  const systems: CarpSystem[] = ents.filter(e => e.type === "Se").map(e => {
    const n = dv.getUint32(e.at + 8, true), ids = e.at + 12, refs = ids + 4 * n;
    return { name: nm(e.hash), initialState: nm(dv.getUint32(e.at, true)), defaultState: nm(dv.getUint32(e.at + 4, true)),
      states: Array.from({ length: n }, (_, i) => stateOf(ref(refs + 4 * i))) };
  });
  const eng = ents.find(e => e.type === "Ee");
  const engName = eng ? (ref(eng.at) ? cstr(b, ref(eng.at)!.at) : nm(eng.hash)) : "";
  return { engine: engName, systems, actions, strings, entryTypes, warnings };
}

// ───────────────────────────── NISREVDATA ─────────────────────────────
/** SOUND\NISREVDATA\<escena>.BIN [D: NIS_RevManager::OpenNISRevData (ensamblador)] [V]: 16 conjuntos seguidos (coche 1–8, policía 1–8),
 *  cada uno u32 nº de puntos + puntos EngRevDataPoint {f32 tiempo (s), s32 RPM, s32 Trq (0–100 = acelerador %)}.
 *  Lo que queda detrás de los 16 conjuntos es basura del grabador (no se lee). */
export function parseNisRevData(b: Uint8Array) {
  const dv = view(b), sets: { slot: number; points: [number, number, number][] }[] = [];
  let o = 0;
  for (let s = 0; s < 16 && o + 4 <= b.length; s++) {
    const n = dv.getUint32(o, true); o += 4;
    if (!n) continue;
    const pts: [number, number, number][] = [];
    for (let i = 0; i < n; i++, o += 12) pts.push([+dv.getFloat32(o, true).toFixed(4), dv.getInt32(o + 4, true), dv.getInt32(o + 8, true)]);
    sets.push({ slot: s, points: pts });
  }
  return { sets, bytesUsed: o, trailing: b.length - o };
}

// ───────────────────────────── directorio de escenas y candidatos (INGAMEB) ─────────────────────────────
/** 0x00037060 AnimDirectory (0x4808 B) [D: AnimDirectory.hpp] [V]: u32 nº de escenas, AnimSceneLoadInfo[256] (8 B: hash, u8 nº y
 *  primer archivo compartido, u8 nº y primer archivo propio), u32 nº de archivos, char[256][64] rutas. */
export function parseAnimDirectory(raw: Uint8Array) {
  const b = stripPad(raw), dv = view(b);
  const nScenes = dv.getUint32(0, true), nFiles = dv.getUint32(4 + 256 * 8, true), files = Array.from({ length: nFiles }, (_, i) => cstr(b, 8 + 256 * 8 + 64 * i, 64));
  return Array.from({ length: nScenes }, (_, i) => { const o = 4 + 8 * i;
    return { hash: dv.getUint32(o, true), shared: files.slice(b[o + 5], b[o + 5] + b[o + 4]), files: files.slice(b[o + 7], b[o + 7] + b[o + 6]) }; });
}
/** 0x00037070 CAnimCandidateData (0x1054 B) [D: PS2_types]: contadores + escenas «momento» y listas de coches especiales. */
export function parseAnimCandidates(raw: Uint8Array) {
  const b = stripPad(raw), dv = view(b), u = (o: number) => dv.getUint32(o, true);
  const counts = { raceStart: u(0), raceEnd: u(4), onlineRaceStart: u(8), forwardMasks: u(0xc), reverseMasks: u(0x10), moments: u(0x14), specialCarLists: u(0x18) };
  const raceStart = Array.from({ length: counts.raceStart }, (_, i) => Array.from({ length: 3 }, (_, k) => u(0x1c + 12 * i + 4 * k)));
  const moments = Array.from({ length: counts.moments }, (_, i) => ({ sceneHash: u(0xc9c + 8 * i), momentType: u(0xca0 + 8 * i) }));
  const SPECIAL = ["ONE_COP", "LOTS_OF_COPS", "TRAFFIC_MIX1", "TRAFFIC_MIX2", "TRAFFIC_MIX3", "TRAFFIC_MIX4", "TRAFFIC_MIX5", "TRAFFIC_MIX6", "TRAFFIC_MIX7", "TRAFFIC_MIX8", "TRAFFIC_MIX9", "ONE_SPORT_COP"];
  const special = Array.from({ length: counts.specialCarLists }, (_, i) => ({ sceneHash: u(0xe9c + 8 * i), list: SPECIAL[u(0xea0 + 8 * i)] ?? String(u(0xea0 + 8 * i)) }));
  return { counts, raceStart, moments, special };
}

// ───────────────────────────── audio NIS (NISAUDIO.IDX) ─────────────────────────────
/** uNIS_STRINGHASHMAP [D: SFXObj_NISStream.cpp GenerateNISAnimHashMap]: escena → (evento Csis, bit del parámetro de escena). */
export const NIS_AUDIO_MAP: [string, "start" | "blacklist" | "end", number][] = [
  ["GenericStart", "start", 18], ...Array.from({ length: 10 }, (_, i) => [`IntroNis${String(i + 1).padStart(2, "0")}`, "start", i] as [string, "start", number]),
  ["Flythrough", "start", 12], ["IntroNisDD", "start", 14], ["IntroNisDDEnd", "start", 19], ["IntroNisToll01", "start", 17], ["GarageEnter", "start", 13], ["GarageExit", "start", 13], ["OPMRivalIntro", "start", 15],
  ...Array.from({ length: 16 }, (_, i) => [`IntroNisBL${String(i + 1).padStart(2, "0")}`, "blacklist", i] as [string, "blacklist", number]),
  ["IntroNisBL06End", "blacklist", 5], ["IntroNisBL07End", "blacklist", 6],
  ...(["F02", "F06", "F07", "F14", "F18", "F23", "M01", "M04", "M06", "M07", "M14", "M16", "M19", "M23"] as const).flatMap(a => {
    const bit = { M01: 0, M04: 1, M06: 2, M14: 3, M16: 4, M19: 5, M23: 6, F02: 7, F06: 8, F07: 9, F14: 10, F23: 11, F18: 14, M07: 15 }[a];
    return [[`Arrest${a}`, "end", bit], [`Arrest${a}b`, "end", bit]] as [string, "end", number][];
  }),
  ["EndingNis01", "end", 17], ["EndingNis02", "end", 18], ["EndingNis03", "end", 19], ["EndingNis04", "end", 20],
];
/** Bancos de NISAUDIO.IDX (CLUMP_IDX como la radio [V]). Desplazamientos de clip en unidades de (byte 7 de la cabecera + 1) × 256 B
 *  (0 → 256, 1 → 512, 3 → 1024) [V: los 140 clips caen en una cabecera SCHl] y 3 parámetros por clip
 *  (bits de escena, de pista de cámara y de sección: 0 Complete / 2 End). Frases: 0x4023 Start, 0x4025 Blacklist, 0x4024 End,
 *  0x400E SoundFX (2 parámetros) [V: eventos del .EVT y nombres NIS_Select_Start/SoundFX_Select/NIS_Select_Blacklist/NIS_Select_End]. */
export function parseNisAudioIdx(idx: Uint8Array, clipOffsets: number[]) {
  const dv = view(idx), count = dv.getUint32(0x54, true), banks: { phrase: number; event: string; first: number; clips: { clip: number; values: number[] }[] }[] = [];
  const EV: Record<number, string> = { 0x4023: "NIS_Select_Start", 0x4025: "NIS_Select_Blacklist", 0x4024: "NIS_Select_End", 0x400e: "SoundFX_Select" };
  for (let i = 0; i < count; i++) {
    const o = 0x58 + 16 * i, hdr = dv.getUint32(o + 8, true), sample = dv.getUint32(o + 12, true);
    const phrase = dv.getUint16(hdr, true), dims = idx[hdr + 4], n = idx[hdr + 5], unit = (idx[hdr + 7] + 1) * 256;
    const clips = Array.from({ length: n }, (_, k) => { const e = hdr + 12 + k * (2 + dims);
      return { clip: clipOffsets.indexOf(sample + ((idx[e] << 8) | idx[e + 1]) * unit), values: Array.from(idx.subarray(e + 2, e + 2 + dims)) }; });
    if (clips.some(c => c.clip < 0)) throw new Error(`NISAUDIO: banco ${i} con clips fuera de sitio`);
    banks.push({ phrase, event: EV[phrase] ?? `0x${phrase.toString(16)}`, first: clips[0]?.clip ?? -1, clips });
  }
  return banks;
}
