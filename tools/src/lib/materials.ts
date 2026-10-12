// Tabla de materiales compartida por un GLB: textura por hash → PNG embebido; sin textura → color estable.
import type { GlbImage, GlbMaterial } from "./glb";
import type { Texture } from "./tex-ps2";
import { encodePng } from "./png";
import { hex8 } from "./hash";
import type { Placeholder } from "./car-textures";

export class MaterialTable {
  materials: GlbMaterial[] = [];
  images: GlbImage[] = [];
  private byHash = new Map<string, number>();
  missing = new Set<number>();
  /** external: carpeta donde escribir PNG compartidos y prefijo de URI relativo al GLB. */
  constructor(private textures: Map<number, Texture>, private opts: { unlit?: boolean; external?: { dir: string; uriPrefix: string; written: Set<number> }; placeholders?: Map<number, Placeholder>; missingColor?: [number, number, number, number] } = {}) {}

  get(hash: number | undefined): number {
    const key = hash === undefined ? "none" : hex8(hash);
    const hit = this.byHash.get(key);
    if (hit !== undefined) return hit;
    const t = hash !== undefined ? this.textures.get(hash) : undefined;
    let m: GlbMaterial;
    if (t) {
      const ext = this.opts.external;
      if (ext) {
        if (!ext.written.has(t.nameHash)) { Bun.write(`${ext.dir}/${hex8(t.nameHash)}.png`, encodePng(t.rgba, t.width, t.height)); ext.written.add(t.nameHash); }
        this.images.push({ name: t.name, uri: `${ext.uriPrefix}${hex8(t.nameHash)}.png`, wrap: t.tilableUV & 3 });
      } else this.images.push({ name: t.name, png: encodePng(t.rgba, t.width, t.height), wrap: t.tilableUV & 3 });
      m = { name: t.name, color: [1, 1, 1, 1], texture: this.images.length - 1, unlit: this.opts.unlit, ...alphaFor(t) };
    } else if (hash !== undefined && this.opts.placeholders?.has(hash)) {
      const { role, ...p } = this.opts.placeholders.get(hash)!;
      m = { color: [1, 1, 1, 1], unlit: this.opts.unlit, ...p, extras: { ...p.extras, role } };
    } else if (this.opts.missingColor) {
      if (hash !== undefined) this.missing.add(hash);
      m = { name: `sin_textura_${key}`, color: this.opts.missingColor, unlit: this.opts.unlit };
    } else {
      if (hash !== undefined) this.missing.add(hash);
      const h = hash ?? 0x9e3779b9, r = 0.35 + ((h & 0xff) / 255) * 0.4, g = 0.35 + (((h >> 8) & 0xff) / 255) * 0.4, b = 0.35 + (((h >> 16) & 0xff) / 255) * 0.4;
      m = { name: `sin_textura_${key}`, color: [r, g, b, 1], unlit: this.opts.unlit };
    }
    this.materials.push(m);
    this.byHash.set(key, this.materials.length - 1);
    return this.materials.length - 1;
  }
}

/** Umbral de la prueba de alfa del juego: GXSetAlphaCompare(GX_GREATER, 0x28) [D: GameCube/Src/Ecstasy/EcstasyEx.cpp _alphaRef]. */
export const ALPHA_REF = 0x28 / 255;

/**
 * Modo de alfa según TextureInfo.AlphaUsageType / AlphaBlendType, igual que eSetBlendMode [D: EcstasyEx.cpp]:
 *  - AlphaUsageType 1 (PUNCHTHRU) activa la prueba de alfa (alfa > 0x28); el resto no la usa.
 *  - AlphaBlendType 0 (SRCCOPY) no mezcla; 1 mezcla normal (SRCALPHA, INVSRCALPHA); 2 aditiva (SRCALPHA, ONE).
 * Por eso MODULATED + SRCCOPY es opaco (asfalto) y MODULATED + BLEND es una calcomanía semitransparente (pintadas,
 * cristales, alambradas). extras.wrap = TilableUV (bit 0 repite U, bit 1 repite V; 0 = recortar) [V: 0,8 % de UV fuera de 0…1].
 */
export function alphaFor(t: Texture): Pick<GlbMaterial, "alphaMode" | "alphaCutoff" | "extras"> {
  const usage = t.alphaUsage, blend = t.alphaBlend;
  const base = { wrap: t.tilableUV & 3, ...(t.applyAlphaSorting ? { sort: 1 } : {}) };
  // Sombras horneadas (SHD_*): RGB negro y alfa = densidad de sombra; se mezclan encima del suelo [V: 1 026 texturas].
  if (t.name.startsWith("SHD_")) return { alphaMode: "BLEND", extras: { ...base, blend: "sombra" } };
  // Agua animada (ANM_WATERA_000…013): semitransparente por el alfa de vértice (0,5 en el océano) [V].
  if (t.name.startsWith("ANM_WATER")) return { alphaMode: "BLEND", extras: { ...base, blend: "agua" } };
  if (blend === 2 || blend === 6) return { alphaMode: "BLEND", extras: { ...base, blend: "aditiva" } };
  if (blend === 0) return usage === 1 ? { alphaMode: "MASK", alphaCutoff: ALPHA_REF, extras: base } : { alphaMode: "OPAQUE", extras: base };
  // Mezcla normal: con alfa útil (MODULATED) es una calcomanía; sin alfa (NONE) es opaca a efectos prácticos.
  if (usage === 0) return { alphaMode: "OPAQUE", extras: base };
  return { alphaMode: "BLEND", extras: { ...base, blend: usage === 1 ? "recorte_mezcla" : "mezcla" } };
}
