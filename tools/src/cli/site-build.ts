// Web del proyecto (rockport-native.vercel.app): genera la versión en castellano (/) y en inglés (/en/) desde una sola
// plantilla, con SEO, GEO y AEO completos:
//   · cada página solo lleva su idioma (los elementos data-es / data-en del otro se quitan al generar)
//   · <head> propio: título, descripción, canonical, hreflang (es, en, x-default), Open Graph, Twitter, iconos
//   · JSON-LD: WebSite, SoftwareApplication (versión, descarga, sistema, licencia) y FAQPage con las mismas preguntas
//     y respuestas que se ven en la página
//   · robots.txt (buscadores y bots de IA permitidos), sitemap.xml con alternativas de idioma, llms.txt, clave IndexNow
// Uso: bun src/cli/site-build.ts   (desde tools/; escribe en ../site)
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "../../..");
const SITE = join(ROOT, "site");
const URL = "https://rockport-native.vercel.app";
const REPO = "https://github.com/pablonolascoo/nfs-mw-2005-ps2-port";
const VERSION = readFileSync(join(ROOT, "native-engine/VERSION"), "utf8").trim();
const DATE = new Date().toISOString().slice(0, 10);
export const INDEXNOW_KEY = "b04314ee624181c9a34be8144a72012c";

type Lang = "es" | "en";
const T = {
  es: {
    path: "/", locale: "es_ES",
    title: "Need for Speed: Most Wanted nativo en Mac | Rockport Native",
    desc: "Juega a NFS Most Wanted (2005) nativo en Mac desde tu propia ISO de PS2: motor Swift y Metal a 60 fps, física, IA, historia y guiones originales. Gratis y de código abierto.",
    date: new Date(DATE).toLocaleDateString("es-ES", { day: "numeric", month: "long", year: "numeric" }),
    faqTitle: ["Preguntas", "frecuentes"], faqKicker: "Lo que más se pregunta",
    altLabel: "EN",
  },
  en: {
    path: "/en/", locale: "en_US",
    title: "Need for Speed: Most Wanted native on Mac | Rockport Native",
    desc: "Play NFS Most Wanted (2005) natively on Mac from your own PS2 ISO: a Swift and Metal engine at 60 fps with the original physics, AI, story and scripts. Free and open source.",
    date: new Date(DATE).toLocaleDateString("en-US", { day: "numeric", month: "long", year: "numeric" }),
    faqTitle: ["Frequently asked", "questions"], faqKicker: "What people ask",
    altLabel: "ES",
  },
} as const;

