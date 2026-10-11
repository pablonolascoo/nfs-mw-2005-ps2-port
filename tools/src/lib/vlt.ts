// Lector de la base de atributos de EA ("AttribSys", vaults .vlt/.bin empaquetados en VPAK).
// Formato documentado en docs/es/05-vlt-atributos.md (etiquetas [V] verificado / [D] decomp / [H] hipótesis).
//
// Resumen (todo little-endian en el disco PS2):
//   VPAK  = cabecera + tabla de vaults + tabla de nombres + bloques bin/vlt de cada vault.
//   vault = dos blobs: "vlt" (chunks DepN, StrN, DatN, ExpN, PtrN) y "bin" (chunk StrE + datos crudos).
//   ExpN  = lista de exportaciones {id, tipo, nombre, bytes, offset}; el tipo dice qué estructura hay en DatN:
//           DatabaseLoadData (tipos), ClassLoadData (definiciones de campos) o CollectionLoadData (valores).
//   PtrN  = parches de punteros: el motor los aplica al cargar (Attrib::Vault::Initialize). Aquí NO se
//           escriben: se guardan en un mapa (blob, offset) → destino, y se consultan al leer un puntero.

// ───────────────────────────── hash ─────────────────────────────

/** Jenkins lookup2 de 32 bits (Attrib::StringToKey usa semilla 0xABCDEF00). [D] AttribHash32.cpp, [V] "gameplay" → 0x5cea9d46. */
export function attribHash(s: string, initval = 0xabcdef00): number {
  const k = new TextEncoder().encode(s);
  let a = 0x9e3779b9, b = 0x9e3779b9, c = initval >>> 0;
  let len = k.length, i = 0;
  const mix = () => {
    a = (a - b - c) >>> 0; a = (a ^ (c >>> 13)) >>> 0;
    b = (b - c - a) >>> 0; b = (b ^ (a << 8)) >>> 0;
    c = (c - a - b) >>> 0; c = (c ^ (b >>> 13)) >>> 0;
    a = (a - b - c) >>> 0; a = (a ^ (c >>> 12)) >>> 0;
    b = (b - c - a) >>> 0; b = (b ^ (a << 16)) >>> 0;
    c = (c - a - b) >>> 0; c = (c ^ (b >>> 5)) >>> 0;
    a = (a - b - c) >>> 0; a = (a ^ (c >>> 3)) >>> 0;
    b = (b - c - a) >>> 0; b = (b ^ (a << 10)) >>> 0;
    c = (c - a - b) >>> 0; c = (c ^ (b >>> 15)) >>> 0;
  };
  const w = (o: number) => (k[o] | (k[o + 1] << 8) | (k[o + 2] << 16) | (k[o + 3] << 24)) >>> 0;
  while (len >= 12) {
    a = (a + w(i)) >>> 0; b = (b + w(i + 4)) >>> 0; c = (c + w(i + 8)) >>> 0;
    mix(); i += 12; len -= 12;
  }
  c = (c + k.length) >>> 0;
  switch (len) { // caída en cascada intencionada, como el original
    case 11: c = (c + (k[i + 10] << 24)) >>> 0;
    case 10: c = (c + (k[i + 9] << 16)) >>> 0;
    case 9: c = (c + (k[i + 8] << 8)) >>> 0;
    case 8: b = (b + (k[i + 7] << 24)) >>> 0;
    case 7: b = (b + (k[i + 6] << 16)) >>> 0;
    case 6: b = (b + (k[i + 5] << 8)) >>> 0;
    case 5: b = (b + k[i + 4]) >>> 0;
    case 4: a = (a + (k[i + 3] << 24)) >>> 0;
    case 3: a = (a + (k[i + 2] << 16)) >>> 0;
    case 2: a = (a + (k[i + 1] << 8)) >>> 0;
    case 1: a = (a + k[i]) >>> 0;
  }
  mix();
  return c >>> 0;
}

const hex = (n: number) => "0x" + (n >>> 0).toString(16).padStart(8, "0");

