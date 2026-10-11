// Lector mínimo de ISO9660 (solo lectura). Suficiente para discos de PS2.
const SECTOR = 2048;

export interface IsoEntry { path: string; lba: number; size: number; isDir: boolean }

export class IsoImage {
  constructor(public readonly path: string) {}

  async read(offset: number, length: number): Promise<Uint8Array> {
    const buf = new Uint8Array(await Bun.file(this.path).slice(offset, offset + length).arrayBuffer());
    if (buf.length !== length) throw new Error(`Lectura corta en ${this.path} @${offset}: ${buf.length}/${length}`);
    return buf;
  }

  async list(): Promise<IsoEntry[]> {
    const pvd = await this.read(16 * SECTOR, SECTOR);
    const magic = new TextDecoder().decode(pvd.subarray(1, 6));
    if (pvd[0] !== 1 || magic !== "CD001") throw new Error("No es un volumen ISO9660 (falta PVD CD001)");
    const root = this.parseRecord(pvd, 156)!;
    const out: IsoEntry[] = [];
    await this.walk(root.lba, root.size, "", out);
    return out;
  }

  private parseRecord(b: Uint8Array, o: number) {
    const len = b[o];
    if (!len) return null;
    const dv = new DataView(b.buffer, b.byteOffset);
    const nameLen = b[o + 32];
    let name = new TextDecoder("latin1").decode(b.subarray(o + 33, o + 33 + nameLen));
    name = name.replace(/;1$/, "");
    return { len, lba: dv.getUint32(o + 2, true), size: dv.getUint32(o + 10, true), isDir: (b[o + 25] & 2) !== 0, name };
  }

  private async walk(lba: number, size: number, prefix: string, out: IsoEntry[]) {
    const data = await this.read(lba * SECTOR, Math.ceil(size / SECTOR) * SECTOR);
    let o = 0;
    while (o < size) {
      const r = this.parseRecord(data, o);
      if (!r) { o = (Math.floor(o / SECTOR) + 1) * SECTOR; continue; } // relleno hasta fin de sector
      o += r.len;
      if (r.name === "\u0000" || r.name === "\u0001") continue; // "." y ".."
      const path = prefix + r.name;
      out.push({ path, lba: r.lba, size: r.size, isDir: r.isDir });
      if (r.isDir) await this.walk(r.lba, r.size, path + "/", out);
    }
  }
}
