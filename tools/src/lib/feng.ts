// FEng (FrontEnd engine de EA, «FEng») · paquetes de interfaz .fng de NFS MW PS2, fuentes y tabla de textos.
// Fuente: decomp dbalatoni13/nfsmw (src/Speed/Indep/Src/FEng/FEPackageReader.cpp, FEPackageChunks.h, FEObject.h,
// FEImage.h, FEMultiImage.h, FEString.h, FEKeyTrack.h, FEKeyInterpLinear.cpp; Frontend/FEngFont.cpp, RealFontOld.hpp,
// Localization/Localize.cpp, WideCharHistogram.cpp) [D]. Todo comprobado con bytes de SLES-53559 [V].
//
// En PS2 los datos van en little-endian [V] (la decomp hereda un FEngGetu32 que da la vuelta a los bytes: es de GameCube).
//
// Contenedores en el disco [V]:
//   bChunk 0x00030203 = paquete sin comprimir (los datos son el chunk FEng)
//   bChunk 0x00030210 = paquete comprimido: u32 hash del nombre + bloque JDLZ/HUFF/RAWW con el chunk FEng
//   bChunk 0x00030201 = fuente: char nombre[256] · char textura[256] · RealFontOld::Font («FNTS»)
//   bChunk 0x00039000 = tabla de textos del idioma (LANGUAGES\<IDIOMA>.BIN)
//
// Paquete (FEChunk = {u32 id, u32 tamaño}; bit 0x80000000 = contenedor, ids con letras «FEng», «PkHd»…):
//   FEng ─ PkHd {u32 versión ≥ 0x20000, u32 ?, u32 recursos, u32 objetos, u32 largoNombre, u32 ?, char nombre[largoNombre], char archivo[]}
//        ├ TypS {u32 tipo, u32 tamañoDatos}[]          (tamaño del bloque de datos animables por tipo de objeto)
//        ├ LibL / LibR                                   (paquetes biblioteca; MW PS2 no los usa [V])
//        ├ ResL ─ RsNm (nombres de recursos, texto) · RsRq {u32 n, n × {u32 id, u32 offNombre, u32 tipo, u32 flags, u32 handle, u32 param}}
//        ├ ObjL ─ Butn {u32 n} · FObj ─ ObjD (etiquetas) · Scrp (etiquetas) · MsgR (etiquetas)
//        ├ PkgR (respuestas a mensajes del paquete) · Targ (destinos de mensajes)
//   Etiqueta (FETag) = {u16 id, u16 tamaño} + datos (los ids son dos letras: 'Ot', 'Oh', 'OP', 'PA', 'SA', 'St', 'SH'…).
import { lzDecompress } from "./lz";
import { parseChunks, walk } from "./bchunk";

export const enum FEObjType { None = 0, Image = 1, String = 2, Model = 3, List = 4, Group = 5, CodeList = 6, Movie = 7, Effect = 8, ColoredImage = 9, AnimImage = 10, SimpleImage = 11, MultiImage = 12 }
export const OBJ_TYPE_NAMES: Record<number, string> = { 0: "none", 1: "image", 2: "string", 3: "model", 4: "list", 5: "group", 6: "codelist", 7: "movie", 8: "effect", 9: "colored", 10: "anim", 11: "simple", 12: "multi" };
export const RES_TYPE_NAMES: Record<number, string> = { 0: "none", 1: "image", 2: "font", 3: "model", 4: "movie", 5: "effect", 6: "animimage", 7: "multiimage" };

/** FEHashUpper / bStringHash en mayúsculas: h = h*33 + c, inicio 0xFFFFFFFF [D: FEList.cpp]. */
export function feHash(s: string): number {
  let h = 0xffffffff;
  for (const ch of s.toUpperCase()) h = (Math.imul(h, 33) + (ch.charCodeAt(0) & 0xff)) >>> 0;
  return h >>> 0;
}

const tag2 = (id: number) => String.fromCharCode(id & 0xff, id >> 8);
const fourcc = (id: number) => String.fromCharCode(id & 0xff, (id >> 8) & 0xff, (id >> 16) & 0xff, (id >>> 24) & 0x7f);