/** Diccionario hash → nombre. Se alimenta con cadenas conocidas (decomp, StrE, nombres de colección). */
export class HashNames {
  map = new Map<number, string>();
  add(s: string) { if (s) this.map.set(attribHash(s), s); return this; }
  set(h: number, s: string) { this.map.set(h >>> 0, s); }
  get(h: number) { return this.map.get(h >>> 0); }
  name(h: number) { return this.map.get(h >>> 0) ?? hex(h); }
}

// ───────────────────────────── lectura segura ─────────────────────────────

class Reader {
  dv: DataView;
  constructor(public buf: Uint8Array, public label: string) { this.dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength); }
  check(o: number, n: number) {
    if (!(o >= 0 && n >= 0 && o + n <= this.buf.length)) throw new RangeError(`${this.label}: lectura fuera de rango @${o}+${n} (tam ${this.buf.length})`);
  }
  u8(o: number) { this.check(o, 1); return this.buf[o]; }
  i8(o: number) { this.check(o, 1); return this.dv.getInt8(o); }
  u16(o: number) { this.check(o, 2); return this.dv.getUint16(o, true); }
  i16(o: number) { this.check(o, 2); return this.dv.getInt16(o, true); }
  u32(o: number) { this.check(o, 4); return this.dv.getUint32(o, true); }
  i32(o: number) { this.check(o, 4); return this.dv.getInt32(o, true); }
  f32(o: number) { this.check(o, 4); return this.dv.getFloat32(o, true); }
  f64(o: number) { this.check(o, 8); return this.dv.getFloat64(o, true); }
  tag(o: number) { return String.fromCharCode(...this.buf.subarray(o, o + 4)); }
  cstr(o: number, max = 4096) {
    this.check(o, 1);
    let e = o; while (e < this.buf.length && e - o < max && this.buf[e] !== 0) e++;
    return new TextDecoder("latin1").decode(this.buf.subarray(o, e));
  }
}

// ───────────────────────────── VPAK ─────────────────────────────

export interface VpakEntry { name: string; binOffset: number; binSize: number; vltOffset: number; vltSize: number; bin: Uint8Array; vlt: Uint8Array }

/**
 * Cabecera VPAK [V] (GAMEPLAY.BIN, ATTRIBUTES.BIN, FE_ATTRIB.BIN de SLES-53559):
 *   +0 "VPAK" · +4 u32 nVaults · +8 u32 offTablaNombres · +C u32 tamTablaNombres
 *   +10 nVaults × {u32 offNombre, u32 binSize, u32 vltSize, u32 binOffset, u32 vltOffset}
 */
export function parseVpak(buf: Uint8Array): VpakEntry[] {
  const r = new Reader(buf, "VPAK");
  if (r.tag(0) !== "VPAK") throw new Error("No es un VPAK (falta la firma 'VPAK')");
  const n = r.u32(4), strOff = r.u32(8), strSize = r.u32(12);
  if (n > 100000 || 0x10 + n * 20 > buf.length) throw new Error(`VPAK: número de vaults absurdo (${n})`);
  r.check(strOff, strSize);
  const out: VpakEntry[] = [];
  for (let i = 0; i < n; i++) {
    const o = 0x10 + i * 20;
    const nameOff = r.u32(o), binSize = r.u32(o + 4), vltSize = r.u32(o + 8), binOffset = r.u32(o + 12), vltOffset = r.u32(o + 16);
    if (nameOff >= strSize) throw new Error(`VPAK: nombre del vault ${i} fuera de la tabla`);
    r.check(binOffset, binSize); r.check(vltOffset, vltSize);
    out.push({ name: r.cstr(strOff + nameOff), binOffset, binSize, vltOffset, vltSize, bin: buf.subarray(binOffset, binOffset + binSize), vlt: buf.subarray(vltOffset, vltOffset + vltSize) });
  }
  return out;
}

// ───────────────────────────── vault ─────────────────────────────

