// Clasificación provisional por cabecera. Siempre "probable": se confirma leyendo la estructura.
const CHUNKS: Record<number, string> = {
  0x80134000: "bChunk: lista de sólidos (geometría)",
  0x30300001: "bChunk: pack de texturas PS2",
  0xb3300000: "bChunk: pack de texturas (TPK, tipo PC)",
  0x00034110: "bChunk: tabla de secciones de streaming",
  0x80034100: "bChunk: escenario (scenery)",
  0x00039000: "bChunk: atributos/VLT?",
};

export function sniff(head: Uint8Array): { format: string; confidence: "alta" | "media" | "baja" } {
  if (head.length < 8) return { format: "vacío/muy pequeño", confidence: "baja" };
  const dv = new DataView(head.buffer, head.byteOffset, head.byteLength);
  const ascii = new TextDecoder("latin1").decode(head.subarray(0, 4));
  if (["JDLZ", "COMP", "RAWW", "HUFF"].includes(ascii)) return { format: `comprimido ${ascii}`, confidence: "alta" };
  if (ascii === "SCHl" || ascii === "SHEN" || ascii === "SHDE") return { format: `audio/vídeo EA (${ascii})`, confidence: "media" };
  if (ascii === "MVhd" || ascii === "MPCh") return { format: `vídeo EA (${ascii})`, confidence: "media" };
  if (head[0] === 0x7f && ascii.slice(1) === "ELF") return { format: "ELF (código/NIS)", confidence: "alta" };
  const id = dv.getUint32(0, true), size = dv.getUint32(4, true);
  if (CHUNKS[id]) return { format: CHUNKS[id], confidence: "media" };
  if ((id & 0x7fffffff) !== 0 && size > 0 && (id >>> 16) !== 0 && (id & 0x0000ff00) <= 0xff00) return { format: `bChunk? id 0x${id.toString(16).padStart(8, "0")}`, confidence: "baja" };
  return { format: "desconocido", confidence: "baja" };
}
