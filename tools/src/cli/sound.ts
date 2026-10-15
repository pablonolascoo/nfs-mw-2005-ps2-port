// Sonido del juego para el motor nativo → map-data/<ID>/sound/ (no se sube a git).
// Uso: bun src/cli/sound.ts <iso> <ID>                 exporta bancos + sound.json
//      bun src/cli/sound.ts <iso> <ID> --check         además compara TODOS los sonidos con vgmstream-cli (si está instalado)
//      bun src/cli/sound.ts <iso> <ID> --wav IG_GLOBAL/SIREN_MB.ABK[,ENGINE/GIN_BMW_M3.GIN…]  escribe WAV para escuchar
//      bun src/cli/sound.ts <iso> <ID> --dump          lista bancos, sonidos y coches
//
// Qué sale (formatos en src/lib/abk.ts y docs/es/16-audio-y-voces.md §7–9):
//   sound/<CARPETA>/<ARCHIVO>   bancos ABKC (.ABK) y motores granulares (.GIN) tal cual del disco (~33 MB). La app los
//                               decodifica sola (native-engine/Sources/Rockport/Audio/SFXBank.swift): PS-ADPCM, EA-XA v2, EA-XAS.
//   sound/sound.json            índice: sonidos de cada banco (códec, frecuencia, muestras, bucle, desplazamientos),
//                               cabecera de cada .GIN, clases VLT de audio (engineaudio, turbosfx, shiftpattern, acceltrans),
//                               coche → juego de sonidos (como EAXCar::Attach), superficies (simsurface), «stitches» de golpes
//                               (GLOBAL\INGAMEB.BUN bChunk 0x8003B500) y el papel de cada muestra en los bancos globales.
import { mkdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, parseVpak, type Value } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { loadCandidates } from "../lib/names";
import { outDir, embedded } from "../lib/paths";
import { decodeBankSound, decodeGnsu, decodeGnsuInt, parseAbk, parseGnsu, type AbkBank } from "../lib/abk";
import { encodeWav } from "../lib/microtalk";
import stitchNamesText from "../../data/stitch-collision-types.txt" with { type: "text" };

/** Carpetas de SOUND\ que usa el motor. SPEECH (radio.ts), STREAMS/PFDATA (películas y música) y NISREVDATA van aparte. */
const DIRS = ["ENGINE", "TURBO", "SHIFTING", "SKIDS", "NOS", "IG_GLOBAL", "GLOBAL", "FE"];

/** Papel de cada muestra en los bancos globales. Los módulos AEMS (código MIPS dentro del ABKC) no se ejecutan, así que
 *  el port decide qué muestra suena con la lógica de la decomp y estas tablas. [D] = índice que pasa el código del juego,
 *  [I] = deducido de la decomp + datos (bucle, duración, espectro), [H] = hipótesis por escucha/medida. */