/** Bloque de datos de un vault: 0 = el propio .vlt, 1 = el .bin (índices de DepN). [D] Vault::Initialize */
export type Blob = 0 | 1;
export interface Loc { blob: Blob; off: number }
export type Fixup = { kind: "ptr"; to: Loc } | { kind: "null" } | { kind: "export"; dep: number; id: number } | { kind: "string"; text: string };

export const EXPORT_DATABASE = attribHash("Attrib::DatabaseLoadData"); // 0xcbbc628f
export const EXPORT_CLASS = attribHash("Attrib::ClassLoadData");       // 0x5e970cbc
export const EXPORT_COLLECTION = attribHash("Attrib::CollectionLoadData"); // 0x8e112eb7

export interface ExportEntry { id: number; type: number; name: string; bytes: number; offset: number }

export class Vault {
  vltR: Reader; binR: Reader;
  deps: { id: number; name: string }[] = [];
  /** Cadenas del chunk StrN del .vlt (claves registradas). */
  strN: string[] = [];
  /** Cadenas del chunk StrE del .bin, por offset dentro del .bin. */
  strE = new Map<number, string>();
  exports: ExportEntry[] = [];
  fixups = new Map<string, Fixup>();
  chunks: { tag: string; blob: Blob; off: number; size: number }[] = [];

  constructor(public name: string, public vlt: Uint8Array, public bin: Uint8Array) {
    this.vltR = new Reader(vlt, `${name}.vlt`);
    this.binR = new Reader(bin, `${name}.bin`);
    this.parseVlt();
    this.parseBin();
  }

  reader(b: Blob) { return b === 0 ? this.vltR : this.binR; }

  private parseVlt() {
    const r = this.vltR;
    let strNData: [number, number] | null = null, ptrN: [number, number] | null = null;
    for (let o = 0; o + 8 <= r.buf.length;) {
      // Las etiquetas están escritas como u32 LE: 'DepN' aparece en disco como "NpeD". [V]
      const id = r.u32(o), size = r.u32(o + 4);
      if (size < 8 || o + size > r.buf.length) throw new Error(`${this.name}.vlt: chunk corrupto @${o} (tam ${size})`);
      const tag = String.fromCharCode((id >>> 24) & 255, (id >>> 16) & 255, (id >>> 8) & 255, id & 255);
      this.chunks.push({ tag, blob: 0, off: o, size });
      const d = o + 8;
      if (tag === "DepN") {
        const n = r.u32(d);
        const namesBase = d + 4 + n * 8;
        for (let i = 0; i < n; i++) this.deps.push({ id: r.u32(d + 4 + i * 4), name: r.cstr(namesBase + r.u32(d + 4 + n * 4 + i * 4)) });
      } else if (tag === "StrN") strNData = [d, o + size];
      else if (tag === "ExpN") {
        const n = r.u32(d);
        const namesBase = d + 4 + n * 20;
        for (let i = 0; i < n; i++) {
          const e = d + 4 + i * 20;
          const nameOff = r.u32(e + 8);
          this.exports.push({ id: r.u32(e), type: r.u32(e + 4), name: namesBase + nameOff < o + size ? r.cstr(namesBase + nameOff) : "", bytes: r.u32(e + 12), offset: r.u32(e + 16) });
        }
      } else if (tag === "PtrN") ptrN = [d, o + size];
      o += size;
    }
    if (strNData) {
      for (let p = strNData[0]; p < strNData[1];) { const s = r.cstr(p); if (s) this.strN.push(s); p += s.length + 1; }
    }
    if (!ptrN) throw new Error(`${this.name}.vlt: falta PtrN`);
    // PtrRef {u32 fixupOffset, u16 tipo, u16 índice, u32 offset/exportId} [D] AttribLoadAndGo.cpp, [V] datos reales.
    let target: Blob = 0, ended = false;
    for (let p = ptrN[0]; p + 12 <= ptrN[1]; p += 12) {
      const fix = r.u32(p), type = r.u16(p + 4), idx = r.u16(p + 6), val = r.u32(p + 8);
      const key = `${target}:${fix}`;
      if (type === 0) { ended = true; break; }
      else if (type === 1) this.fixups.set(key, { kind: "null" });
      else if (type === 2) { if (idx > 1) throw new Error(`${this.name}: PtrN cambia a dependencia ${idx}`); target = idx as Blob; }
      else if (type === 3) { if (idx > 1) throw new Error(`${this.name}: PtrN apunta a dependencia ${idx}`); this.fixups.set(key, { kind: "ptr", to: { blob: idx as Blob, off: val } }); }
      else if (type === 4) this.fixups.set(key, { kind: "export", dep: idx, id: val });
      else if (type === 5) this.fixups.set(key, { kind: "string", text: strNData ? r.cstr(strNData[0] + val) : "" });
      else throw new Error(`${this.name}: tipo de PtrRef desconocido ${type}`);
    }
    if (!ended) throw new Error(`${this.name}.vlt: PtrN sin terminador`);
  }

