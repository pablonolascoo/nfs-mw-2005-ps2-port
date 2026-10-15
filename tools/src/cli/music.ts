// Música interactiva y mezcla del juego → map-data/<ID>/music/ (no se sube a git).
// Uso: bun src/cli/music.ts <iso> <ID>              copia .MPF/.MUS tal cual + music.json, mixmaps.json, reverbs.json, csi.json
//      bun src/cli/music.ts <iso> <ID> --audio      además cada muestra en FLAC (ffmpeg) en music/audio/<PROYECTO>/
//      bun src/cli/music.ts <iso> <ID> --check      compara TODAS las muestras con vgmstream-cli (si está instalado)
//      bun src/cli/music.ts <iso> <ID> --dump       grafo legible por consola
//
// Qué sale (formatos en src/lib/pathfinder.ts, src/lib/mixmap.ts y docs/es/25-musica-y-mezcla.md):
//   music/MW_MUSIC.MPF/.MUS, MW_MUS_1…4.MPF/.MUS   tal cual del disco (~400 MB). La app decodifica sola (EA-XA v2 por bloques).
//   music/music.json      proyectos PathFinder (nodos, ramas, eventos, variables, routers, muestras con desplazamiento y
//                         bloques), canciones de EA Trax (VLT «music»), ambientes por zona, partes de la persecución y la
//                         lógica del juego (MusicFlow / SFXObj_PFEATrax de la decomp).
//   music/mixmaps.json    SOUND\MIXMAPS: 4 mapas × 13 estados con nombres del .DYN.
//   music/reverbs.json    SOUND\FXEDIT: 15 presets + qué zona usa cada uno (decomp).
//   music/csi.json        interfaces Csis (SOUND\EVT_SYS y SOUND\SPEECH\*.CSI).
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { GameDisc } from "../lib/zdir";
import { loadCandidates } from "../lib/names";
import { outDir, embedded } from "../lib/paths";
import { AttribDatabase, Vault, parseVpak, type Value } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { encodeWav } from "../lib/microtalk";
import {
  parseMpf, parseMusStream, decodeMusStream, PFXMAP, PF_ENTRIES, AMBIENT_CROSSMAP, LICENSED_SPECIAL, CALLBACKS, type Mpf,
} from "../lib/pathfinder";
import { parseMixMap, attachNames, parseCsi, parseFx, ENVELOPES, type MixMap } from "../lib/mixmap";

const PROJECTS = ["MW_MUSIC", "MW_MUS_1", "MW_MUS_2", "MW_MUS_3", "MW_MUS_4"];
const MIXMAPS = ["MAPOUTPUT", "MAPOUTPUTDRG", "MAPOUTPUT2CR", "MAPOUTPUT2DR"];
/** szMixMapFiles[eMapType] [D: NFSMixMap.cpp]: 0 normal, 1 drag, 2 y 3 pantalla partida (2 coches) [I por el nombre]. */
const MIXMAP_ROLE: Record<string, string> = {
  MAPOUTPUT: "normal (szMixMapFiles[0])", MAPOUTPUTDRG: "carreras de aceleración / drag (szMixMapFiles[1])",
  MAPOUTPUT2CR: "dos jugadores, [I] 2CR (szMixMapFiles[2])", MAPOUTPUT2DR: "dos jugadores en drag, [I] 2DR (szMixMapFiles[3])",
};
/** csfxedit[] y ReverbZoneCrossMap[] [D: SFXObj_Reverb.cpp]: zona de reverb (ParameterMap «Reverb») → preset. */
const CSFXEDIT = ["City_Dense.fx", "Alley.fx", "City_Open.fx", "Garage.fx", "Garage_sml.fx", "Simple_Tunnel.fx", "Simple_Tunnel_Sml.fx", "Hills_Close.fx", "Hills.fx", "City_Open.fx", "City_Dense.fx", "Alley.fx"];
const REVERB_ZONES = ["RVRB_CARSHOW_SML", "RVRB_CARSHOW_BASS", "RVRB_CARSHOW_BASS_2", "RVRB_GARAGE", "RVRB_GARAGE_SML", "RVRB_SIMPLE_TUNNEL", "RVRB_SIMPLE_TUNNEL_SML", "RVRB_HILLS_CLOSE", "RVRB_HILLS", "RVRB_CITYOPEN", "RVRB_CITYDENSE", "RVRB_ALLEY"];
const AMBIENT_ZONE_NAMES: Record<number, string> = { 9: "refugio (FE)", 10: "taller de tuneo (FE)", 11: "menú (FE)", 12: "concesionario (FE)", 13: "ficha policial (rap sheet)" };

