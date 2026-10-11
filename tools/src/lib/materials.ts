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
  constructor(private textures: Map<number, Texture>) {}

  get(hash: number | undefined): number {
    const key = hash === undefined ? "none" : hex8(hash);
    const hit = this.byHash.get(key);
    if (hit !== undefined) return hit;
    const t = hash !== undefined ? this.textures.get(hash) : undefined;
    let m: GlbMaterial;
    if (t) {
      this.images.push({ name: t.name, png: encodePng(t.rgba, t.width, t.height) });
      let minA = 255; for (let i = 3; i < t.rgba.length; i += 4) minA = Math.min(minA, t.rgba[i]);
      m = { name: t.name, color: [1, 1, 1, 1], texture: this.images.length - 1, alphaMode: minA < 250 ? "MASK" : "OPAQUE" };
    } else {
      if (hash !== undefined) this.missing.add(hash);
      const h = hash ?? 0x9e3779b9, r = 0.35 + ((h & 0xff) / 255) * 0.4, g = 0.35 + (((h >> 8) & 0xff) / 255) * 0.4, b = 0.35 + (((h >> 16) & 0xff) / 255) * 0.4;
      m = { name: `sin_textura_${key}`, color: [r, g, b, 1] };
    }
    this.materials.push(m);
    this.byHash.set(key, this.materials.length - 1);
    return this.materials.length - 1;
  }
}