  private parseBin() {
    const r = this.binR;
    if (r.buf.length < 8) return;
    const id = r.u32(0), size = r.u32(4);
    if (id !== 0x53747245) return; // 'StrE'
    if (size < 8 || size > r.buf.length) throw new Error(`${this.name}.bin: StrE corrupto`);
    this.chunks.push({ tag: "StrE", blob: 1, off: 0, size });
    for (let p = 8; p < size;) { const s = r.cstr(p); if (s) this.strE.set(p, s); p += s.length + 1; }
  }

  /** Destino del puntero guardado en (blob, off), o undefined si no hay parche. */
  fixup(at: Loc) { return this.fixups.get(`${at.blob}:${at.off}`); }
  /** Resuelve un puntero a cadena C (Text). */
  pointedString(at: Loc): string | null | undefined {
    const f = this.fixup(at);
    if (!f) return undefined;
    if (f.kind === "null") return null;
    if (f.kind === "string") return f.text;
    if (f.kind === "ptr") return this.reader(f.to.blob).cstr(f.to.off);
    return undefined;
  }
}

// ───────────────────────────── estructuras exportadas ─────────────────────────────

export interface TypeInfo { hash: number; name: string; size: number }
export interface Definition { key: number; type: number; offset: number; size: number; maxCount: number; flags: number; alignment: number }
export const DEF_ARRAY = 1, DEF_IN_LAYOUT = 2, DEF_BOUND = 4, DEF_NOT_SEARCHABLE = 8; // [D] AttribSys.h Definition::Flags
export const NODE_ARRAY = 2, NODE_INHERITED = 4, NODE_LAID_OUT = 0x10, NODE_BY_VALUE = 0x20; // [D] Node::Flags

export interface ClassInfo { key: number; vault: string; collectionReserve: number; layoutSize: number; definitions: Definition[] }

export interface AttribEntry { key: number; type: number; flags: number; entryFlags: number; dataLoc: Loc }
export interface CollectionInfo {
  key: number; classKey: number; parent: number; vault: Vault; offset: number;
  tableReserve: number; keyShift: number; types: number[]; entries: AttribEntry[]; layout: Loc | null;
}

/** DatabaseLoadData {u32 nClases, u32 tamDefault, u32 nTipos, char* nombres} + u32 tamaños[nTipos]. [D]+[V] */
export function readDatabase(v: Vault, e: ExportEntry): TypeInfo[] {
  const r = v.vltR, o = e.offset;
  const nTypes = r.u32(o + 8);
  const f = v.fixup({ blob: 0, off: o + 12 });
  if (!f || f.kind !== "ptr") throw new Error("DatabaseLoadData sin puntero a nombres de tipo");
  const nr = v.reader(f.to.blob);
  const out: TypeInfo[] = [];
  let p = f.to.off;
  for (let i = 0; i < nTypes; i++) {
    const name = nr.cstr(p); p += name.length + 1;
    out.push({ hash: attribHash(name), name, size: r.u32(o + 16 + i * 4) });
  }
  return out;
}

