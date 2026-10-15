// Iconos 3D de la partida guardada (MEMCARD\*.ICO): formato estándar de PS2 [I: formato público «PS2 icon»][V: los 2 iconos del disco].
//   cabecera 20 B: u32 0x00010000 · u32 nº de formas (shapes) · u32 tipo de textura (bit 3 = comprimida) · f32 1.0 · u32 nº de vértices
//   vértices: por vértice, formas × {s16 x, y, z, w} + normal {s16 × 4} + UV {s16 u, v} + color RGBA (4 B)   (× 1/4096 en posición)
//   animación: u32 1 · u32 duración · f32 velocidad · u32 desfase · u32 nº de fotogramas · por fotograma {u32 forma, u32 nº de claves,
//              claves {f32 tiempo, f32 valor}}
//   textura 128×128 RGB5A1: comprimida = u32 tamaño + RLE de u16 (código & 0x8000 → 0x10000 − código píxeles literales;
//              si no, el siguiente píxel repetido «código» veces); sin comprimir = 32 768 B.
export interface Ps2Icon { shapes: number; vertices: number; frames: number; texture: Uint16Array }

export function parsePs2Icon(b: Uint8Array): Ps2Icon {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (dv.getUint32(0, true) !== 0x00010000) throw new Error("no es un icono de PS2");
  const shapes = dv.getUint32(4, true), texType = dv.getUint32(8, true), vertices = dv.getUint32(16, true);
  let o = 20 + vertices * (shapes * 8 + 8 + 4 + 4);
  if (dv.getUint32(o, true) !== 1) throw new Error("cabecera de animación inesperada");
  const frames = dv.getUint32(o + 16, true);
  o += 20;
  for (let f = 0; f < frames; f++) o += 8 + dv.getUint32(o + 4, true) * 8;
  const texture = new Uint16Array(128 * 128);
  if (texType & 8) {
    const size = dv.getUint32(o, true); o += 4;
    const end = o + size;
    let n = 0;
    while (o < end && n < texture.length) {
      const code = dv.getUint16(o, true); o += 2;
      if (code & 0x8000) { for (let i = 0; i < 0x10000 - code; i++, o += 2) texture[n++] = dv.getUint16(o, true); }
      else { const px = dv.getUint16(o, true); o += 2; for (let i = 0; i < code; i++) texture[n++] = px; }
    }
    if (n !== texture.length || end !== b.length) throw new Error(`textura RLE: ${n} píxeles, ${b.length - end} B sobrantes`);
  } else for (let i = 0; i < texture.length; i++) texture[i] = dv.getUint16(o + i * 2, true);
  return { shapes, vertices, frames, texture };
}