export interface FEKey { t: number; v: number[] }
export interface FETrack { param: number; size: number; interp: number; action: number; length: number; offset: number; keys: FEKey[] }
export interface FEScript { id: number; name?: string; length: number; flags: number; chainTo?: number; tracks: FETrack[]; events: { id: number; target: number; t: number }[] }
export interface FEResponse { msg: number; responses: { id: number; param?: number | string; target?: number }[] }
export interface FEObj {
  guid: number; nameHash: number; name?: string; type: number; typeName: string; flags: number; resIndex: number; parent?: number;
  data: number[];                        // bloque animable en palabras de 32 bits (colores en enteros, el resto en float)
  imageFlags?: number;
  string?: { text: string; label?: number; labelName?: string; format: number; leading: number; maxWidth: number; bufLen?: number };
  multi?: { tex: number[]; texFlags: number[] };
  scripts: FEScript[]; responses: FEResponse[];
}
export interface FEPackage {
  name: string; filename: string; version: number; headerWords: number[];
  typeSizes: Record<number, number>;
  libraries: string[];
  resources: { index: number; id: number; name: string; type: number; typeName: string; flags: number; handle: number; param: number }[];
  buttons: number;
  objects: FEObj[];                       // en el orden del archivo (orden de dibujo dentro del grupo); parent = guid del grupo
  responses: FEResponse[];
  targets: { msg: number; guids: number[] }[];
  warnings: string[];
}

interface FEChunk { id: number; size: number; data: number; end: number }
function feChildren(dv: DataView, start: number, end: number): FEChunk[] {
  const out: FEChunk[] = [];
  let o = start;
  while (o + 8 <= end) {
    const id = dv.getUint32(o, true), size = dv.getUint32(o + 4, true);
    if (o + 8 + size > end) throw new Error(`FEChunk ${fourcc(id)} se sale (${o}+${size} > ${end})`);
    out.push({ id, size, data: o + 8, end: o + 8 + size });
    o += 8 + size;
  }
  return out;
}
const ID = (s: string, nested = false) => ((s.charCodeAt(0) | (s.charCodeAt(1) << 8) | (s.charCodeAt(2) << 16) | (s.charCodeAt(3) << 24)) | (nested ? 0x80000000 : 0)) >>> 0;
const C = {
  FEng: ID("FEng", true), PkHd: ID("PkHd"), TypS: ID("TypS"), LibL: ID("LibL"), LibR: ID("LibR"), ResL: ID("ResL", true), RsNm: ID("RsNm"), RsRq: ID("RsRq"),
  ObjL: ID("ObjL", true), Butn: ID("Butn"), FObj: ID("FObj", true), ObjD: ID("ObjD"), Scrp: ID("Scrp"), MsgR: ID("MsgR"), PkgR: ID("PkgR"), Targ: ID("Targ"),
};
const T = (s: string) => s.charCodeAt(0) | (s.charCodeAt(1) << 8);

function cstr(b: Uint8Array, o: number, end = b.length) {
  let e = o; while (e < end && b[e]) e++;
  return new TextDecoder("latin1").decode(b.subarray(o, e));
}
function wstr(dv: DataView, o: number, end: number) {
  let s = "";
  for (let p = o; p + 2 <= end; p += 2) { const c = dv.getUint16(p, true); if (!c) break; s += String.fromCharCode(c); }
  return s;
}

/** Palabras del bloque de datos que son enteros (colores, número de fotograma) según el tipo [D: FEObjData y derivados]. */
export function intWords(type: number): Set<number> {
  const s = new Set([0, 1, 2, 3]);                                // FEColor b,g,r,a
  if (type === FEObjType.ColoredImage) for (let i = 21; i < 37; i++) s.add(i); // 4 colores de vértice
  if (type === FEObjType.AnimImage) s.add(21);                    // FrameNum
  return s;
}