/** ClassLoadData {key, reserva, nDefs, Definition*, tamLayout, keyShift, nLayout}; Definition = 16 B. [D]+[V] */
export function readClass(v: Vault, e: ExportEntry): ClassInfo {
  const r = v.vltR, o = e.offset;
  const key = r.u32(o), nDefs = r.u32(o + 8);
  if (nDefs > 10000) throw new Error(`Clase ${hex(key)}: ${nDefs} definiciones`);
  const f = v.fixup({ blob: 0, off: o + 12 });
  const defs: Definition[] = [];
  if (f?.kind === "ptr") {
    const dr = v.reader(f.to.blob);
    for (let i = 0; i < nDefs; i++) {
      const d = f.to.off + i * 16;
      defs.push({ key: dr.u32(d), type: dr.u32(d + 4), offset: dr.u16(d + 8), size: dr.u16(d + 10), maxCount: dr.u16(d + 12), flags: dr.u8(d + 14), alignment: dr.u8(d + 15) });
    }
  }
  return { key, vault: v.name, collectionReserve: r.u32(o + 4), layoutSize: r.u32(o + 16), definitions: defs };
}

/**
 * CollectionLoadData (0x20 B) [D] PS2_types + [V]:
 *   key, class, parent, tableReserve, tableKeyShift, nEntries, nTypes, void* layout
 *   + u32 tipos[nTypes] + nEntries × AttribEntry {u32 key, u32 data, u16 tipo(índice), u8 nodeFlags, u8 entryFlags}
 */
export function readCollection(v: Vault, e: ExportEntry): CollectionInfo {
  const r = v.vltR, o = e.offset;
  const nEntries = r.u32(o + 20), nTypes = r.u32(o + 24);
  if (nEntries > 4096 || nTypes > 4096) throw new Error(`${v.name}: colección @${o} con tamaños absurdos`);
  if (0x20 + nTypes * 4 + nEntries * 12 > e.bytes) throw new Error(`${v.name}: colección @${o} más grande que su exportación`);
  const types: number[] = [];
  for (let i = 0; i < nTypes; i++) types.push(r.u32(o + 0x20 + i * 4));
  const entries: AttribEntry[] = [];
  const eb = o + 0x20 + nTypes * 4;
  for (let i = 0; i < nEntries; i++) {
    const p = eb + i * 12;
    const ti = r.u16(p + 8);
    if (ti >= nTypes) throw new Error(`${v.name}: entrada con índice de tipo ${ti} ≥ ${nTypes}`);
    entries.push({ key: r.u32(p), type: types[ti], flags: r.u8(p + 10), entryFlags: r.u8(p + 11), dataLoc: { blob: 0, off: p + 4 } });
  }
  const lf = v.fixup({ blob: 0, off: o + 0x1c });
  return {
    key: r.u32(o), classKey: r.u32(o + 4), parent: r.u32(o + 8), vault: v, offset: o,
    tableReserve: r.u32(o + 12), keyShift: r.u32(o + 16), types, entries, layout: lf?.kind === "ptr" ? lf.to : null,
  };
}

// ───────────────────────────── base de datos ─────────────────────────────

export type Value = number | boolean | string | null | Value[] | { [k: string]: Value };

/**
 * Agrupa varios vaults (p. ej. ATTRIBUTES.BIN 'db' + los 272 de GAMEPLAY.BIN), con tipos y clases
 * del vault principal y colecciones de todos. Resuelve valores con herencia por "parent".
 */
export class AttribDatabase {
  names = new HashNames();
  types = new Map<number, TypeInfo>();
  classes = new Map<number, ClassInfo>();
  collections = new Map<string, CollectionInfo>(); // clave "clase:colección"
  vaults: Vault[] = [];
  warnings: string[] = [];