const ROLES: Record<string, Record<string, unknown>> = {
  turbo: { spool: 0, blowoffSmall: 1, blowoffBig: [2, 3], spoolHigh: 4, tag: "[D] FX_TURBO_01 id 0 = soplado (PSI), 1 = descarga pequeña, 2–3 = grande al azar si PSI > 75 % (CARSFX_Turbo.cpp); 4 = segundo bucle [H]. Compresores (SC_*): 0 y 1 bucles de silbido [I]" },
  shifting: { down: 0, up: 1, braking: 2, tag: "[D] AEMS_SHIFTING_SAMPLES: DOWN = 0, UP = 1, BREAKING = 2 (EAXSoundEnums.hpp)" },
  skids: { side: 0, forward: 1, back: 2, drift: 3, loose: 4, tag: "[I] 0–2 chirridos tonales (asfalto, Aud_Skid_Type 0), 3 derrape largo, 4 ruido de tierra (Aud_Skid_Type 1): reparto fwd/side/back [H]" },
  nitrous: { loop: 0, start: 1, stop: 2, tag: "[I] 0 bucle de flujo, 1 golpe de entrada (ruido corto), 2 purga/cierre; NITROUS_01 añade 3–5 [H]" },
  siren: { yelp: 0, yelpFar: 1, wail: 2, wailFar: 3, phaser: 4, tag: "[I] ciclos de 0,36 s (yelp) y 3,78 s (wail); 1 y 3 = las mismas a 14 kHz (SIREN_BED, lejos) [I]; 4 bucle de 0,08 s [H]" },
  traffic: { engineA: 0, engineB: 1, horn: 2, hornTruck: 3, tag: "[I] 0–1 bucles graves (motor del tráfico), 2–3 golpes brillantes de ~1 s (cláxones); HornType 11 = camiones → 3 [H]" },
  wind: { left: 0, right: 1, fast: 2, rumble: 3, tag: "[I] FX_WIND: volume_left/right, intensidad y rumble_Volume; 3 se reproduce a 1 kHz (retumbo grave) [V: frecuencia]" },
  roadnoise: { tag: "[D] simsurface.Aud_Roadnoise_LOOP elige el bucle 0–6 (asfalto 5, tierra 0, hormigón 1, adoquín 2, agua/vía 3, rueda reventada 6); 7–14 transiciones (Aud_RoadNoise_TransON/OFF) [I]" },
  collision: { tag: "[V] GLOBAL\\INGAMEB.BUN bChunk 0x8003B500: 608 «stitches» = lista de muestras de STICH_COLLISION_MB con volumen Q15, tono Q12 (4096 = 1), retardo en ms y variación al azar [D: STICH_Struct.h]" },
  engine: { tag: "[D] Ginsu: GIN acelerando (Filename_GinsuAccel) + desacelerando (Filename_GinsuDecel) mezclados por SFXCTL_HybridMotor; AEMS (CAR_NN_ENG_MB_EE/SPU) = capa de bucles que el port no usa (módulo MIPS) [I]" },
};