/** Lee un paquete FEng ya descomprimido (empieza por el chunk «FEng»). */
export function parseFEPackage(buf: Uint8Array): FEPackage {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const top = feChildren(dv, 0, buf.length)[0];
  if (!top || top.id !== C.FEng) throw new Error("No es un paquete FEng");
  const kids = feChildren(dv, top.data, top.end);
  const find = (id: number) => kids.find(k => k.id === id);
  const pk: FEPackage = { name: "", filename: "", version: 0, headerWords: [], typeSizes: {}, libraries: [], resources: [], buttons: 0, objects: [], responses: [], targets: [], warnings: [] };

  const hd = kids[0];
  if (hd?.id !== C.PkHd) throw new Error("Falta PkHd");
  pk.version = dv.getUint32(hd.data, true);
  pk.headerWords = [0, 1, 2, 3, 4, 5].map(i => dv.getUint32(hd.data + i * 4, true));
  const nameLen = pk.headerWords[4];
  pk.name = cstr(buf, hd.data + 24, hd.end);
  pk.filename = cstr(buf, hd.data + 24 + nameLen, hd.end);

  const typs = find(C.TypS);
  if (typs) for (let o = typs.data; o + 8 <= typs.end; o += 8) pk.typeSizes[dv.getUint32(o, true)] = dv.getUint32(o + 4, true);

  const libl = find(C.LibL);
  if (libl) { const n = dv.getUint32(libl.data, true); for (let i = 0; i < n; i++) pk.libraries.push(cstr(buf, libl.data + dv.getUint32(libl.data + 4 + i * 4, true), libl.end)); }
  if (find(C.LibR)) pk.warnings.push("LibR: referencias a bibliotecas sin resolver");

  const resl = find(C.ResL);
  if (resl) {
    const [nm, rq] = feChildren(dv, resl.data, resl.end);
    if (nm?.id === C.RsNm && rq?.id === C.RsRq) {
      const n = dv.getUint32(rq.data, true);
      for (let i = 0; i < n; i++) {
        const o = rq.data + 4 + i * 24, w = (k: number) => dv.getUint32(o + k * 4, true);
        const type = w(2);
        pk.resources.push({ index: i, id: w(0), name: cstr(buf, nm.data + w(1), nm.end), type, typeName: RES_TYPE_NAMES[type] ?? String(type), flags: w(3), handle: w(4), param: w(5) });
      }
    }
  }

  const byGuid = new Map<number, FEObj>();
  const objl = find(C.ObjL);
  if (objl) for (const oc of feChildren(dv, objl.data, objl.end)) {
    if (oc.id === C.Butn) { pk.buttons = dv.getUint32(oc.data, true); continue; }
    if (oc.id !== C.FObj) continue;
    let obj: FEObj | undefined;
    for (const sc of feChildren(dv, oc.data, oc.end)) {
      if (sc.id === C.ObjD) obj = readObjectTags(buf, dv, sc.data, sc.end, pk);
      else if (sc.id === C.Scrp && obj) obj.scripts.push(...readScriptTags(buf, dv, sc.data, sc.end, obj, pk));
      else if (sc.id === C.MsgR && obj) obj.responses.push(...readResponses(buf, dv, sc.data, sc.end));
    }
    if (obj) { pk.objects.push(obj); byGuid.set(obj.guid, obj); }
  }
  const pkgr = find(C.PkgR);
  if (pkgr) pk.responses = readResponses(buf, dv, pkgr.data, pkgr.end);
  const targ = find(C.Targ);
  if (targ) for (let o = targ.data; o + 4 <= targ.end;) {
    const id = dv.getUint16(o, true), sz = dv.getUint16(o + 2, true), d = o + 4;
    if (id === T("Mt")) pk.targets.push({ msg: dv.getUint32(d, true), guids: [...Array(sz / 4 - 1)].map((_, i) => dv.getUint32(d + 4 + i * 4, true)) });
    o = d + sz;
  }
  for (const o of pk.objects) if (o.parent !== undefined && !byGuid.has(o.parent)) pk.warnings.push(`objeto ${o.guid}: padre ${o.parent} no existe`);
  return pk;
}