  addVault(v: Vault) {
    this.vaults.push(v);
    for (const s of v.strN) this.names.add(s);
    for (const s of v.strE.values()) this.names.add(s);
    for (const e of v.exports) {
      try {
        if (e.type === EXPORT_DATABASE) for (const t of readDatabase(v, e)) { this.types.set(t.hash, t); this.names.set(t.hash, t.name); }
        else if (e.type === EXPORT_CLASS) { const c = readClass(v, e); this.classes.set(c.key, c); }
        else if (e.type === EXPORT_COLLECTION) {
          const c = readCollection(v, e);
          const k = `${c.classKey}:${c.key}`;
          if (this.collections.has(k)) this.warnings.push(`colección duplicada ${this.names.name(c.classKey)}/${this.names.name(c.key)} en ${v.name}`);
          this.collections.set(k, c);
        } else this.warnings.push(`${v.name}: exportación de tipo desconocido ${hex(e.type)}`);
      } catch (err) { this.warnings.push(`${v.name}: ${(err as Error).message}`); }
    }
  }

  /** Nombre de la colección: el campo de layout CollectionName (Text) si existe; si no, el diccionario. */
  collectionName(c: CollectionInfo): string {
    const known = this.names.get(c.key);
    if (known) return known;
    if (c.layout) {
      const s = c.vault.pointedString(c.layout);
      if (s && attribHash(s) === c.key) { this.names.set(c.key, s); return s; }
    }
    return hex(c.key);
  }

  /** Decodifica un valor de tipo `type` situado en `loc` dentro de `v`. */
  decode(v: Vault, type: number, loc: Loc, size?: number): Value {
    const t = this.types.get(type);
    const name = t?.name ?? this.names.get(type) ?? hex(type);
    const sz = size ?? t?.size ?? 4;
    const r = v.reader(loc.blob), o = loc.off;
    const f32 = (i: number) => +r.f32(o + i * 4).toPrecision(7);
    switch (name) {
      case "EA::Reflection::Float": return f32(0);
      case "EA::Reflection::Double": return r.f64(o);
      case "EA::Reflection::Int32": return r.i32(o);
      case "EA::Reflection::UInt32": return r.u32(o);
      case "EA::Reflection::Int16": return r.i16(o);
      case "EA::Reflection::UInt16": return r.u16(o);
      case "EA::Reflection::Int8": return r.i8(o);
      case "EA::Reflection::UInt8": return r.u8(o);
      case "EA::Reflection::Bool": return (sz >= 4 ? r.u32(o) : r.u8(o)) !== 0; // Bool ocupa 4 B en este vault [V]
      case "EA::Reflection::Char": return String.fromCharCode(r.u8(o));
      case "EA::Reflection::Int64": case "EA::Reflection::UInt64": return hex(r.u32(o + 4)) + (r.u32(o) >>> 0).toString(16).padStart(8, "0");
      case "Attrib::Key": case "EA::Reflection::Reference": case "Attrib::Types::Symbol": { const k = r.u32(o); return k === 0 ? null : this.names.name(k); }
      case "Attrib::Types::Colour": return hex(r.u32(o));
      case "EA::Reflection::Text": { const s = v.pointedString(loc); return s === undefined ? (r.u32(o) === 0 ? null : `<ptr ${hex(r.u32(o))}>`) : s; }
      case "UMath::Vector4": case "Attrib::Types::Vector4": case "Attrib::Types::FloatColour": case "Attrib::Types::Quaternion": return [f32(0), f32(1), f32(2), f32(3)];
      case "UMath::Vector2": case "Attrib::Types::Vector2": return [f32(0), f32(1)];
      case "UMath::Vector3": case "Attrib::Types::Vector3": return [f32(0), f32(1), f32(2)];
      case "UMath::Matrix4": case "Attrib::Types::Matrix": return Array.from({ length: 16 }, (_, i) => f32(i));
      case "GCollectionKey": case "type_bStringHash": { const k = r.u32(o); return k === 0 ? null : this.names.name(k); }
      case "Attrib::RefSpec": case "RefSpec": {
        const cls = r.u32(o), col = r.u32(o + 4);
        return { class: cls ? this.names.name(cls) : null, collection: col ? this.names.name(col) : null };
      }
      case "Attrib::StringKey": { // {u64 hash64, u32 hash32, const char* str} [D] (tamaño 0x10)
        const s = v.pointedString({ blob: loc.blob, off: o + 12 });
        return s ?? this.names.name(r.u32(o + 8));
      }
    }
    // Tipos de 4 B sin decodificador (enums como GRace::Type, eUnlockableEntity…): entero. [H]
    if (sz === 4) return r.i32(o);
    // Desconocido: volcado crudo en palabras de 32 bits.
    const words: Value[] = [];
    for (let i = 0; i + 4 <= sz; i += 4) words.push(hex(r.u32(o + i)));
    return { type: name, raw: words };
  }

