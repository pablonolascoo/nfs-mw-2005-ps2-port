// Plano de la propuesta de expansión «Rust Belt» → docs/expansion/mapa-expansion.svg
// Rockport se dibuja con su red de carreteras real (map-data/<ID>/roads.json, Bézier en mundo, Z arriba).
// Las zonas nuevas son una PROPUESTA de diseño (ver ROADMAP.md): posiciones y formas inventadas, no datos del juego.
// Uso: bun src/cli/expansion-map.ts [ID=SLES-53559]
import { outDir, repoRoot } from "../lib/paths";

const id = Bun.argv[2] ?? "SLES-53559";
const roads = await Bun.file(`${outDir(id)}/roads.json`).json() as {
  nodes: { p: number[] }[]; segments: { nodes: number[]; startControl: number[]; endControl: number[]; road: number }[];
};

// Ventana del plano en metros (mundo). Rockport ocupa ≈ X −1400…4860, Y −990…4570.
const W = { x0: -4900, x1: 7500, y0: -3900, y1: 9500 };
const PX = 1600, S = PX / (W.x1 - W.x0), H = Math.round((W.y1 - W.y0) * S);
const sx = (x: number) => +((x - W.x0) * S).toFixed(1), sy = (y: number) => +((W.y1 - y) * S).toFixed(1);

// Carreteras reales: cada tramo como curva cúbica
let path = "";
for (const s of roads.segments) {
  const a = roads.nodes[s.nodes[0]].p, b = roads.nodes[s.nodes[1]].p;
  const c1 = [a[0] + s.startControl[0], a[1] + s.startControl[1]], c2 = [b[0] + s.endControl[0], b[1] + s.endControl[1]];
  path += `M${sx(a[0])} ${sy(a[1])}C${sx(c1[0])} ${sy(c1[1])} ${sx(c2[0])} ${sy(c2[1])} ${sx(b[0])} ${sy(b[1])}`;
}

// Zonas propuestas: orden = orden de desbloqueo tras vencer a la Lista Negra original
const zones = [
  { n: 1, es: "MILLBROOK", sub: "Pueblo obrero · nuevo refugio", en: "Working-class town · new safehouse", bl: "#15–#11",
    poly: [[1300, 5500], [4600, 5300], [5400, 6400], [4700, 7900], [2200, 8100], [1100, 7000]] },
  { n: 2, es: "ACERÍAS DEL RÍO", sub: "Altos hornos · vías de tren", en: "Steelworks · rail yards", bl: "#10–#6",
    poly: [[-4300, -1700], [-1700, -2100], [-1200, -400], [-1500, 1900], [-3200, 2400], [-4500, 900]] },
  { n: 3, es: "PUERTO DE MERCANCÍAS", sub: "Grúas · contenedores · muelles", en: "Cranes · containers · piers", bl: "#5–#2",
    poly: [[1700, -1500], [4400, -1300], [6900, -2100], [6700, -3500], [3200, -3600], [1500, -2600]] },
  { n: 4, es: "SIERRA ALTA", sub: "Puerto de montaña · presa · túneles", en: "Mountain pass · dam · tunnels", bl: "#1",
    poly: [[-4500, 3200], [-1600, 3000], [-800, 4600], [-1300, 7300], [-3600, 8300], [-4600, 6000]] },
];
// Interestatal propuesta (I-99) que une las zonas nuevas por fuera de la ciudad, y los accesos desde Rockport
const interstate = [[-1500, 1900], [-929, 2700], [-1000, 4300], [-600, 5900], [600, 5700], [2000, 5450], [3600, 5000]];
const links = [
  [[3600, 5000], [3300, 4400]],                          // puente norte desde Rosewood/Camden
  [[-317, -151], [-1300, -500], [-1700, -900]],         // salida suroeste hacia las acerías
  [[2000, -700], [2300, -1300], [2700, -1700]],          // salida sur hacia el puerto
];
const pl = (pts: number[][]) => pts.map((p, i) => `${i ? "L" : "M"}${sx(p[0])} ${sy(p[1])}`).join("");
const centroid = (pts: number[][]) => [pts.reduce((a, p) => a + p[0], 0) / pts.length, pts.reduce((a, p) => a + p[1], 0) / pts.length];

const amber = "#ffb21a", fog = "#8d9483", paper = "#e9ecdf", ink = "#0a0b09";
const font = `font-family="'Big Shoulders Display','Arial Narrow','Helvetica Neue',Arial,sans-serif"`;
const mono = `font-family="'IBM Plex Mono',ui-monospace,Menlo,monospace"`;

