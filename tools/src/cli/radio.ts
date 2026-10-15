// Radio de la policía para el motor nativo → map-data/<ID>/radio/ (no se sube a git).
// Uso: bun src/cli/radio.ts <iso> <ID> [SP|EN|IT]      (por defecto: PAL → SP castellano, NTSC → EN)
//      bun src/cli/radio.ts <iso> <ID> [idioma] --wav 0,100,500   además escribe esos clips en radio/wav/*.wav (pruebas)
//
// Salida:
//   radio/COPSPEECH.BIG   los clips tal cual del disco (EA SCHl + MicroTalk, ~10:1). La app los decodifica sola
//                         (native-engine/Sources/Rockport/Audio/MicroTalk.swift): no hace falta vgmstream ni ffmpeg.
//   radio/radio.json      índice: clips, bancos de frases y tabla de eventos (qué frase dice cada evento).
//
// Formatos del disco [V con SLES-53559; estructuras de la decomp donde se indica]:
//   COPSPEECH_<L>.IDX = CLUMP_IDX_FILE [D: EAXSound/Clump.h]: numtypes, numbanks[20], count (0x54), item[count] de 16 B
//       {key = tipo<<24 | nº de banco, size, header (desplazamiento en el .IDX), sample (desplazamiento en el .BIG)}.
//       Cabecera de banco [V, deducida]: u16 frase, u16 ?, u8 dims (0/1/2 = bytes de parámetro por clip), u8 nº de clips,
//       u16 ?, u32 tamaño/256, y por clip: u16 BE desplazamiento/256 dentro del banco + `dims` bytes con el valor de cada parámetro.
//   COPSPEECH_<L>.EVT = base de eventos de SPCH (SPCH_AddEventDB) [V, deducida]: u32 nº de eventos en 0x10,
//       tabla de u16 (×4 = desplazamiento) desde 0x18. Cada evento: u16 id (SPCHType_1_EventID [D: SND_GEN/P2temp.h]),
//       u16 prioridad, u16 500, u16 nº de alternativas, u8 0, u8 100, u8 0, u8 nº de parámetros, u32;
//       alternativa: u8, u8 100, u8 4×nº de piezas, u8 0, u32 0, posiciones de pieza (u8, en palabras), y por pieza:
//       u16 frase, u16 1 = depende del policía que habla (0x0101) / 0 = voz fija, u32 nº de condiciones,
//       condición = u32 máscara de valores permitidos + u8 nº de parámetro (1 = speaker_id; 2… = campos del Csis::*Struct [D: SND_GEN/COPSPEECH.hpp]).
//   COPSPEECH_<L>.CSI = interfaz Csis (MOIR); no hace falta para reproducir.
//   COPSPEECH_<L>.BIG = clips SCHl alineados a 256 B, en el mismo orden que los bancos.
import { mkdirSync, writeFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { outDir, embedded } from "../lib/paths";
import { loadCandidates } from "../lib/names";
import { decodeMicroTalkClip, encodeWav, findSchlClips, parseSchl } from "../lib/microtalk";

/** SPCHType_1_EventID [D: EAXSound/SND_GEN/P2temp.h]. Solo nombres: los datos salen del disco. */
const EVENT_NAMES: Record<number, string> = {
  57: "Acknowledge", 58: "Spotter", 59: "SpotterReply", 61: "InitPursuit", 62: "PrimaryEngage", 64: "Bullhorn", 66: "SelfStrategy", 67: "CallForBU",
  68: "UnitBUReply", 70: "DispPursuitEscalation", 73: "BUReminder", 74: "DispBackupUpdate", 76: "CallForRB", 77: "DispRBReply", 78: "DispRBUpdate",
  79: "RBApproach", 80: "RBEngage", 81: "CallForSafety", 82: "ProjectileLaunch", 83: "InitStrategy", 84: "CallToPosition", 86: "CallToPositionRem",
  89: "StrategyExecute", 90: "AnticipateSuccess", 93: "OutcomeFail", 94: "StrategyReset", 95: "Arrest", 96: "DispArrestReply", 98: "CollisionWorld",
  99: "DispPursuitUpdate", 100: "PursuitUpdateRep", 102: "Disp911Report", 103: "Unit911Reply", 104: "SuspectUTurn", 105: "SuspectOutrun",
  106: "LostVisual", 107: "RegainVisual", 108: "LostSuspect", 112: "CallForEV", 113: "IntentToRam", 114: "Bailout", 115: "FocusChange",
  116: "SuspectBehaviour", 118: "DriverHistory", 119: "PursuitApproaching", 120: "ProjectileHit", 144: "ProjectileMiss", 145: "RBReminder",
  150: "BUArrives", 152: "RBAverted", 153: "Interrupt", 154: "AttmptVehStp", 155: "VehicleReport", 158: "LocationReport", 159: "SuspectConfirmed",
  160: "ReInitPursuit", 161: "InitialCallForBU", 162: "NegativeBUReply", 163: "NegativeRBReply", 164: "UnitDisabled", 165: "BailoutDeny",
  166: "OffroadMoment", 169: "HeliLostVisual", 170: "HeliIntentToBail", 171: "SwarmingReply", 173: "AnticipateFail", 174: "DispGoAhead",
  175: "HeliSelfStrategy", 176: "HeliBailout", 177: "HeliSwarming", 178: "HeliSpotter", 179: "HeliHazardAlert", 180: "DispTimeExpired",
  181: "DispPursEscGen", 182: "VehicleReportTag", 183: "DispBreakAway", 184: "DispBackupReply", 185: "StaticInterrupt", 186: "InterruptRam",
  197: "E3_Setup", 198: "InterruptRamHigh", 200: "RegainVisualInterrupt", 204: "CellCall", 205: "InitialCallForBU_MS", 206: "InterruptRam_RE",
  207: "InterruptRam_HO", 208: "InterruptRam_SS", 209: "InterruptRam_TB", 210: "CollWorld_Civi", 211: "CollWorld_Spin", 212: "CollWorld_Air",
  213: "CollWorld_Flip", 214: "Spotted", 215: "BullhornPrefix", 216: "SpotterWanted", 217: "SuspectBrake", 218: "CallForRB_sub", 219: "WeatherReport",
  220: "HeatJump", 221: "CallForSwarming", 222: "BullhornArrest", 223: "DispJurisShift", 224: "DispEVReply", 225: "DispNoVehDescrip",
  226: "DispCustPaint", 227: "DispSubRB", 228: "DispBUETA", 229: "DispHeliBUETA", 230: "HeliQuadrent", 231: "HeliQuadrentMoving", 232: "MoreDetails",
  233: "DirectionHigh", 234: "SuperPursuitReply", 235: "SwarmingReplyFollow", 236: "QuadrentForming", 237: "SuspectPossiblyGone", 238: "QuadrentMoving",
  239: "OtherLead", 240: "PossibleSuspect", 241: "WrongSuspect", 242: "SuspectGone", 243: "RBWarning", 244: "RBPosition", 245: "ExtraRBEngage",
  246: "ExtraRBAverted", 247: "CrossBUReply", 248: "CrossFailReply", 249: "CrossRBFailReply", 250: "CrossPursuitEsc", 251: "CrossSelfStrategy",
  252: "CrossMultiStrategy", 254: "CrossBailoutDeny_sub", 255: "Disp911CsPnt", 256: "Disp911NoDescrip", 257: "DispVehDescrip",
  258: "DispVehDescripVinyls", 259: "HeliBullhornArrest", 260: "D_Day", 263: "DispIntroRace",
};

export interface RadioBank { phrase: number; key: number; first: number; count: number; dims: number; values?: number[][] }
export interface RadioPiece { phrase: number; speaker: boolean; cond: [number, number][] }
export interface RadioEvent { id: number; name: string; priority: number; params: number; alts: RadioPiece[][] }

/** Bancos de frases del .IDX. `clipAt` traduce un desplazamiento del .BIG a nº de clip. */
export function parseRadioIdx(idx: Uint8Array, clipAt: (offset: number) => number): RadioBank[] {
  const dv = new DataView(idx.buffer, idx.byteOffset, idx.byteLength);
  const count = dv.getUint32(0x54, true);
  const banks: RadioBank[] = [];
  for (let i = 0; i < count; i++) {
    const o = 0x58 + 16 * i;
    const key = dv.getUint32(o, true), hdr = dv.getUint32(o + 8, true), sample = dv.getUint32(o + 12, true);
    const phrase = dv.getUint16(hdr, true), dims = idx[hdr + 4], n = idx[hdr + 5];
    const first = clipAt(sample);
    if (first < 0) throw new Error(`banco ${i}: no hay clip en 0x${sample.toString(16)}`);
    const b: RadioBank = { phrase, key, first, count: n, dims };
    if (dims > 0) {
      b.values = [];
      for (let k = 0; k < n; k++) {
        const e = hdr + 12 + k * (2 + dims);
        const off = sample + ((idx[e] << 8) | idx[e + 1]) * 256;
        if (clipAt(off) !== first + k) throw new Error(`banco ${i}: el clip ${k} no está donde dice la cabecera`);
        b.values.push(Array.from(idx.subarray(e + 2, e + 2 + dims)));
      }
    }
    banks.push(b);
  }
  return banks;
}

/** Tabla de eventos del .EVT. */
export function parseRadioEvt(evt: Uint8Array): RadioEvent[] {
  const dv = new DataView(evt.buffer, evt.byteOffset, evt.byteLength);
  const n = dv.getUint32(0x10, true);
  const events: RadioEvent[] = [];
  for (let k = 0; k < n; k++) {
    const a = dv.getUint16(0x18 + 2 * k, true) * 4;
    const id = dv.getUint16(a, true), priority = dv.getUint16(a + 2, true), nAlt = dv.getUint16(a + 6, true), params = evt[a + 11];
    let p = a + 16;
    const alts: RadioPiece[][] = [];
    for (let j = 0; j < nAlt; j++) {
      const alt = p;
      const nPieces = evt[p + 2] / 4;
      const pos = Array.from(evt.subarray(p + 8, p + 8 + nPieces));
      const pieces: RadioPiece[] = [];
      let end = p + 8 + Math.ceil(nPieces / 4) * 4;
      for (const w of pos) {
        let q = alt + w * 4;
        const phrase = dv.getUint16(q, true), flag = dv.getUint16(q + 2, true), nc = dv.getUint32(q + 4, true);
        q += 8;
        const cond: [number, number][] = [];
        for (let c = 0; c < nc; c++, q += 8) cond.push([evt[q + 4], dv.getUint32(q, true)]);
        pieces.push({ phrase, speaker: flag === 0x0101, cond });
        end = Math.max(end, q);
      }
      alts.push(pieces);
      p = end;
    }
    events.push({ id, name: EVENT_NAMES[id] ?? `Event${id}`, priority, params, alts });
  }
  return events;
}

/** Paso del conversor (también lo llama install.ts: `step radio <iso> <ID>`). */
export async function main(args: string[]) {
  const wavIdx = args.indexOf("--wav");
  const wavList = wavIdx >= 0 ? args.splice(wavIdx, 2)[1].split(",").map(Number) : [];
  const [iso, id, langArg] = args;
  if (!iso || !id) { console.error("Uso: bun src/cli/radio.ts <iso> <ID> [SP|EN|IT] [--wav 0,1,2]"); process.exit(1); }
  const disc = await GameDisc.open(iso);
  disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
  // Idioma: PAL (SLES) → castellano; NTSC (SLUS) → inglés. Si falta, el primero que haya.
  const wanted = (langArg ?? process.env.ROCKPORT_RADIO_LANG ?? (id.startsWith("SLES") ? "SP" : "EN")).toUpperCase();
  const lang = [wanted, "SP", "EN", "IT"].find(l => disc.find(`SOUND\\SPEECH\\COPSPEECH_${l}.BIG`));
  if (!lang) { console.error("El disco no trae SOUND\\SPEECH\\COPSPEECH_*.BIG"); process.exit(1); }
  const read = async (ext: string) => disc.readEntry(disc.find(`SOUND\\SPEECH\\COPSPEECH_${lang}.${ext}`)!);
  const [big, idx, evt] = [await read("BIG"), await read("IDX"), await read("EVT")];

  const offs = findSchlClips(big);
  const byOff = new Map(offs.map((o, i) => [o, i]));
  let stereo = 0;
  const clips: [number, number, number][] = offs.map((o, i) => {
    const h = parseSchl(big.subarray(o, o + 256));
    if (!h || (h.codec2 !== 0x04 && h.codec2 !== 0x16)) throw new Error(`clip ${i}: no es MicroTalk`);
    if (h.channels > 1) stereo++;
    return [o, (i + 1 < offs.length ? offs[i + 1] : big.length) - o, h.numSamples];
  });
  const sampleRate = parseSchl(big.subarray(0, 256))!.sampleRate;
  const banks = parseRadioIdx(idx, off => byOff.get(off) ?? -1);
  const events = parseRadioEvt(evt);
  const phrases = new Set(banks.map(b => b.phrase));
  const missing = events.flatMap(e => e.alts.flat()).filter(p => !phrases.has(p.phrase));
  if (banks.reduce((s, b) => s + b.count, 0) !== clips.length) throw new Error("los bancos no cubren todos los clips");

  const out = `${outDir(id)}/radio`;
  mkdirSync(out, { recursive: true });
  await Bun.write(`${out}/COPSPEECH.BIG`, big);
  const totalSec = clips.reduce((s, c) => s + c[2], 0) / sampleRate;
  writeFileSync(`${out}/radio.json`, JSON.stringify({
    format: 1, disc: id, lang, sampleRate, codec: "EA MicroTalk 10:1 (SCHl v3, PS2)",
    note: "clips = [desplazamiento en COPSPEECH.BIG, bytes, muestras]; algunos clips son estéreo (la app los mezcla a mono). banks = frases por voz. events = qué frases dice cada evento (radio de la policía).",
    clips, banks, events,
  }));
  console.log(`radio ${lang}: ${clips.length} clips (${(totalSec / 60).toFixed(0)} min), ${banks.length} bancos, ${phrases.size} frases, ${events.length} eventos, ${stereo} en estéreo${missing.length ? `, ${missing.length} piezas sin banco` : ""}`);

  if (wavList.length) {
    mkdirSync(`${out}/wav`, { recursive: true });
    for (const k of wavList) {
      const [o, size] = clips[k];
      const { channels, sampleRate: sr } = decodeMicroTalkClip(big.subarray(o, o + size));
      writeFileSync(`${out}/wav/${String(k).padStart(5, "0")}.wav`, encodeWav(channels, sr));
    }
    console.log(`WAV de prueba → ${out}/wav (${wavList.length})`);
  }
}

if (import.meta.main) await main(Bun.argv.slice(2));
