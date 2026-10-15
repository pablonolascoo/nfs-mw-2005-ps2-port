// Datos de la música interactiva (doc 25): music.json (proyectos PathFinder: nodos, ramas, eventos, muestras), los .MUS tal
// cual del disco (flujos SCHl GSTR de EA-XA v2 estéreo a 32 kHz, decodificados aquí igual que tools/src/lib/pathfinder.ts,
// idéntico a vgmstream [V]), las canciones de EA Trax y la capa «Ambience» de los ParameterMaps (effects.json, doc 24).
import Foundation

struct MusicNode {
    /// N > 0: muestra N−1 · 0: nodo mudo (cabecera de una parte) · −1: fin · −3: lanza el evento `event`.
    let wave: Int
    let section: Int
    let b3: Int
    /// En las ondas de persecución: router + 1 [I: el máximo coincide con el nº de routers en los 4 proyectos].
    let b4: Int
    let flags: Int
    /// En las ondas: el nodo cabecera de su parte (SongProgressCallback) [D].
    let ref: Int
    let event: Int
    /// Ramas {mín, máx, destino}: se sigue la que cumple mín < control ≤ máx.
    let branches: [(min: Int, max: Int, dest: Int)]
}

struct MusicEventDef {
    let index: Int
    let id: Int          // 24 bits bajos
    let name: String
    let actions: [[Int]] // [tipo, código, p0, p1, pista]
}

struct MusicSampleRef {
    let offset: Int, bytes: Int, ms: Int, rate: Int, channels: Int, samples: Int
}

final class MusicProject {
    let name: String
    let musURL: URL
    let nodes: [MusicNode]
    let events: [MusicEventDef]
    let samples: [MusicSampleRef]
    let vars: [(name: String, value: Int)]
    /// Routers: pares (onda de paso, destino) [I: doc 25 §6, MusicPathFinder].
    let routers: [[(via: Int, target: Int)]]
    /// Parte → nodo cabecera (NEUTRAL, LOSE…) [D: PFXMAP].
    let parts: [String: Int]
    private var byId: [Int: Int] = [:]
    private var mus: Data?

    init?(_ j: [String: Any], dir: URL) {
        guard let name = j["name"] as? String, let musName = j["mus"] as? String,
              let nodes = j["nodes"] as? [[Any]], let evs = j["events"] as? [[String: Any]], let smp = j["samples"] as? [[Int]] else { return nil }
        self.name = name
        musURL = dir.appendingPathComponent(musName)
        self.nodes = nodes.map { n in
            func i(_ k: Int) -> Int { (n[k] as? Int) ?? 0 }
            let br = (n.count > 8 ? n[8] as? [[Int]] : nil) ?? []
            return MusicNode(wave: i(0), section: i(1), b3: i(2), b4: i(3), flags: i(4), ref: i(5), event: i(7) & 0xFFFFFF,
                             branches: br.map { ($0[0], $0[1], $0[2]) })
        }
        events = evs.map { e in
            MusicEventDef(index: e["index"] as? Int ?? 0, id: (e["id"] as? Int ?? 0) & 0xFFFFFF, name: e["name"] as? String ?? "",
                          actions: e["actions"] as? [[Int]] ?? [])
        }
        samples = smp.map { MusicSampleRef(offset: $0[0], bytes: $0[1], ms: $0[2], rate: $0[3], channels: $0[4], samples: $0[5]) }
        vars = (j["vars"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["value"] as? Int ?? 0) }
        routers = (j["routers"] as? [[[Int]]] ?? []).map { r in r.map { ($0[0], $0[1]) } }
        parts = j["parts"] as? [String: Int] ?? [:]
        for e in events { byId[e.id] = e.index }
    }

    func event(id: Int) -> MusicEventDef? { byId[id & 0xFFFFFF].map { events[$0] } }

    /// El .MUS mapeado en memoria (cientos de MB: solo se lee lo que suena).
    private func musData() -> Data? {
        if mus == nil { mus = try? Data(contentsOf: musURL, options: .alwaysMapped) }
        return mus
    }

    /// Decodifica la muestra `index` → PCM estéreo (Int16 por canal) a su frecuencia.
    func decode(sample index: Int) -> MusicPCM? {
        guard index >= 0, index < samples.count, let d = musData() else { return nil }
        let s = samples[index]
        guard s.offset + 16 <= d.count else { return nil }
        return MusicDecoder.decodeStream(d, offset: s.offset)
    }
}

/// PCM de una muestra de música (no cambia una vez creada: el hilo de audio la lee sin cerrojo).
final class MusicPCM {
    let left: [Int16]
    let right: [Int16]
    let rate: Int
    init(left: [Int16], right: [Int16], rate: Int) { self.left = left; self.right = right; self.rate = rate }
    var count: Int { left.count }
    var seconds: Double { Double(count) / Double(rate) }
}

enum MusicDecoder {
    private static let xa: [Int32] = [0, 240, 460, 392, 0, 0, -208, -220]