let z = "";
for (const q of zones) {
  const [cx, cy] = centroid(q.poly);
  z += `<path d="${pl(q.poly)}Z" fill="${amber}" fill-opacity=".09" stroke="${amber}" stroke-width="2" stroke-dasharray="10 6"/>`;
  z += `<g transform="translate(${sx(cx)} ${sy(cy)})">`;
  z += `<rect x="-20" y="-62" width="40" height="40" fill="${amber}"/><text x="0" y="-31" text-anchor="middle" ${font} font-weight="900" font-size="30" fill="${ink}">${q.n}</text>`;
  z += `<text x="0" y="6" text-anchor="middle" ${font} font-weight="900" font-size="34" letter-spacing="1" fill="${paper}">${q.es}</text>`;
  z += `<text x="0" y="28" text-anchor="middle" ${mono} font-size="13" fill="${fog}">${q.sub}</text>`;
  z += `<text x="0" y="46" text-anchor="middle" ${mono} font-size="12" fill="${fog}" opacity=".75">${q.en}</text>`;
  z += `<text x="0" y="68" text-anchor="middle" ${mono} font-size="13" fill="${amber}">LISTA NEGRA 2 · ${q.bl}</text></g>`;
}

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${PX} ${H}" width="${PX}" height="${H}">
<rect width="100%" height="100%" fill="${ink}"/>
<defs><pattern id="g" width="64" height="64" patternUnits="userSpaceOnUse"><path d="M64 0H0V64" fill="none" stroke="#1b1e18" stroke-width="1"/></pattern></defs>
<rect width="100%" height="100%" fill="url(#g)"/>
${z}
<path d="${pl(interstate)}" fill="none" stroke="${amber}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>
${links.map(l => `<path d="${pl(l)}" fill="none" stroke="${amber}" stroke-width="3" stroke-dasharray="6 6" stroke-linecap="round"/>`).join("")}
<path d="${path}" fill="none" stroke="${paper}" stroke-width="1.1" stroke-opacity=".75"/>
<text x="${sx(1500)}" y="${sy(2300)}" text-anchor="middle" ${font} font-weight="900" font-size="64" fill="${paper}" stroke="${ink}" stroke-width="8" paint-order="stroke">ROCKPORT</text>
<text x="${sx(1500)}" y="${sy(2300) + 26}" text-anchor="middle" ${mono} font-size="14" fill="${fog}" stroke="${ink}" stroke-width="5" paint-order="stroke">red de carreteras real del juego · real in-game road network</text>
<text x="${sx(-700)}" y="${sy(4300)}" ${mono} font-size="14" font-weight="600" fill="${amber}">I-99</text>
<g transform="translate(40 52)">
<rect x="-4" y="-34" width="62" height="44" fill="${amber}"/><text x="27" y="0" text-anchor="middle" ${font} font-weight="900" font-size="34" fill="${ink}">MW</text>
<text x="76" y="-4" ${font} font-weight="900" font-size="40" fill="${paper}">EXPANSIÓN «RUST BELT»</text>
<text x="76" y="20" ${mono} font-size="14" fill="${fog}">Propuesta de fans · se desbloquea al vencer a la Lista Negra original</text>
</g>
<g transform="translate(40 ${H - 92})" ${mono} font-size="13" fill="${fog}">
<line x1="0" y1="0" x2="40" y2="0" stroke="${paper}" stroke-width="1.5"/><text x="52" y="4">Rockport (juego original)</text>
<line x1="0" y1="24" x2="40" y2="24" stroke="${amber}" stroke-width="5"/><text x="52" y="28">Interestatal I-99 (nueva)</text>
<line x1="0" y1="48" x2="40" y2="48" stroke="${amber}" stroke-width="3" stroke-dasharray="6 6"/><text x="52" y="52">Accesos nuevos desde Rockport</text>
<rect x="300" y="-8" width="40" height="16" fill="${amber}" fill-opacity=".09" stroke="${amber}" stroke-dasharray="6 4"/><text x="352" y="4">Distrito nuevo · número = orden de desbloqueo</text>
<text x="300" y="52">1 km ≈ ${(1000 * S).toFixed(0)} px · norte arriba</text>
</g>
</svg>`;
const out = `${repoRoot}docs/expansion/mapa-expansion.svg`;
await Bun.write(out, svg);
console.log(`Plano: ${out} (${PX}×${H}, ${roads.segments.length} tramos reales)`);