/** Muestras alcanzables desde un nodo siguiendo todas las ramas (sin repetir), sin entrar en los nodos de `stops`
 *  (las entradas de otros eventos: así un ambiente no se «come» el de la zona siguiente). */
function reach(m: Mpf, start: number, stops: Set<number> = new Set()) {
  const seen = new Set<number>(), samples: number[] = [], events: number[] = [];
  const st = [start];
  while (st.length) {
    const n = st.pop()!;
    if (seen.has(n) || !m.nodes[n] || (n !== start && stops.has(n))) continue;
    seen.add(n);
    const x = m.nodes[n];
    if (x.sample !== null && !samples.includes(x.sample)) samples.push(x.sample);
    if (x.wave === -3 && !events.includes(x.event)) events.push(x.event);
    for (const br of [...x.branches].reverse()) st.push(br.node);
  }
  return { nodes: [...seen].sort((a, b) => a - b), samples, events };
}
/** Nodos destino «ir a» (4/3) de un evento. */
const gotos = (m: Mpf, e: Mpf["events"][number]) => e.actions.filter(a => a.type === 4 && a.code === 3).map(a => a.params[0]);

export async function main(args: string[]) {
  const flag = (f: string) => { const i = args.indexOf(f); if (i < 0) return false; args.splice(i, 1); return true; };
  const audio = flag("--audio"), check = flag("--check"), dump = flag("--dump");
  const [iso, id] = args;
  if (!iso || !id) { console.error("Uso: bun src/cli/music.ts <iso> <ID> [--audio] [--check] [--dump]"); process.exit(1); }
  const disc = await GameDisc.open(iso);
  disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
  const read = async (name: string) => { const e = disc.find(name); if (!e) throw new Error(`No está en el disco: ${name}`); return disc.readEntry(e); };
  const out = `${outDir(id)}/music`;
  mkdirSync(out, { recursive: true });

  // 1) Proyectos PathFinder: .MPF + .MUS (copia tal cual; si ya está con el mismo tamaño no se vuelve a escribir)
  const mpfs = new Map<string, Mpf>(), musBytes = new Map<string, Uint8Array>();
  let copied = 0;
  for (const p of PROJECTS) {
    const mpfRaw = await read(`SOUND\\PFDATA\\${p}.MPF`);
    mpfs.set(p, parseMpf(mpfRaw));
    writeFileSync(`${out}/${p}.MPF`, mpfRaw);
    const e = disc.find(`SOUND\\PFDATA\\${p}.MUS`)!;
    const dst = `${out}/${p}.MUS`;
    if (!existsSync(dst) || statSync(dst).size !== e.size) { writeFileSync(dst, await disc.readEntry(e)); copied += e.size; }
    musBytes.set(p, new Uint8Array(readFileSync(dst)));
  }

  // 2) Base de atributos: canciones (clase «music») y orden de la lista (audiosystem.mwlicensedmusic.PFMapping)
  const db = new AttribDatabase();
  await loadAttribNames(db);
  for (const e of parseVpak(await read("GLOBAL\\ATTRIBUTES.BIN"))) db.addVault(new Vault(e.name, e.vlt, e.bin));
  const music = new Map<string, Record<string, Value>>();
  let mapping: string[] = [];
  for (const c of db.collections.values()) {
    const cn = db.names.name(c.classKey), name = db.collectionName(c);
    if (cn === "music" && name !== "default") music.set(name, db.resolvedValues(c));
    if (cn === "audiosystem" && name === "mwlicensedmusic") {
      const v = db.resolvedValues(c).PFMapping;
      mapping = (Array.isArray(v) ? v : []).map(x => (x as { collection: string }).collection);
    }
  }
  const order = [...mapping, ...[...music.keys()].filter(k => !mapping.includes(k))];

  // 3) Proyecto de canciones (MW_MUSIC)
  const lic = mpfs.get("MW_MUSIC")!;
  const evByLow = new Map(lic.events.map(e => [e.id, e]));
  const entries = new Set(lic.events.flatMap(e => gotos(lic, e)));
  const songs = order.filter(k => music.has(k)).map((k, i) => {
    const v = music.get(k)!;
    const pe = Number(v.PathEvent) >>> 0, ev = evByLow.get(pe & 0xffffff);
    const entry = ev ? gotos(lic, ev)[0] : undefined;
    const r = entry !== undefined ? reach(lic, entry, entries) : null;
    const sample = r?.samples[0];
    return {
      index: i, key: k, artist: String(v.Artist ?? "").trim(), title: String(v.SongName ?? "").trim(), album: String(v.Album ?? "").trim(),
      defPlay: v.DefPlay ?? null, pathEvent: pe, event: ev?.index ?? null, entryNode: entry ?? null, sample: sample ?? null,
      ms: sample !== undefined ? lic.samples[sample].ms : null, inPlaylist: mapping.includes(k),
    };
  });
  const songBySample = new Map(songs.filter(s => s.sample !== null).map(s => [s.sample!, s]));

  // Nombre de cada evento de cada proyecto
  const eventName = (proj: number, e: Mpf["events"][number]): string => {
    const song = songs.find(s => (s.pathEvent & 0xffffff) === e.id);
    if (proj < 0 && song) return `canción: ${song.artist} – ${song.title}`;
    const sp = Object.entries(LICENSED_SPECIAL).find(([k]) => (+k & 0xffffff) === e.id);
    if (sp) return sp[1];
    const az = AMBIENT_CROSSMAP.findIndex(x => (x & 0xffffff) === e.id);
    if (az >= 0) return `ambiente zona ${az}${AMBIENT_ZONE_NAMES[az] ? ` · ${AMBIENT_ZONE_NAMES[az]}` : ""}`;
    for (let p = 0; p < 4; p++) {
      const k = PFXMAP[p].findIndex((x, i) => i >= 9 && (x & 0xffffff) === e.id);
      if (k >= 0) return k >= 19 ? `${PF_ENTRIES[k]} (proyecto ${p + 1})` : PF_ENTRIES[k];
    }
    const cb = e.actions.find(a => a.type === 0x0d);
    if (cb) return `llamada al juego ${cb.params[1]}/${cb.params[0]} (${CALLBACKS[cb.params[1]] ?? "?"}${cb.params[1] === 3 ? (cb.params[0] ? " → EVT_SWAP2" : " → EVT_SWAP1") : ""})`;
    return "";
  };

  // 4) Cada proyecto a JSON
  const projects = PROJECTS.map((p, pi) => {
    const m = mpfs.get(p)!, mus = musBytes.get(p)!;
    const proj = pi - 1; // −1 = canciones; 0–3 = interactivos
    const samples = m.samples.map(s => {
      const st = parseMusStream(mus, s.offset);
      // [desplazamiento en el .MUS, bytes, ms, Hz, canales, muestras, nº de bloques]
      return [s.offset, st.bytes, s.ms, st.sampleRate, st.channels, st.samples, st.blocks.length];
    });
    const parts = proj >= 0 ? Object.fromEntries(PF_ENTRIES.slice(0, 9).map((n, k) => [n, PFXMAP[proj][k]])) : undefined;
    // Ondas agrupadas por la parte a la que pertenecen (u16 en 0x08)
    const partOf: Record<string, number[]> = {};
    if (parts) for (const [n, node] of Object.entries(parts)) partOf[n] = m.nodes.filter(x => x.sample !== null && x.ref === node).map(x => x.index);
    return {
      name: p, role: proj < 0 ? "canciones (EA Trax), ambientes y golpes musicales" : `persecución, proyecto ${proj + 1} de 4`,
      mpf: `${p}.MPF`, mus: `${p}.MUS`, musBytes: mus.length, version: `${m.version}.${m.subversion}`, counts: m.counts,
      checksum: m.tracks[0]?.checksum, vars: m.vars, routers: m.routers, parts, partWaves: parts ? partOf : undefined,
      // [onda (i16: >0 muestra+1, 0 mudo, −1 fin, −3 evento), sección, b3, b4, flags, ref (parte/contador), aviso, evento, [[mín, máx, destino]…]]
      nodes: m.nodes.map(x => [x.wave, x.section, x.b3, x.b4, x.flags, x.ref, x.notify, x.event, x.branches.map(b => [b.min, b.max, b.node])]),
      events: m.events.map(e => ({
        index: e.index, id: e.id, name: eventName(proj, e), goto: gotos(m, e),
        actions: e.actions.map(a => [a.type, a.code, a.params[0], a.params[1], a.track]),
      })),
      samples,
    };
  });

  // Ambientes y golpes (MW_MUSIC)
  const ambience = AMBIENT_CROSSMAP.map((x, zone) => {
    const ev = evByLow.get(x & 0xffffff);
    const nodes = ev ? [...new Set(gotos(lic, ev))] : [];
    const samples = [...new Set(nodes.flatMap(n => reach(lic, n, entries).samples))];
    return { zone, name: AMBIENT_ZONE_NAMES[zone] ?? null, event: ev?.index ?? null, id: x, entryNodes: nodes, samples };
  });
  const stingers = lic.events.filter(e => /SWAP/.test(eventName(-1, e))).map(e => {
    const n = gotos(lic, e)[0];
    return { event: e.index, name: eventName(-1, e), entryNode: n, samples: n !== undefined ? reach(lic, n, entries).samples : [] };
  });

  const index = {
    format: 1, disc: id,
    note: "Formatos y etiquetas en docs/es/25-musica-y-mezcla.md. samples = [desplazamiento en el .MUS, bytes, ms, Hz, canales, muestras, bloques]: cada una es un flujo SCHl «GSTR» con bloques SCDl de EA-XA v2 estéreo (src/lib/pathfinder.ts). nodes = [onda, sección, b3, b4, flags, ref, aviso, evento, ramas[[mín, máx, destino]]]: al acabar la muestra se sigue la rama cuyo control (intensidad 0–127) cumple mín < c ≤ máx. events.actions = [tipo, código, p0, p1, pista]: 4/3 ir al nodo p0, 4/15 vaciar cola, 13/15 llamada al juego (p1 = id, p0 = parámetro), 5/12 fundido (p0 = 0x100 | volumen destino, p1 = ms) [H], 2/12 espera p0 ms [H], 1/x condiciones [H].",
    codec: { container: "SCHl GSTR (big endian en bloques)", codec: "EA-XA v2", sampleRate: 32000, channels: 2, bytesPerSecond: 36216, verified: "idéntico a vgmstream r2117 muestra a muestra en las 1363 muestras (SLES-53559)" },
    projects, songs, ambience, stingers,
    logic: {
      source: "[D] SFXObj_Pathfinder.cpp (SFXObj_PFEATrax), SFXCTL_Pathfinder5.cpp, Speech/MusicFlow.cpp",
      projects: "MW_MUSIC siempre cargado (canciones, ambientes, golpes). Uno de los 4 interactivos (MW_MUS_1…4) al azar al empezar; cada EVT_SWAP1/2 pasa al siguiente ((n+1) & 3). En pantalla partida no se carga el interactivo.",
      musicType: "SPLASH (inicio) · LICENCED (canción) · INTERACTIVE (persecución activa o buscando) · AMBIENCE (zona del mapa o del menú)",
      licensed: "GenNextMusicTrackID: lista del jugador en orden o al azar (PBMode) sin repetir hasta agotarla; DefPlay FE = menú, IG = juego, AL = ambos. Cada canción: nodo mudo → onda → nodo −3 (evento 0x641F27, llamada 1 = fin) → fin.",
      pursuit: "TestToPursuit: SoundAI kActive o kSearching y música interactiva activada → StartInteractiveMusic(0x026E7282 = EVT_START) → MusicFlow espera 0,5 s y manda EVT_START (17). Al acabar la persecución (EVT_ENDWIN 14 / EVT_ENDBUSTED 15) suena el final y la llamada 2 (InteractiveDone) vuelve a las canciones; tras una persecución hay 40 s de ambiente (PURSUIT_TO_LIC_DELAY) antes de la siguiente canción.",
      intensity: "MusicFlow::Update manda cada fotograma PATH_control(intensidad × 127). Intensidad 0–1 con media exponencial 0,99/0,01 (UpdateIntensity). Las ramas de cada onda la reparten en 4 tramos (p. ej. ≤20, ≤65, ≤110, ≤127 en MW_MUS_1).",
      states: {
        NEUTRAL: { event: 10, part: 4, rule: "persecución normal; cerca (<32 m) sube la intensidad; 30 s «contenido» a ≤0,5" },
        LOSE: { event: 11, part: 1, rule: "el jugador va despacio (<12,5 % de la punta) con bloqueo activo, o la policía está a <32 m" },
        WIN: { event: 12, part: 3, rule: "velocidad media >50 % de la punta; en enfriamiento y rápido (≥35 %)" },
        ELUDE: { event: 13, part: 2, rule: "buscando, parado (<12,5 %) y sin ver al jugador >4 s" },
        TERMINAL: { event: 14, parts: [5, 6, 7], rule: "fin de la persecución (EVT_ENDWIN); EVT_ENDBUSTED si arrestan" },
      },
      parts: "SongProgressCallback(nodo): el u16 «ref» de cada onda es el nodo de su parte; CrossMapNodeParam lo traduce con PFXMAP a 0–8 (ENDPAUSE_1, LOSE, ELUDE, WIN, NEUTRAL, WIN_END, LOSE_END, ELUDE_END, END_PAUSE_2) y MusicFlow cambia de estado.",
      ambience: "UpdateAmbience: en juego, ParameterMap «Ambience» en la posición del coche (zona 0–8); en menús 9 refugio, 10 taller, 11 resto, 12 concesionario, 13 ficha policial. Cada zona = evento AMBIENT_CROSSMAP[zona]. La variable «rapsheet» (1–3) elige la variante de la ficha.",
      pursuitBreaker: "Al romper un «pursuit breaker» un paso bajo baja de 65 535 a 630 Hz en 1 s y sube a 1800 Hz; al salir vuelve a 65 535 en 1 s.",
      volumes: "DMIX: canción 1 (juego) / 0 (menú), interactiva 3, ambiente 5 (juego) / 4 (menú); entradas 6/7/8 = canción/interactiva/ambiente a 0x7FFF.",
    },
  };
  writeFileSync(`${out}/music.json`, JSON.stringify(index));

  // 5) Mapas de mezcla
  const mixmaps: Record<string, unknown> = {};
  let named = 0, differ = 0;
  for (const n of MIXMAPS) {
    const mxb = parseMixMap(await read(`SOUND\\MIXMAPS\\${n}.MXB`));
    const dynRaw = disc.find(`SOUND\\MIXMAPS\\${n}.DYN`) ? await read(`SOUND\\MIXMAPS\\${n}.DYN`) : null;
    if (dynRaw) { const r = attachNames(mxb, parseMixMap(dynRaw, true)); named += r.named; differ += r.differ; }
    mixmaps[n] = { role: MIXMAP_ROLE[n], ...mixJson(mxb) };
  }
  writeFileSync(`${out}/mixmaps.json`, JSON.stringify({
    format: 1, disc: id,
    note: "[D] NFSMixerDefines.hpp / NFSMixMapState.cpp. Cada registro = {name (del .DYN), values (campos fijos), extra (escalas o entradas)}. mixCtls values = [nINPUTID, nUScaleCntSwing]; mixCtls3D = [nINPUTID, por estado de cámara 6 × i32 (n3DSTATEINFOID, nCURVEID_DOPPLER, nQ0..3MinMax)]; subChannels = [MIXCHID, UpperLowerSwing]; masterChannels = [MIXCHID, MixData, SFXOBJID]; eventCtls = [nEVTCTLID, nUScaleCntSwing, nTriggerID, nParam_00..02] (envelope = AR/ASR/ATR/LFO).",
    maps: mixmaps,
  }));

  // 6) Reverbs
  const reverbs: Record<string, unknown> = {};
  for (const e of disc.entries) {
    const nm = e.name;
    if (!nm?.startsWith("SOUND\\FXEDIT\\")) continue;
    const f = parseFx(await disc.readEntry(e)), file = nm.split("\\")[2];
    reverbs[file] = { ...f, zones: REVERB_ZONES.filter((_, i) => CSFXEDIT[i].toUpperCase() === file) };
  }
  writeFileSync(`${out}/reverbs.json`, JSON.stringify({
    format: 1, disc: id,
    note: "[D] SFXObj_Reverb.cpp: csfxedit[12] (archivos que se cargan) y ReverbZoneCrossMap[12] (zona del ParameterMap «Reverb» → preset). Los presets se pasan al IOP (Snd::Hal::SetCustomFx), cuyo código no está en la decomp: aquí solo la cabecera (u32 BE) y el resto en u16 BE (0xCCCC = relleno) [H].",
    loaded: CSFXEDIT, zones: REVERB_ZONES, presets: reverbs,
  }));

  // 7) Interfaces Csis
  const csi: Record<string, unknown> = {};
  for (const e of disc.entries) {
    const nm = e.name;
    if (!nm || !/^SOUND\\(EVT_SYS|SPEECH)\\.*\.CSI$/.test(nm)) continue;
    csi[nm] = parseCsi(await disc.readEntry(e));
  }
  writeFileSync(`${out}/csi.json`, JSON.stringify({ format: 1, disc: id, note: "MOIR: interfaz Csis = {nombre, id del archivo, id de la interfaz}; son los InterfaceId de EAXSound/SND_GEN/*.cpp [D]. La app no los necesita para sonar.", files: csi }));

  // 8) Consola
  const totalMs = projects.reduce((a, p) => a + p.samples.reduce((b, s) => b + Number(s[2]), 0), 0);
  const nSamples = projects.reduce((a, p) => a + p.samples.length, 0);
  if (dump) {
    for (const s of songs) console.log(`canción ${s.index}: ${s.artist} – ${s.title} [${s.defPlay}] evento ${s.event} nodo ${s.entryNode} muestra ${s.sample} ${((s.ms ?? 0) / 1000).toFixed(1)} s`);
    for (const a of ambience) console.log(`ambiente zona ${a.zone}${a.name ? ` (${a.name})` : ""}: evento ${a.event} → nodos ${a.entryNodes.join(",")} muestras ${a.samples.join(",")}`);
    for (const s of stingers) console.log(`golpe: ${s.name} → muestras ${s.samples.join(",")}`);
    for (const p of projects) {
      console.log(`${p.name}: ${p.counts.nodes} nodos, ${p.counts.events} eventos, ${p.samples.length} muestras`);
      for (const e of p.events) console.log(`  evento ${e.index} 0x${e.id.toString(16).padStart(6, "0")} ${e.name} · ${e.actions.map(a => `${a[0]}/${a[1].toString(16)}(${a[2]},${a[3]})`).join(" ")}`);
      if (p.parts) for (const [k, v] of Object.entries(p.parts)) console.log(`  parte ${k} = nodo ${v} (${p.partWaves![k].length} ondas)`);
    }
  }

  if (audio) {
    const ff = spawnSync("ffmpeg", ["-version"]).status === 0;
    if (!ff) console.log("--audio: no hay ffmpeg (brew install ffmpeg)");
    else {
      let n = 0;
      for (const p of PROJECTS) {
        const m = mpfs.get(p)!, mus = musBytes.get(p)!, dir = `${out}/audio/${p}`;
        mkdirSync(dir, { recursive: true });
        for (const s of m.samples) {
          const song = p === "MW_MUSIC" ? songBySample.get(s.index) : undefined;
          const label = song ? ` ${song.artist} - ${song.title}`.replace(/[\\/:*?"<>|]/g, "_") : "";
          const ch = decodeMusStream(mus, s.offset), st = parseMusStream(mus, s.offset);
          const r = spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "wav", "-i", "pipe:0", "-c:a", "flac", `${dir}/${String(s.index).padStart(3, "0")}${label}.flac`], { input: encodeWav(ch, st.sampleRate), maxBuffer: 1 << 30 });
          if (r.status) console.log(`  ffmpeg falló en ${p} #${s.index}: ${r.stderr}`); else n++;
        }
      }
      console.log(`--audio: ${n} FLAC → ${out}/audio`);
    }
  }

  if (check) {
    const vgm = ["/opt/homebrew/bin/vgmstream-cli", "/usr/local/bin/vgmstream-cli"].find(p => existsSync(p));
    if (!vgm) console.log("--check: no hay vgmstream-cli (brew install vgmstream)");
    else {
      const tmp = `${out}/.check`; mkdirSync(tmp, { recursive: true });
      let same = 0, total = 0, pcm = 0;
      for (const p of PROJECTS) {
        // vgmstream abre el .MUS con el mismo nombre que el .MPF
        copyFileSync(`${out}/${p}.MPF`, `${tmp}/${p}.mpf`);
        const musLink = `${tmp}/${p}.mus`; rmSync(musLink, { force: true }); require("node:fs").symlinkSync(`${out}/${p}.MUS`, musLink);
        const m = mpfs.get(p)!, mus = musBytes.get(p)!;
        for (const s of m.samples) {
          spawnSync(vgm, ["-i", "-s", String(s.index + 1), "-o", `${tmp}/x.wav`, `${tmp}/${p}.mpf`]);
          const w = new Uint8Array(readFileSync(`${tmp}/x.wav`)), dv = new DataView(w.buffer);
          let o = 12; while (String.fromCharCode(...w.subarray(o, o + 4)) !== "data") o += 8 + dv.getUint32(o + 4, true);
          const n = dv.getUint32(o + 4, true) / 4, ch = decodeMusStream(mus, s.offset);
          let ok = ch[0].length === n;
          for (let i = 0; ok && i < n; i++) if (dv.getInt16(o + 8 + 4 * i, true) !== ch[0][i] || dv.getInt16(o + 10 + 4 * i, true) !== ch[1][i]) ok = false;
          total++; pcm += n; if (ok) same++; else console.log(`  distinto: ${p} #${s.index}`);
        }
      }
      rmSync(tmp, { recursive: true, force: true });
      console.log(`--check (vgmstream): ${same}/${total} muestras idénticas muestra a muestra (${(pcm / 1e6).toFixed(1)} M muestras estéreo)`);
    }
  }

  console.log(`música: ${songs.length} canciones, ${ambience.length} ambientes, 4 proyectos de persecución · ${nSamples} muestras (${(totalMs / 3.6e6).toFixed(2)} h, ${(copied / 1e6).toFixed(0)} MB copiados) · mezcla: ${MIXMAPS.length} mapas (${named} registros con nombre, ${differ} con valores distintos en el .DYN) · ${Object.keys(reverbs).length} reverbs · ${Object.keys(csi).length} CSI`);
}

function mixJson(m: MixMap) {
  return {
    id: m.id, states: m.states.map(s => ({
      index: s.index, name: s.name, stateIndex: s.stateIndex, headers: s.headers,
      mixCtls: s.mixCtls.map(r => ({ name: r.name, values: r.values, extra: r.extra })),
      mixCtls3D: s.mixCtls3D.map(r => ({ name: r.name, values: r.values })),
      subChannels: s.subChannels.map(r => ({ name: r.name, values: r.values, inputs: r.extra, inputNames: (r as { inputNames?: string[] }).inputNames })),
      masterChannels: s.masterChannels.map(r => ({ name: r.name, values: r.values, inputs: r.extra, inputNames: (r as { inputNames?: string[] }).inputNames })),
      eventCtls: s.eventCtls.map(r => ({ name: r.name, envelope: ENVELOPES[(r.values[0] >> 24) & 0xf] ?? null, values: r.values, extra: r.extra })),
      presets: s.presets,
    })),
  };
}

if (import.meta.main) await main(Bun.argv.slice(2));