  /** Lee un Attrib::Array {u16 alloc, u16 count, u16 size, u16 typePad} + datos (+8 si alineado a 16). [D] */
  decodeArray(v: Vault, type: number, at: Loc): Value[] {
    const r = v.reader(at.blob);
    const count = r.u16(at.off + 2), esize = r.u16(at.off + 4), pad = r.u16(at.off + 6) & 0x8000 ? 8 : 0;
    if (count > 4096) throw new Error(`array de ${count} elementos`);
    const base = at.off + 8 + pad, step = esize || 4;
    const out: Value[] = [];
    for (let i = 0; i < count; i++) {
      const el: Loc = { blob: at.blob, off: base + i * step };
      if (esize === 0) { // referencias: punteros parcheados
        const f = v.fixup(el);
        out.push(f?.kind === "ptr" ? this.decode(v, type, f.to) : null);
      } else out.push(this.decode(v, type, el, esize));
    }
    return out;
  }

  /** Valor de una entrada propia de la colección (no heredada). */
  entryValue(c: CollectionInfo, e: AttribEntry): Value {
    const v = c.vault;
    if (e.flags & NODE_BY_VALUE) return this.decode(v, e.type, e.dataLoc);
    const f = v.fixup(e.dataLoc);
    if (!f || f.kind === "null") return null;
    if (f.kind !== "ptr") return `<${f.kind}>`;
    return e.flags & NODE_ARRAY ? this.decodeArray(v, e.type, f.to) : this.decode(v, e.type, f.to);
  }

  /** Campos del layout fijo de la clase (definiciones kInLayout), leídos desde c.layout. */
  layoutValues(c: CollectionInfo): Record<string, Value> {
    const out: Record<string, Value> = {};
    const cls = this.classes.get(c.classKey);
    if (!cls || !c.layout) return out;
    for (const d of cls.definitions) {
      if (!(d.flags & DEF_IN_LAYOUT)) continue;
      const at: Loc = { blob: c.layout.blob, off: c.layout.off + d.offset };
      try { out[this.names.name(d.key)] = d.flags & DEF_ARRAY ? this.decodeArray(c.vault, d.type, at) : this.decode(c.vault, d.type, at); }
      catch (err) { out[this.names.name(d.key)] = `<error: ${(err as Error).message}>`; }
    }
    return out;
  }

  /** Atributos propios (sin herencia), con nombres resueltos. */
  ownValues(c: CollectionInfo): Record<string, Value> {
    const out = this.layoutValues(c);
    for (const e of c.entries) {
      try { out[this.names.name(e.key)] = this.entryValue(c, e); }
      catch (err) { out[this.names.name(e.key)] = `<error: ${(err as Error).message}>`; }
    }
    return out;
  }

  getCollection(classKey: number, key: number) { return this.collections.get(`${classKey}:${key}`); }

  /** Atributos con herencia (los del hijo pisan a los del padre). */
  resolvedValues(c: CollectionInfo, depth = 0): Record<string, Value> {
    const parent = c.parent ? this.getCollection(c.classKey, c.parent) : undefined;
    const base = parent && depth < 32 ? this.resolvedValues(parent, depth + 1) : {};
    return { ...base, ...this.ownValues(c) };
  }
}

export { hex as hexKey };
