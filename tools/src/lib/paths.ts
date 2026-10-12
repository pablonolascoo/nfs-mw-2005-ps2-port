// Rutas de salida y datos propios incrustados.
// - En el repo, todo se escribe en map-data/<ID>/ e inventory/ (como siempre).
// - Dentro de la app (conversor compilado con `bun build --compile`), ROCKPORT_OUT apunta a la carpeta destino
//   (~/Library/Application Support/Rockport/<ID>/) y todo va ahí, inventario incluido.
// Las listas de nombres de tools/data se incrustan en el binario: no hace falta el repo ni la decomp.
import attribNamesText from "../../data/attrib-names.txt" with { type: "text" };
import filenamesMain from "../../data/filenames-mw-ps2.list" with { type: "text" };
import filenamesExtra from "../../data/filenames-extra.list" with { type: "text" };

export const repoRoot = new URL("../../../", import.meta.url).pathname;
/** true cuando corre como binario compilado (sin repo alrededor). */
export const compiled = import.meta.path.startsWith("/$bunfs") || import.meta.path.startsWith("B:\\~BUN");

export function outDir(id: string): string {
  return process.env.ROCKPORT_OUT ?? `${repoRoot}map-data/${id}`;
}
export function inventoryDir(): string {
  return process.env.ROCKPORT_OUT ? `${process.env.ROCKPORT_OUT}/inventory` : `${repoRoot}inventory`;
}
export const embedded = { attribNames: attribNamesText, filenameLists: [filenamesMain, filenamesExtra] };
