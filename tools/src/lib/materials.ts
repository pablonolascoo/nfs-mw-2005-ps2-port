// Tabla de materiales compartida por un GLB: textura por hash → PNG embebido; sin textura → color estable.
import type { GlbImage, GlbMaterial } from "./glb";
import type { Texture } from "./tex-ps2";
import { encodePng } from "./png";
import { hex8 } from "./hash";

export class MaterialTable {
  materials: GlbMaterial[] = [];
  images: GlbImage[] = [];
  private byHash = new Map<string, number>();
  missing = new Set<number>();
  /** external: carpeta donde escribir PNG compartidos y prefijo de URI relativo al GLB. */
  constructor(private textures: Map<number, Texture>, private opts: { unlit?: boolean; external?: { dir: string; uriPrefix: string; written: Set<number> } } = {}) {}

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
        this.images.push({ name: t.name, uri: `${ext.uriPrefix}${hex8(t.nameHash)}.png` });
      } else this.images.push({ name: t.name, png: encodePng(t.rgba, t.width, t.height) });
      m = { name: t.name, color: [1, 1, 1, 1], texture: this.images.length - 1, unlit: this.opts.unlit, ...alphaFor(t) };
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

/**
 * Modo de alfa según TextureInfo.AlphaUsageType / AlphaBlendType [tipos de la decomp, verificado con el asfalto].
 * MODULATED + SRCCOPY = el alfa no es transparencia (p. ej. asfalto): opaco.
 */
export function alphaFor(t: Texture): Pick<GlbMaterial, "alphaMode" | "alphaCutoff" | "extras"> {
  const usage = t.alphaUsage, blend = t.alphaBlend;
  // Sombras horneadas (SHD_*): RGB negro y alfa = densidad de sombra; se mezclan encima del suelo [verificado: 1 026 texturas].
  if (t.name.startsWith("SHD_")) return { alphaMode: "BLEND", extras: { blend: "sombra" } };
  // Agua animada (ANM_WATERA_000…013): semitransparente por el alfa de vértice (0,5 en el océano) [verificado].
  if (t.name.startsWith("ANM_WATER")) return { alphaMode: "BLEND", extras: { blend: "agua" } };
  if (usage === 0 || (usage === 2 && blend === 0)) return { alphaMode: "OPAQUE" };
  if (blend === 2 || blend === 6) return { alphaMode: "BLEND", extras: { blend: "aditiva" } };
  if (usage === 1) return { alphaMode: "MASK", alphaCutoff: 0.5 };
  return { alphaMode: "MASK", alphaCutoff: 0.3 };
}