export async function main(args: string[]) {
  const flag = (f: string) => { const i = args.indexOf(f); if (i < 0) return undefined; const v = args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : ""; args.splice(i, v ? 2 : 1); return v; };
  const check = flag("--check") !== undefined, dump = flag("--dump") !== undefined, wavArg = flag("--wav");
  const [iso, id] = args;
  if (!iso || !id) { console.error("Uso: bun src/cli/sound.ts <iso> <ID> [--check] [--dump] [--wav DIR/ARCHIVO,…]"); process.exit(1); }
  const disc = await GameDisc.open(iso);
  disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));

  // 1) Archivos de sonido: copia + índice
  const out = `${outDir(id)}/sound`;
  const files = new Map<string, Uint8Array>();            // "IG_GLOBAL/SIREN_MB.ABK" → bytes
  for (const e of disc.entries) {
    const n = e.name;
    if (!n?.startsWith("SOUND\\")) continue;
    const [, dir, file] = n.split("\\");
    if (!DIRS.includes(dir) || !file || !/\.(ABK|GIN)$/.test(file)) continue;
    files.set(`${dir}/${file}`, await disc.readEntry(e));
  }
  if (!files.size) { console.error("El disco no trae SOUND\\*.ABK (¿ISO de Most Wanted?)"); process.exit(1); }
  const byBase = new Map([...files.keys()].map(k => [k.split("/")[1], k]));
  const pathOf = (attrName: unknown): string | null => {
    if (typeof attrName !== "string" || !attrName) return null;
    return byBase.get(attrName.toUpperCase()) ?? null;
  };

  const banks: Record<string, { module: number; sounds: unknown[] }> = {};
  const gins: Record<string, unknown> = {};
  const parsed = new Map<string, AbkBank>();
  let nSounds = 0, nSamples = 0;
  for (const [k, b] of [...files].sort()) {
    mkdirSync(`${out}/${k.split("/")[0]}`, { recursive: true });
    writeFileSync(`${out}/${k}`, b);
    if (k.endsWith(".GIN")) {
      const g = parseGnsu(b);
      gins[k] = { minRPM: +g.minFrequency.toFixed(2), maxRPM: +g.maxFrequency.toFixed(2), segments: g.segCount, cycles: g.cycleCount, samples: g.sampleCount, rate: g.sampleRate, data: g.dataOffset };
      nSamples += g.sampleCount;
      continue;
    }
    const bank = parseAbk(b);
    parsed.set(k, bank);
    banks[k] = {
      module: bank.moduleBytes,
      // [índice BNK, códec, frecuencia, muestras, canales, desplazamientos, bucle inicio, bucle fin (-1 = sin bucle)]
      sounds: bank.sounds.map(s => [s.index, s.codec, s.sampleRate, s.samples, s.channels, s.offsets, s.loop?.[0] ?? -1, s.loop?.[1] ?? -1]),
    };
    nSounds += bank.sounds.length; nSamples += bank.sounds.reduce((a, s) => a + s.samples * s.channels, 0);
  }

  // 2) Base de datos de atributos (GLOBAL\ATTRIBUTES.BIN)
  const db = new AttribDatabase();
  await loadAttribNames(db);
  for (const e of parseVpak(await disc.readEntry(disc.find("GLOBAL\\ATTRIBUTES.BIN")!))) db.addVault(new Vault(e.name, e.vlt, e.bin));
  const classOf = new Map<string, Map<string, Record<string, Value>>>();
  for (const c of db.collections.values()) {
    const cn = db.names.name(c.classKey);
    if (!classOf.has(cn)) classOf.set(cn, new Map());
    classOf.get(cn)!.set(db.collectionName(c), db.resolvedValues(c));
  }
  const cls = (n: string) => classOf.get(n) ?? new Map<string, Record<string, Value>>();
  const refName = (v: Value): string | null => (v && typeof v === "object" && !Array.isArray(v) && "collection" in v ? ((v as { collection: string | null }).collection) : null);
  const keyName = (classKey: number, key: number) => { const c = db.getCollection(classKey, key); return c ? db.collectionName(c) : null; };
  const strip = (v: Record<string, Value>) => Object.fromEntries(Object.entries(v).filter(([k]) => k !== "CollectionName"));

  // engineaudio: rutas de archivo ya resueltas a sound/<CARPETA>/<ARCHIVO>
  const engines: Record<string, unknown> = {};
  const missing = new Set<string>();
  for (const [name, v] of cls("engineaudio")) {
    if (name === "default") continue;
    const r: Record<string, unknown> = strip(v);
    for (const f of ["Filename_GinsuAccel", "Filename_GinsuDecel", "BankName_mainRAM"] as const) {
      const p = pathOf(v[f]); r[f] = p; if (v[f] && !p) missing.add(String(v[f]));
    }
    r.BankName_auxRAM = (Array.isArray(v.BankName_auxRAM) ? v.BankName_auxRAM : []).map(pathOf);
    r.SweetBank = (Array.isArray(v.SweetBank) ? v.SweetBank : []).map(pathOf);
    r.acceltrans = refName(v.acceltrans ?? null);
    engines[name] = r;
  }
  const turbos: Record<string, unknown> = {};
  for (const [name, v] of cls("turbosfx")) { const p = pathOf(v.BankName); if (v.BankName && !p) missing.add(String(v.BankName)); turbos[name] = { ...strip(v), BankName: p }; }
  // shiftpattern: stShiftPair = {i16 RPM, i16 Time} empaquetado en un u32 [D: SFXObj_EnumAttributes.hpp]
  const pair = (u: unknown) => { const x = Number(u) >>> 0; return { rpm: (x << 16) >> 16, time: x >>> 16 }; };
  const shifts: Record<string, unknown> = {};
  for (const [name, v] of cls("shiftpattern")) {
    const p = pathOf(v.BankName); if (v.BankName && !p) missing.add(String(v.BankName));
    shifts[name] = {
      ...strip(v), BankName: p, Up_Engage: pair(v.Up_Engage),
      Up_DisengageFall: (Array.isArray(v.Up_DisengageFall) ? v.Up_DisengageFall : [v.Up_DisengageFall]).filter(x => x != null).map(pair),
    };
  }
  const accel: Record<string, unknown> = {};
  for (const [name, v] of cls("acceltrans")) accel[name] = strip(v);
  const mw = cls("audiosystem").get("mostwanted") ?? {};
  const list = (v: Value | undefined) => (Array.isArray(v) ? v : v != null ? [v] : []).map(pathOf);
  const globalBanks = {
    skid: list(mw.AEMS_SkidBanks), nos: list(mw.AEMS_NOSBanks), roadnoise: list(mw.AEMS_RNBanks), wind: list(mw.AEMS_WNBanks),
    misc: list(mw.AEMS_MiscBanks), stitch: list(mw.AEMS_StitchBanks), env: list(mw.AEMS_EnvBanks), fe: list(mw.AEMS_FEBanks),
  };
  const surfaces: Record<string, unknown> = {};
  for (const [name, v] of cls("simsurface")) surfaces[name] = { roadnoise: v.Aud_Roadnoise_LOOP, transOn: v.Aud_RoadNoise_TransON, transOff: v.Aud_RoadNoise_TransOFF, skid: v.Aud_Skid_Type };

  // 3) Coche → sonidos, como EAXCar::Attach / GenerateUpgradedEngine [D]
  const upgradeIntervals = (cur: number, physNum: number, audNum: number) => {
    const base = Math.max(0, Math.min(4, 4 - physNum)), off = Math.max(0, Math.min(4, cur));
    let a = 0;
    if (base < 3) { if (base > 0) a = base + off >= 3 ? 1 : 0; else { const n = base + off; a = n > 2 ? 2 : n > 0 ? 1 : 0; } }
    return Math.max(0, Math.min(audNum - 1, a));
  };
  type Spec = { item: string | null; level: number };
  const upgradeSpecs = (v: Value | undefined): Spec[] => (Array.isArray(v) ? v : []).map(x => {
    const raw = (x as { raw: string[] }).raw;
    return { item: keyName(parseInt(raw[0], 16) >>> 0, parseInt(raw[1], 16) >>> 0), level: parseInt(raw[3], 16) & 0xff };
  });
  const pickLevel = (specs: Spec[], cur: number) => { let k = 0; for (let n = 0; n < specs.length; n++) { if (specs[n].level > cur) break; k = n; } return specs[k]?.item ?? null; };
  const num = (v: Value | undefined) => (typeof v === "number" ? v : 0);
  const cars: Record<string, unknown> = {};
  for (const [name, pv] of cls("pvehicle")) {
    if (!pv.engineaudio) continue;
    const engList = (Array.isArray(pv.engineaudio) ? pv.engineaudio : [pv.engineaudio]).map(refName);
    const turbo = upgradeSpecs(pv.TurboSND), shift = upgradeSpecs(pv.ShiftSND);
    const engine = engList[upgradeIntervals(num(pv.engine_current), num(pv.engine_upgrades), engList.length)] ?? engList[0];
    const t = pickLevel(turbo, 4 - num(pv.induction_upgrades) + num(pv.induction_current));
    cars[name] = {
      class: pv.CLASS ?? null, engine, engines: engList,
      turbo: t === "default" ? null : t, turbos: turbo, shift: pickLevel(shift, 4 - num(pv.transmission_upgrades) + num(pv.transmission_current)), shifts: shift,
      horn: pv.HornType ?? 0, trafficEngine: pv.TrafficEngType ?? 0, woosh: pv.WooshType ?? 0, truck: pv.TruckSndFX === true,
    };
  }

  // 4) Stitches de golpes: GLOBAL\INGAMEB.BUN, bChunk 0x8003B500 (BCHUNK_SND_STICHBUNDLE) [D: STICH_Loader.cpp; V]
  const stitchNames = new Map(stitchNamesText.split(/\r?\n/).filter(l => /^\d/.test(l)).map(l => { const [i, n] = l.split(" "); return [+i, n] as [number, string]; }));
  const stitches: unknown[] = [];
  const ingame = disc.find("GLOBAL\\INGAMEB.BUN");
  if (ingame) {
    const b = await disc.readEntry(ingame), dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    let p = 0;
    while (p + 8 <= b.length) {
      const cid = dv.getUint32(p, true), size = dv.getUint32(p + 4, true);
      if (cid === 0x8003b500) {
        let q = p + 8; const end = q + size;
        while (q + 8 <= end) {
          const id1 = dv.getUint32(q, true), s1 = dv.getUint32(q + 4, true);
          if (id1 !== 0x3b502) { q += 8 + s1; continue; }
          const n = b[q + 17], type = dv.getInt8(q + 16), index = dv.getUint16(q + 14, true);
          const r0 = q + 8 + s1;                      // el siguiente chunk (0x3B503) es la lista de SND_SampleRef de 16 B
          const refs: number[][] = [];
          for (let k = 0; k < n; k++) {
            const r = r0 + 8 + 16 * k;
            // [muestra, volumen Q15, tono Q12, retardo ms, variación de volumen, variación de tono, prioridad]
            refs.push([b[r], dv.getUint16(r + 2, true), dv.getUint16(r + 4, true), dv.getUint16(r + 6, true), dv.getUint16(r + 10, true), dv.getInt16(r + 12, true), b[r + 14]]);
          }
          stitches[index] = { name: stitchNames.get(index) ?? `stitch${index}`, type, volume: dv.getUint16(q + 12, true), refs };
          q = r0 + 8 + dv.getUint32(r0 + 4, true);
        }
        break;
      }
      p += 8 + size;
      if (size > b.length) break;
    }
  }

  const index = {
    format: 1, disc: id,
    note: "banks[archivo].sounds = [índice BNK, códec (vag = PS-ADPCM, xa2 = EA-XA v2), Hz, muestras, canales, [desplazamiento de cada canal en el archivo], bucle inicio, bucle fin (-1 = sin bucle)]. gins = motores granulares (RPM mín./máx. de la tabla de ciclos). Fuentes y etiquetas en docs/es/16-audio-y-voces.md.",
    banks, gins, engines, turbos, shifts, acceltrans: accel, cars, surfaces, global: globalBanks, stitches, roles: ROLES,
  };
  writeFileSync(`${out}/sound.json`, JSON.stringify(index));
  const mb = [...files.values()].reduce((a, b) => a + b.length, 0) / 1e6;
  console.log(`sonido: ${Object.keys(banks).length} bancos ABK (${nSounds} sonidos), ${Object.keys(gins).length} motores GIN, ${(nSamples / 1e6).toFixed(1)} M muestras, ${mb.toFixed(1)} MB · ${Object.keys(engines).length} engineaudio, ${Object.keys(turbos).length} turbos, ${Object.keys(shifts).length} cambios, ${Object.keys(cars).length} coches, ${stitches.filter(Boolean).length} stitches${missing.size ? ` · faltan ${[...missing].join(", ")}` : ""}`);

  if (dump) {
    for (const [k, b] of Object.entries(banks)) console.log(`${k} · módulo ${b.module} B · ` + (b.sounds as unknown[][]).map(s => `#${s[0]} ${s[1]} ${s[2]}Hz ${(Number(s[3]) / Number(s[2])).toFixed(2)}s${Number(s[7]) >= 0 ? " bucle" : ""}${Number(s[4]) > 1 ? " estéreo" : ""}`).join(" · "));
    for (const [k, g] of Object.entries(gins)) console.log(`${k} · ${JSON.stringify(g)}`);
    for (const [k, c] of Object.entries(cars)) console.log(`coche ${k}: ${JSON.stringify(c)}`);
  }

  if (wavArg) {
    mkdirSync(`${out}/wav`, { recursive: true });
    for (const k of wavArg.split(",").map(s => s.trim().toUpperCase())) {
      const b = files.get(k);
      if (!b) { console.log(`--wav: no existe ${k}`); continue; }
      const base = `${out}/wav/${k.replace(/[\/.]/g, "_")}`;
      if (k.endsWith(".GIN")) { const g = parseGnsu(b); writeFileSync(`${base}.wav`, encodeWav([decodeGnsu(b, g)], g.sampleRate)); continue; }
      for (const s of parsed.get(k)!.sounds) writeFileSync(`${base}_${s.index}.wav`, encodeWav(decodeBankSound(b, s), s.sampleRate));
    }
    console.log(`WAV → ${out}/wav`);
  }

  if (check) {
    const vgm = ["/opt/homebrew/bin/vgmstream-cli", "/usr/local/bin/vgmstream-cli"].find(p => require("node:fs").existsSync(p));
    if (!vgm) { console.log("--check: no hay vgmstream-cli (brew install vgmstream)"); return; }
    const tmp = `${out}/.check`; mkdirSync(tmp, { recursive: true });
    const readWav = (p: string): Int16Array[] => {
      const w = new Uint8Array(require("node:fs").readFileSync(p)), dv = new DataView(w.buffer);
      let o = 12, nch = 1;
      while (o + 8 <= w.length) {
        const t = String.fromCharCode(w[o], w[o + 1], w[o + 2], w[o + 3]), sz = dv.getUint32(o + 4, true);
        if (t === "fmt ") nch = dv.getUint16(o + 10, true);
        if (t === "data") { const n = sz / 2 / nch; const ch = Array.from({ length: nch }, () => new Int16Array(n)); for (let i = 0; i < n; i++) for (let c = 0; c < nch; c++) ch[c][i] = dv.getInt16(o + 8 + (i * nch + c) * 2, true); return ch; }
        o += 8 + sz + (sz & 1);
      }
      return [];
    };
    let exact = 0, total = 0, clippedOnly = 0, ginExact = 0, ginTotal = 0, gameVsVgm = 0, gameSamples = 0;
    for (const [k, b] of files) {
      const f = `${tmp}/x.${k.endsWith(".GIN") ? "gin" : "abk"}`; writeFileSync(f, b);
      if (k.endsWith(".GIN")) {
        spawnSync(vgm, ["-i", "-o", `${tmp}/x.wav`, f]);
        const ref = readWav(`${tmp}/x.wav`)[0], g = parseGnsu(b), mine = decodeGnsuInt(b, g), game = decodeGnsu(b, g);
        ginTotal++; if (ref.length === mine.length && ref.every((v, i) => v === mine[i])) ginExact++;
        for (let i = 0; i < game.length; i++) { gameSamples++; if (game[i] !== mine[i]) gameVsVgm++; }
        continue;
      }
      const meta = spawnSync(vgm, ["-m", f], { encoding: "utf8" }).stdout;
      const cnt = +(/stream count: (\d+)/.exec(meta)?.[1] ?? 1);
      const refs: Int16Array[][] = [];
      for (let s = 1; s <= cnt; s++) { spawnSync(vgm, ["-s", String(s), "-i", "-o", `${tmp}/x.wav`, f]); refs.push(readWav(`${tmp}/x.wav`)); }
      const same = (a: Int16Array[], r: Int16Array[]) => a.length === r.length && a.every((ch, c) => ch.length === r[c].length && ch.every((v, i) => v === r[c][i]));
      for (const s of parsed.get(k)!.sounds) {
        total++;
        if (refs.some(r => same(decodeBankSound(b, s, true), r))) { exact++; if (!refs.some(r => same(decodeBankSound(b, s), r))) clippedOnly++; }
        else console.log(`  distinto: ${k} #${s.index}`);
      }
    }
    console.log(`--check (vgmstream): ABK ${exact}/${total} sonidos idénticos muestra a muestra (${clippedOnly} solo con la historia sin saturar de vgmstream; la app satura como la SPU) · GIN ${ginExact}/${ginTotal} idénticos con el decodificador entero; el del juego (coma flotante, decomp) difiere en ${(100 * gameVsVgm / gameSamples).toFixed(1)} % de las muestras por redondeo`);
  }
}

if (import.meta.main) await main(Bun.argv.slice(2));