function readObjectTags(buf: Uint8Array, dv: DataView, start: number, end: number, pk: FEPackage): FEObj {
  let obj: FEObj | undefined;
  for (let o = start; o + 4 <= end;) {
    const id = dv.getUint16(o, true), sz = dv.getUint16(o + 2, true), d = o + 4;
    const u = (i: number) => dv.getUint32(d + i * 4, true);
    if (id === T("Ot")) {
      const type = u(0);
      obj = { guid: 0, nameHash: 0, type, typeName: OBJ_TYPE_NAMES[type] ?? String(type), flags: 0, resIndex: 0xffff, data: new Array((pk.typeSizes[type] ?? 0x44) / 4).fill(0), scripts: [], responses: [] };
    } else if (!obj) { /* etiqueta antes del tipo: no pasa en MW [V] */ }
    else if (id === T("On")) obj.name = cstr(buf, d, d + sz);
    else if (id === T("Oh")) obj.nameHash = u(0);
    else if (id === T("OP")) {
      obj.guid = u(0); obj.nameHash = u(1); obj.flags = u(2); obj.resIndex = u(3) & 0xffff;
      if (obj.flags & (1 << 20)) pk.warnings.push(`objeto ${obj.guid}: usa objeto de biblioteca (FF_UsesLibraryObject)`);
    } else if (id === T("PA")) obj.parent = u(0);
    else if (id === T("SA")) {
      const ints = intWords(obj.type);
      for (let i = 0; i < sz / 4 && i < obj.data.length; i++) obj.data[i] = ints.has(i) ? dv.getInt32(d + i * 4, true) : dv.getFloat32(d + i * 4, true);
    } else if (obj.type === FEObjType.String) {
      obj.string ??= { text: "", format: 0, leading: 0, maxWidth: 0 };
      if (id === T("Sb")) obj.string.bufLen = u(0);
      else if (id === T("St")) obj.string.text = wstr(dv, d, d + sz);
      else if (id === T("Sj")) obj.string.format = u(0);
      else if (id === T("Sl")) obj.string.leading = dv.getInt32(d, true);
      else if (id === T("Sw")) obj.string.maxWidth = u(0);
      else if (id === T("SL")) obj.string.labelName = cstr(buf, d, d + sz);
      else if (id === T("SH")) obj.string.label = u(0);
    } else if (id === T("If")) obj.imageFlags = u(0);
    else if (obj.type === FEObjType.MultiImage) {
      obj.multi ??= { tex: [0, 0, 0], texFlags: [1, 1, 1] };
      const k = ["M1", "M2", "M3"].indexOf(tag2(id)), f = ["Ma", "Mb", "Mc"].indexOf(tag2(id));
      if (k >= 0) obj.multi.tex[k] = u(0); else if (f >= 0) obj.multi.texFlags[f] = u(0);
    }
    o = d + sz;
  }
  if (!obj) throw new Error("ObjD sin tipo");
  return obj;
}

/** Valores de un fotograma clave según ParamType [D: FEKeyInterpLinear.cpp]: 1 entero, 2 float, 3 vec2, 4 vec3, 5 cuaternión, 6 color (enteros b,g,r,a). */
function readKeyVals(dv: DataView, o: number, param: number, n: number) {
  const v: number[] = [];
  for (let i = 0; i < n; i++) v.push(param === 1 || param === 6 ? dv.getInt32(o + i * 4, true) : dv.getFloat32(o + i * 4, true));
  return v;
}

function readScriptTags(buf: Uint8Array, dv: DataView, start: number, end: number, obj: FEObj, pk: FEPackage): FEScript[] {
  const out: FEScript[] = [];
  let sc: FEScript | undefined, tr: FETrack | undefined, running = 0;
  const begin = () => { sc = { id: 0, length: 0, flags: 0, tracks: [], events: [] }; out.push(sc); running = 0; tr = undefined; };
  for (let o = start; o + 4 <= end;) {
    const id = dv.getUint16(o, true), sz = dv.getUint16(o + 2, true), d = o + 4;
    const u = (i: number) => dv.getUint32(d + i * 4, true);
    switch (tag2(id)) {
      case "Sn": begin(); sc!.name = cstr(buf, d, d + sz); break;
      case "Sh": if (!sc) begin(); sc!.id = u(0); sc!.length = dv.getInt32(d + 4, true); sc!.flags = u(2); break; // u(3) = número de pistas
      case "Sc": if (sc) sc.chainTo = u(0); break;
      case "SI": pk.warnings.push(`script por referencia (SI) en ${obj.guid}`); break;
      case "Sl": if (sc) sc.length = u(0); break;
      case "Sf": if (sc) sc.flags = u(0); break;
      case "FI": {
        if (!sc) begin();
        tr = { param: buf[d], size: buf[d + 1], interp: buf[d + 2], action: buf[d + 3], length: dv.getInt32(d + 4, true) & 0xffffff, offset: running, keys: [] };
        running += tr.size >> 2;
        sc!.tracks.push(tr);
        break;
      }
      // To/Tt/Ta: el valor es el primer byte de la etiqueta [V] (la decomp hace Getu16 >> 8 con bytes ya girados: GameCube)
      case "To": if (tr) tr.offset = buf[d]; break;
      case "Tt": if (tr) tr.interp = buf[d]; break;
      case "Ta": if (tr) tr.action = buf[d]; break;
      case "Kd": {
        if (!tr) break;
        const ks = tr.size + 4, n = Math.floor(sz / ks);
        for (let k = 0; k < n; k++) tr.keys.push({ t: dv.getInt32(d + k * ks, true), v: readKeyVals(dv, d + k * ks + 4, tr.param, tr.size >> 2) });
        break;
      }
      case "EV": if (sc) for (let k = 0; k + 12 <= sz; k += 12) sc.events.push({ id: dv.getUint32(d + k, true), target: dv.getUint32(d + k + 4, true), t: dv.getUint32(d + k + 8, true) }); break;
      case "Ti": case "Tb": pk.warnings.push(`etiqueta de script ${tag2(id)} sin soporte en ${obj.guid}`); break;
    }
    o = d + sz;
  }
  return out;
}