// Preguntas frecuentes: lo mismo en la página y en el JSON-LD (respuestas de 40–60 palabras que se entienden solas).
const FAQ: { es: [string, string]; en: [string, string] }[] = [
  { es: ["¿Qué es Rockport Native?", "Rockport Native es un port nativo para Mac de Need for Speed: Most Wanted (2005) de PlayStation 2. Un motor propio en Swift y Metal lee tu ISO, convierte los datos del juego y lo ejecuta a pantalla completa y 60 fps, con la física, la inteligencia artificial, la interfaz y los guiones de la historia originales."],
    en: ["What is Rockport Native?", "Rockport Native is a native Mac port of Need for Speed: Most Wanted (2005) for PlayStation 2. Its own Swift and Metal engine reads your ISO, converts the game data and runs it full screen at 60 fps, with the original physics, artificial intelligence, interface and story scripts."] },
  { es: ["¿Incluye el juego o necesito mi propia ISO?", "No incluye ningún dato del juego. Necesitas tu propia copia de PS2: la versión europea PAL (SLES-53559) o la americana NTSC-U (SLUS-21351). El instalador detecta la región leyendo el disco y convierte los datos en tu Mac en alrededor de un minuto. Nada del juego se sube a internet."],
    en: ["Does it include the game, or do I need my own ISO?", "It includes no game data. You need your own PS2 copy: the European PAL release (SLES-53559) or the American NTSC-U release (SLUS-21351). The installer detects the region by reading the disc and converts the data on your Mac in about a minute. Nothing from the game is uploaded anywhere."] },
  { es: ["¿En qué Mac funciona y cuánto cuesta?", `Funciona en Mac con Apple Silicon y macOS 14 o posterior. Es gratis y de código abierto con licencia MIT; la versión actual es la ${VERSION}, que se descarga como .dmg desde GitHub. Se juega con teclado o con mandos de Xbox, PS5, PS4, PS3 y PS2 por USB.`],
    en: ["Which Macs does it run on, and how much does it cost?", `It runs on Apple Silicon Macs with macOS 14 or later. It is free and open source under the MIT licence; the current version is ${VERSION}, downloaded as a .dmg from GitHub. You can play with a keyboard or with Xbox, PS5, PS4, PS3 and PS2 controllers over USB.`] },
  { es: ["¿Es un emulador de PS2?", "No. Es un port: el juego se reconstruye con un motor nativo en vez de emular la consola. Se ha entendido el 99,94 % del disco, se han desensamblado las 18 909 funciones del ejecutable y el motor ejecuta los 258 guiones Lua originales que mueven la historia y las carreras."],
    en: ["Is it a PS2 emulator?", "No. It is a port: the game is rebuilt on a native engine instead of emulating the console. 99.94 % of the disc is understood, all 18,909 functions of the executable have been disassembled, and the engine runs the 258 original Lua scripts that drive the story and the races."] },
  { es: ["¿Habrá versión para Windows o para móvil?", "Hoy solo hay versión para Mac, pero el proyecto está pensado para llegar a Windows y a móvil. Todo el trabajo de ingeniería inversa (formatos del disco, base de datos, física y guiones) es independiente de la plataforma y está documentado en castellano y en inglés en el repositorio."],
    en: ["Will there be a Windows or mobile version?", "Today there is only a Mac version, but the project is designed to reach Windows and mobile. All the reverse-engineering work (disc formats, database, physics and scripts) is platform independent and documented in Spanish and English in the repository."] },
  { es: ["¿Qué es la expansión Rust Belt?", "Es una ampliación propuesta por la comunidad que continúa la historia tras vencer a la Lista Negra: cuatro distritos nuevos junto a Rockport (Millbrook, Ironwood, Calder Bay y Black Hollow), una segunda Lista Negra y coches clásicos. Está diseñada sobre el mapa real del juego, pero todavía no es jugable."],
    en: ["What is the Rust Belt expansion?", "It is a community-proposed expansion that continues the story after beating the Blacklist: four new districts next to Rockport (Millbrook, Ironwood, Calder Bay and Black Hollow), a second Blacklist and classic cars. It is designed on the game's real map, but it is not playable yet."] },
  { es: ["¿Cómo puedo colaborar?", "El repositorio es público en GitHub y acepta contribuciones mediante pull requests revisadas. Hace falta ayuda en el motor nativo (Swift y Metal), en ingeniería inversa de los formatos y guiones, en modelado propio de coches y en el diseño de los distritos de la expansión."],
    en: ["How can I contribute?", "The repository is public on GitHub and accepts contributions through reviewed pull requests. Help is needed on the native engine (Swift and Metal), on reverse engineering formats and scripts, on original car modelling and on designing the expansion's districts."] },
];

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function head(l: Lang): string {
  const t = T[l], url = URL + t.path;
  const ld = {
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "WebSite", "@id": `${URL}/#web`, url: URL + "/", name: "Rockport Native", inLanguage: ["es", "en"],
        description: T.es.desc, publisher: { "@id": `${URL}/#autor` } },
      { "@type": "Person", "@id": `${URL}/#autor`, name: "Pablo Nolasco", url: "https://github.com/pablonolascoo" },
      { "@type": "SoftwareApplication", "@id": `${URL}/#app`, name: "Rockport Native", alternateName: ["NFS Most Wanted para Mac", "Need for Speed Most Wanted Mac port"],
        applicationCategory: "GameApplication", applicationSubCategory: "Racing game port", operatingSystem: "macOS 14 or later (Apple Silicon)",
        softwareVersion: VERSION, dateModified: DATE, inLanguage: l, url, downloadUrl: `${REPO}/releases/latest`,
        codeRepository: REPO, license: "https://opensource.org/licenses/MIT", isAccessibleForFree: true,
        offers: { "@type": "Offer", price: "0", priceCurrency: "EUR" },
        image: `${URL}/img/og.jpg`, screenshot: [`${URL}/img/hud.jpg`, `${URL}/img/persecucion.jpg`, `${URL}/img/carrera.jpg`],
        description: t.desc, author: { "@id": `${URL}/#autor` },
        isBasedOn: { "@type": "VideoGame", name: "Need for Speed: Most Wanted", datePublished: "2005-11-15", gamePlatform: "PlayStation 2",
          publisher: { "@type": "Organization", name: "Electronic Arts" } },
        requirements: l === "es" ? "Tu propia ISO de PS2: SLES-53559 (PAL) o SLUS-21351 (NTSC-U)" : "Your own PS2 ISO: SLES-53559 (PAL) or SLUS-21351 (NTSC-U)" },
      { "@type": "FAQPage", "@id": `${url}#faq`, inLanguage: l,
        mainEntity: FAQ.map(q => ({ "@type": "Question", name: q[l][0], acceptedAnswer: { "@type": "Answer", text: q[l][1] } })) },
    ],
  };
  return `<title>${esc(t.title)}</title>
<meta name="description" content="${esc(t.desc)}" />
<link rel="canonical" href="${url}" />
<link rel="alternate" hreflang="es" href="${URL}/" />
<link rel="alternate" hreflang="en" href="${URL}/en/" />
<link rel="alternate" hreflang="x-default" href="${URL}/" />
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1" />
<meta name="theme-color" content="#0a0b09" />
<link rel="icon" href="/favicon.png" type="image/png" />
<link rel="apple-touch-icon" href="/apple-touch-icon.png" />
<meta property="og:type" content="website" />
<meta property="og:site_name" content="Rockport Native" />
<meta property="og:locale" content="${t.locale}" />
<meta property="og:locale:alternate" content="${l === "es" ? "en_US" : "es_ES"}" />
<meta property="og:url" content="${url}" />
<meta property="og:title" content="${esc(t.title)}" />
<meta property="og:description" content="${esc(t.desc)}" />
<meta property="og:image" content="${URL}/img/og.jpg" />
<meta property="og:image:width" content="1200" />
<meta property="og:image:height" content="630" />
<meta property="og:image:alt" content="${l === "es" ? "El BMW M3 GTR de Most Wanted en el motor nativo de Mac" : "The Most Wanted BMW M3 GTR in the native Mac engine"}" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="${esc(t.title)}" />
<meta name="twitter:description" content="${esc(t.desc)}" />
<meta name="twitter:image" content="${URL}/img/og.jpg" />
<link rel="alternate" type="text/plain" href="${URL}/llms.txt" title="llms.txt" />
<script type="application/ld+json">${JSON.stringify(ld)}</script>
`;
}