    /// Flujo SCHl «GSTR» (doc 25 §4): cabecera con etiquetas, SCCl, SCDl × n, SCEl. EA-XA v2 por canal; la historia sigue
    /// de un bloque al siguiente; el nº de muestras de la cabecera manda.
    static func decodeStream(_ d: Data, offset: Int) -> MusicPCM? {
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MusicPCM? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func tag(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
            func u32le(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
            func u32be(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
            let SCHl: UInt32 = 0x5343_486C, SCDl: UInt32 = 0x5343_446C, SCEl: UInt32 = 0x5343_456C, SCCl: UInt32 = 0x5343_436C
            guard offset + 16 <= n, tag(offset) == SCHl else { return nil }
            let hsize = u32le(offset + 4)
            var tags: [Int: Int] = [:]
            var p = offset + 16
            while p + 1 < offset + hsize {
                let t = Int(b[p]); p += 1
                if t == 0xFF { break }
                if t == 0xFC || t == 0xFD || t == 0xFE { continue }
                let k = Int(b[p]); p += 1
                var v = 0
                for j in 0..<k { v = v << 8 | Int(b[p + j]) }
                p += k; tags[t] = v
            }
            let rate = tags[0x84] ?? 32000, ch = max(1, tags[0x82] ?? 1)
            var blocks: [(Int, Int)] = []
            var q = offset + hsize, total = 0
            while q + 8 <= n {
                let id = tag(q), size = u32le(q + 4)
                if id == SCEl { break }
                guard size >= 8 else { break }
                if id == SCDl { let k = u32be(q + 8); blocks.append((q, k)); total += k }
                else if id != SCCl { break }
                q += size
            }
            let want = tags[0x85] ?? total
            var outs = [[Int16]](repeating: [Int16](repeating: 0, count: total), count: ch)
            var h1 = [Int32](repeating: 0, count: ch), h2 = [Int32](repeating: 0, count: ch)
            var at = 0
            for (q, cnt) in blocks {
                for c in 0..<ch {
                    var pp = q + 0x0C + 4 * ch + u32be(q + 0x0C + 4 * c)
                    var s1 = h1[c], s2 = h2[c], k = 0
                    outs[c].withUnsafeMutableBufferPointer { o in
                        while k < cnt && pp < n {
                            let info = b[pp]
                            if info == 0xEE {
                                guard pp + 61 <= n else { pp = n; break }
                                s1 = Int32(Int16(bitPattern: UInt16(b[pp + 1]) << 8 | UInt16(b[pp + 2])))
                                s2 = Int32(Int16(bitPattern: UInt16(b[pp + 3]) << 8 | UInt16(b[pp + 4])))
                                for i in 0..<28 where k < cnt {
                                    o[at + k] = Int16(bitPattern: UInt16(b[pp + 5 + 2 * i]) << 8 | UInt16(b[pp + 6 + 2 * i])); k += 1
                                }
                                pp += 61
                            } else {
                                guard pp + 15 <= n else { pp = n; break }
                                let c1 = xa[Int(info >> 4) & 3], c2 = xa[(Int(info >> 4) & 3) + 4], shift = Int32(info & 0x0F) + 8
                                for i in 0..<28 where k < cnt {
                                    let byte = b[pp + 1 + (i >> 1)]
                                    let nib = Int32((i & 1) == 1 ? byte & 0x0F : byte >> 4)
                                    var s = (nib << 28) >> shift
                                    s = (s + c1 * s1 + c2 * s2) >> 8
                                    s = max(-32768, min(32767, s))
                                    o[at + k] = Int16(s); k += 1
                                    s2 = s1; s1 = s
                                }
                                pp += 15
                            }
                        }
                    }
                    h1[c] = s1; h2[c] = s2
                }
                at += cnt
            }
            let len = min(want, total)
            let l = Array(outs[0].prefix(len)), r = ch > 1 ? Array(outs[1].prefix(len)) : l
            return MusicPCM(left: l, right: r, rate: rate)
        }
    }
}

struct MusicSong {
    let index: Int
    let artist: String
    let title: String
    let album: String
    /// FE = menús, IG = juego, AL = las dos [V: DefPlay].
    let defPlay: String
    let pathEvent: Int
}

/// music.json completo: los 5 proyectos (MW_MUSIC + MW_MUS_1…4), canciones y ambientes.
final class MusicLibrary {
    let root: URL
    let projects: [MusicProject]
    let songs: [MusicSong]
    /// Zona de ambiente 0–13 → id del evento de MW_MUSIC [D: AmbientCrossMap].
    let ambienceEvents: [Int: Int]
    let mix: MusicMix

    var licensed: MusicProject { projects[0] }
    var interactive: [MusicProject] { Array(projects.dropFirst()) }

    init?(root: URL) {
        self.root = root
        let dir = root.appendingPathComponent("music")
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("music.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ps = j["projects"] as? [[String: Any]] else { return nil }
        projects = ps.compactMap { MusicProject($0, dir: dir) }
        guard projects.count >= 2, FileManager.default.fileExists(atPath: projects[0].musURL.path) else { return nil }
        songs = (j["songs"] as? [[String: Any]] ?? []).map {
            MusicSong(index: $0["index"] as? Int ?? 0, artist: $0["artist"] as? String ?? "", title: $0["title"] as? String ?? "",
                      album: $0["album"] as? String ?? "", defPlay: $0["defPlay"] as? String ?? "AL", pathEvent: ($0["pathEvent"] as? Int ?? 0) & 0xFFFFFF)
        }
        var amb: [Int: Int] = [:]
        for a in j["ambience"] as? [[String: Any]] ?? [] { if let z = a["zone"] as? Int, let id = a["id"] as? Int { amb[z] = id & 0xFFFFFF } }
        ambienceEvents = amb
        mix = MusicMix(dir: dir)
    }
}

/// Niveles del mapa de mezcla del juego para la música (MIXMAPS\MAPOUTPUT.MXB → mixmaps.json, estado MUSIC; doc 25 §7).
/// `MixData` de cada canal maestro = {i16 mínimo (−10000), i16 nivel} en milibelios [V lectura; H unidades].
struct MusicMix {
    var licensedFE: Float = -1100, licensedIG: Float = 200, composedFE: Float = -100, composedIG: Float = 0
    var ambienceFE: Float = -400, ambienceIG: Float = -700
    /// «Speech Ducker» del estado MAIN: −555 mB [H: nUScaleCntSwing bajo 16 bits].
    var speechDuck: Float = -555
    var fromFile = false

    init(dir: URL) {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("mixmaps.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let maps = j["maps"] as? [String: Any],
              let m = maps["MAPOUTPUT"] as? [String: Any], let states = m["states"] as? [[String: Any]],
              let music = states.first(where: { $0["name"] as? String == "MUSIC" }), let masters = music["masterChannels"] as? [[String: Any]] else { return }
        func level(_ r: [String: Any]) -> Float? { (r["values"] as? [Int]).flatMap { $0.count > 1 ? Float(Int16(truncatingIfNeeded: $0[1] >> 16)) : nil } }
        for r in masters {
            guard let name = r["name"] as? String, let inputs = r["inputNames"] as? [String], let v = level(r) else { continue }
            switch (name, inputs.first ?? "") {
            case ("FE", "Licensed"): licensedFE = v
            case ("In Game", "Licensed"): licensedIG = v
            case ("FE", "Composed"): composedFE = v
            case ("In Game", "Composed"): composedIG = v
            case ("Ambience", _): ambienceFE = v
            case ("IG Ambience", _): ambienceIG = v
            default: break
            }
        }
        if let main = states.first(where: { $0["name"] as? String == "MAIN" }), let evs = main["eventCtls"] as? [[String: Any]],
           let sd = evs.first(where: { $0["name"] as? String == "Speech Ducker" }), let v = sd["values"] as? [Int], v.count > 1 {
            speechDuck = Float(Int16(truncatingIfNeeded: v[1]))
        }
        fromFile = true
    }

    static func gain(_ mB: Float) -> Float { powf(10, mB / 2000) }
}

/// Capa «Ambience» de los ParameterMaps (effects.json → parameterMaps, doc 24 §6.2): zona 0–8 en cada punto del mapa.
struct AmbienceMap {
    let rect: [Float]
    let quads: [Int]
    let sets: [[Int]]

    init?(root: URL) {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("effects.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let maps = j["parameterMaps"] as? [[String: Any]],
              let a = maps.first(where: { $0["name"] as? String == "Ambience" }),
              let r = a["rect"] as? [NSNumber], let s = a["sets"] as? [[Int]] else { return nil }
        rect = r.map { $0.floatValue }; quads = a["quads"] as? [Int] ?? []; sets = s
    }

    /// Árbol cuaternario [D: ParameterMaps.cpp; igual que parameterSetAt de tools/src/lib/world-extra.ts].
    func zone(x: Float, y: Float) -> Int {
        var set = 0
        if !quads.isEmpty {
            var left = rect[0], top = rect[1], right = rect[2], bottom = rect[3], i = 0
            set = -1
            for _ in 0..<64 {
                guard i * 4 + 3 < quads.count else { break }
                let q0 = quads[i * 4], q1 = quads[i * 4 + 1], q2 = quads[i * 4 + 2], q3 = quads[i * 4 + 3]
                if q0 == 0 { set = q1; break }
                let cx = (left + right) / 2, cy = (top + bottom) / 2
                if x < cx { right = cx; if y < cy { bottom = cy; i = q0 } else { top = cy; i = q1 } }
                else { left = cx; if y < cy { bottom = cy; i = q2 } else { top = cy; i = q3 } }
            }
        }
        guard set >= 0, set < sets.count, let z = sets[set].first else { return 0 }
        return z
    }
}