function readResponses(buf: Uint8Array, dv: DataView, start: number, end: number): FEResponse[] {
  const out: FEResponse[] = [];
  let cur: FEResponse | undefined, r: FEResponse["responses"][number] | undefined;
  for (let o = start; o + 4 <= end;) {
    const id = dv.getUint16(o, true), sz = dv.getUint16(o + 2, true), d = o + 4;
    switch (tag2(id)) {
      case "Mi": cur = { msg: dv.getUint32(d, true), responses: [] }; out.push(cur); break;
      case "Ri": if (cur) { r = { id: dv.getUint32(d, true) }; cur.responses.push(r); } break;
      case "Ru": if (r) r.param = dv.getUint32(d, true); break;
      case "Rs": if (r) r.param = cstr(buf, d, d + sz); break;
      case "Rt": if (r) r.target = dv.getUint32(d, true); break;
    }
    o = d + sz;
  }
  return out;
}

/** Busca paquetes FEng (0x30203 / 0x30210) y fuentes (0x30201) dentro de un archivo bChunk ya descomprimido. */
export function findFEngChunks(buf: Uint8Array) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const packages: { hash?: number; data: Uint8Array }[] = [], fonts: Uint8Array[] = [];
  for (const [c] of walk(parseChunks(buf))) {
    if (c.id === 0x30203) packages.push({ data: buf.subarray(c.dataOffset, c.dataOffset + c.size) });
    else if (c.id === 0x30210) packages.push({ hash: dv.getUint32(c.dataOffset, true), data: lzDecompress(buf.subarray(c.dataOffset + 4, c.dataOffset + c.size)) });
    else if (c.id === 0x30201) fonts.push(buf.subarray(c.dataOffset, c.dataOffset + c.size));
  }
  return { packages, fonts };
}

// ── Fuentes ───────────────────────────────────────────────────────────────────────────────────────────────
// Chunk 0x30201: char nombre[256] · char textura[256] · RealFontOld::Font [D: FEngFont.cpp, RealFontOld.hpp][V]
//   Font: char «FNTS» · u32 tamaño (con la textura original, que no va aquí) · u16 versión · u16 nGlifos · u32 flags ·
//         s8 centroX · s8 centroY · u8 ascenso · u8 descenso · i32 offGlifos · i32 offKern · i32 offForma · i32 estados[24]
//   estados[1] = altura de línea (Font::GetHeight) [V: arial 19, title 44, tac_numbers 31].
//   Glifo (16 B si flags & 0x40000, si no 12): u16 unicode · u8 ancho · u8 alto · u16 u · u16 v · s8 avanceY · s8 offX · s8 offY ·
//         u8 nKern · u16 índiceKern · s16 avanceX. Ordenados por unicode (búsqueda binaria).
//   Kern: u32 n · n × {u16 carácterAnterior, s8 ajuste, u8 ?} [V: pares «AV», «Te»…]; cada glifo usa [índiceKern, +nKern).
export interface FEFont { name: string; texture: string; hash: number; textureHash: number; version: number; flags: number; height: number; ascent: number; descent: number; baselineOffset: number; leadingScale: number;
  glyphs: { c: number; w: number; h: number; u: number; v: number; ox: number; oy: number; ax: number; kern?: [number, number][] }[] }

// ExtraFontDataTable [D: FEngFont.cpp]: desplazamiento de línea base y escala del interlineado por fuente.
const EXTRA_FONT: Record<number, [number, number]> = { 0xdca5485a: [18, 2], 0x833a8678: [22, 2], 0xf88a75f9: [18, 1], 0x71c777d7: [23, 1] };