function faqSection(l: Lang): string {
  const t = T[l];
  const items = FAQ.map(q => `        <details${q === FAQ[0] ? " open" : ""}><summary>${esc(q[l][0])}</summary><p>${esc(q[l][1])}</p></details>`).join("\n");
  return `  <section id="faq">
    <div class="wrap">
      <div class="kicker">${t.faqKicker}</div>
      <h2>${t.faqTitle[0]}<br />${t.faqTitle[1]}</h2>
      <div class="faq">
${items}
      </div>
    </div>
  </section>

`;
}

async function page(l: Lang): Promise<string> {
  const other: Lang = l === "es" ? "en" : "es";
  let html = readFileSync(join(SITE, "src/index.html"), "utf8")
    .replace("<!--HEAD-->", head(l))
    .replace("<!--FAQ-->", faqSection(l))
    .replaceAll("{{LANG}}", l).replaceAll("{{HOME}}", T[l].path)
    .replaceAll("{{ALT_URL}}", T[other].path).replaceAll("{{ALT_LANG}}", other).replaceAll("{{ALT_LABEL}}", T[l].altLabel)
    .replaceAll("{{VERSION}}", VERSION).replaceAll("{{DATE}}", DATE).replaceAll("{{DATE_TEXT}}", T[l].date);
  // Solo el idioma de la página: fuera los elementos del otro y el atributo en los que quedan
  const rw = new HTMLRewriter()
    .on(`[data-${other}]`, { element(e) { e.remove(); } })
    .on(`[data-${l}]`, { element(e) { e.removeAttribute(`data-${l}`); } });
  html = await rw.transform(new Response(html)).text();
  if (/\{\{|<!--(HEAD|FAQ)-->/.test(html)) throw new Error(`${l}: quedan marcadores sin rellenar`);
  return html;
}

writeFileSync(join(SITE, "index.html"), await page("es"));
mkdirSync(join(SITE, "en"), { recursive: true });
writeFileSync(join(SITE, "en/index.html"), await page("en"));

writeFileSync(join(SITE, "robots.txt"), `# Rockport Native: todo abierto a buscadores y a asistentes de IA (búsqueda, consulta y entrenamiento)
User-agent: *
Allow: /

User-agent: Googlebot
User-agent: Bingbot
User-agent: OAI-SearchBot
User-agent: ChatGPT-User
User-agent: GPTBot
User-agent: Claude-SearchBot
User-agent: Claude-User
User-agent: ClaudeBot
User-agent: PerplexityBot
User-agent: Perplexity-User
User-agent: Google-Extended
User-agent: Applebot-Extended
Allow: /

Sitemap: ${URL}/sitemap.xml
`);

const alt = `\n    <xhtml:link rel="alternate" hreflang="es" href="${URL}/" />\n    <xhtml:link rel="alternate" hreflang="en" href="${URL}/en/" />\n    <xhtml:link rel="alternate" hreflang="x-default" href="${URL}/" />`;
const img = (p: string, title: string) => `\n    <image:image><image:loc>${URL}/img/${p}</image:loc><image:title>${esc(title)}</image:title></image:image>`;
writeFileSync(join(SITE, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
  <url>
    <loc>${URL}/</loc>
    <lastmod>${DATE}</lastmod>${alt}${img("hud.jpg", "HUD original de Most Wanted en el motor nativo de Mac")}${img("persecucion.jpg", "Persecución policial en el motor nativo")}${img("bmw.jpg", "BMW M3 GTR con su pintura de la historia")}
  </url>
  <url>
    <loc>${URL}/en/</loc>
    <lastmod>${DATE}</lastmod>${alt}${img("hud.jpg", "Original Most Wanted HUD in the native Mac engine")}${img("persecucion.jpg", "Police pursuit in the native engine")}
  </url>
</urlset>
`);

writeFileSync(join(SITE, "llms.txt"), `# Rockport Native

> Native macOS port of Need for Speed: Most Wanted (2005, PlayStation 2), built from the player's own PS2 ISO. Open source (MIT), free, no game data included. Current version: ${VERSION} (updated ${DATE}).

Rockport Native is a fan reverse-engineering project. A Swift + Metal engine reads the user's PS2 disc image (PAL SLES-53559 or NTSC-U SLUS-21351), converts the game data on the Mac in about one minute and runs the game natively at 60 fps on Apple Silicon (macOS 14+). It is not an emulator: the game is rebuilt on a native engine.

## Key facts
- Platform: macOS 14 or later, Apple Silicon. Windows and mobile are planned, not available.
- Price: free. Licence: MIT. Download: ${REPO}/releases/latest (.dmg).
- Requirement: the user's own legal copy of the game; no game data is distributed.
- 99.94 % of the disc's bytes are understood; all 18,909 functions of the executable have been disassembled (Ghidra + REA).
- The game's story and race conditions are 258 Lua 5.0 scripts stored in GAMEPLAY.BIN; the engine runs them as they are.
- Working: whole Rockport city, original interface and HUD, game physics, traffic, police and pursuits, races and the Blacklist (15 → 1), story prologue (D-Day), garages, sound, movies with the disc's dub, EA Trax music, controllers (Xbox, PS5, PS4, PS3, PS2), 2–4 player split screen.
- Next: volumetric fog, NIS cutscenes, pause map, call voices.
- Expansion "Rust Belt" (proposal): four new districts (Millbrook, Ironwood, Calder Bay, Black Hollow), a second Blacklist and classic cars.
- Not affiliated with Electronic Arts. Need for Speed is a trademark of Electronic Arts.

## Pages
- [Website (Spanish)](${URL}/): overview, status, FAQ.
- [Website (English)](${URL}/en/): same content in English.
- [Source code and README](${REPO}): build instructions, user guide, screenshots.
- [Roadmap](${REPO}/blob/main/ROADMAP.en.md): what is done and what comes next.
- [Technical documentation](${REPO}/tree/main/docs/en): disc formats, physics, AI, interface, races, audio, scripts (docs 00–26).
- [Releases](${REPO}/releases): downloadable .dmg builds and changelogs.
`);

writeFileSync(join(SITE, `${INDEXNOW_KEY}.txt`), INDEXNOW_KEY);
console.log(`Web generada: / y /en/ (v${VERSION}, ${DATE}) · robots.txt · sitemap.xml · llms.txt · clave IndexNow`);