export function parseFont(chunk: Uint8Array): FEFont {
  const dv = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  const name = cstr(chunk, 0, 256), texture = cstr(chunk, 256, 512);
  const f = 0x200;
  if (cstr(chunk, f, f + 4) !== "FNTS") throw new Error(`Fuente ${name}: sin firma FNTS`);
  const num = dv.getUint16(f + 10, true), flags = dv.getUint32(f + 12, true);
  const gt = f + dv.getInt32(f + 20, true), kt = f + dv.getInt32(f + 24, true), stride = flags & 0x40000 ? 16 : 12;
  const hasKern = dv.getInt32(f + 24, true) > 0;
  const hash = feHash(name), extra = EXTRA_FONT[hash];
  const font: FEFont = { name, texture, hash, textureHash: feHash(texture), version: dv.getUint16(f + 8, true), flags, height: dv.getInt32(f + 0x20 + 4, true),
    ascent: chunk[f + 18], descent: chunk[f + 19], baselineOffset: extra?.[0] ?? 0, leadingScale: extra?.[1] ?? 1, glyphs: [] };
  for (let i = 0; i < num; i++) {
    const g = gt + i * stride;
    const nk = chunk[g + 11], ki = dv.getUint16(g + 12, true);
    const gl: FEFont["glyphs"][number] = { c: dv.getUint16(g, true), w: chunk[g + 2], h: chunk[g + 3], u: dv.getUint16(g + 4, true), v: dv.getUint16(g + 6, true),
      ox: dv.getInt8(g + 9), oy: dv.getInt8(g + 10), ax: stride === 16 ? dv.getInt16(g + 14, true) : chunk[g + 2] };
    if (hasKern && nk) { gl.kern = []; for (let k = 0; k < nk; k++) { const e = kt + 4 + (ki + k) * 4; gl.kern.push([dv.getUint16(e, true), dv.getInt8(e + 2)]); } }
    font.glyphs.push(gl);
  }
  return font;
}

// ── Textos del idioma ─────────────────────────────────────────────────────────────────────────────────────
// Chunk 0x00039000 [D: Localize.cpp LoaderLanguage][V: SPANISH.BIN]:
//   cabecera {i32 posHistograma = 0x10, i32 nRegistros, i32 posRegistros, i32 posTextos} (relativas al inicio de los datos del chunk)
//   histograma {i32 nEntradas, u16 entradas[nEntradas]} · registros {u32 hash, u32 offTexto}[] ordenados por hash
//   textos empaquetados (WideCharHistogram::UnpackString): byte < 0x80 = ASCII; byte ≥ 0x80 → e = entradas[byte];
//   si 0 < e < 0x80, es un par: carácter = entradas[e*0x80 + siguiente − 0x80].
export function parseLanguage(file: Uint8Array): Map<number, string> {
  const ch = [...walk(parseChunks(file))].map(([c]) => c).find(c => c.id === 0x39000);
  if (!ch) throw new Error("Sin chunk de idioma 0x39000");
  const dv = new DataView(file.buffer, file.byteOffset + ch.dataOffset, ch.size);
  const b = file.subarray(ch.dataOffset, ch.dataOffset + ch.size);
  const histPos = dv.getInt32(0, true), n = dv.getInt32(4, true), recPos = dv.getInt32(8, true), strPos = dv.getInt32(12, true);
  const nEntries = dv.getInt32(histPos, true);
  const entry = (i: number) => (i < nEntries || i < 3072) && histPos + 4 + i * 2 + 2 <= b.length ? dv.getUint16(histPos + 4 + i * 2, true) : 0;
  const out = new Map<number, string>();
  for (let i = 0; i < n; i++) {
    const hash = dv.getUint32(recPos + i * 8, true);
    let p = strPos + dv.getUint32(recPos + i * 8 + 4, true), s = "";
    for (;;) {
      const c = b[p++];
      if (c === undefined || c === 0) break;
      if (c & 0x80) {
        let r = entry(c);
        if (r < 0x80 && r !== 0) { const nx = b[p++]; r = nx & 0x80 ? entry(r * 0x80 + nx - 0x80) : 0; }
        s += String.fromCharCode(r || 0x5f);
      } else s += String.fromCharCode(c);
    }
    out.set(hash, s);
  }
  return out;
}
