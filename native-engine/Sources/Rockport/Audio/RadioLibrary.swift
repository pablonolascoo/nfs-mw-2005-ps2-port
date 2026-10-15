// Radio de la policía del disco: índice (radio/radio.json, lo escribe tools/src/cli/radio.ts) y clips (radio/COPSPEECH.BIG).
//
// Cómo se arma una frase [I: deducido de COPSPEECH_*.EVT/.IDX y de la decomp, ver docs/es/16-audio-y-voces.md §6]:
//   evento (p. ej. InitPursuit) → alternativas → piezas (frase + condiciones) → banco de esa frase para la voz que habla →
//   clip cuyo valor de parámetro coincide (intensidad, sí/no, nº de sospechosos…).
//   · Cada frase tiene varios bancos: uno por voz [H: el nº de banco dentro de la frase = voz; se usa voz % bancos].
//   · Los parámetros son los campos del Csis::*Struct del evento: 1 = speaker_id, 2… = el resto en orden [D: SND_GEN/COPSPEECH.hpp].
//     Cada valor es un bit (enum de potencias de 2); aquí se pasa el índice del bit (0 = primer valor).
import Foundation

final class RadioLibrary {
    struct Index: Decodable {
        let lang: String
        let sampleRate: Int
        let clips: [[Int]]                 // [desplazamiento, bytes, muestras]
        let banks: [Bank]
        let events: [Event]
    }
    struct Bank: Decodable { let phrase: Int; let key: Int; let first: Int; let count: Int; let dims: Int; let values: [[Int]]? }
    struct Piece: Decodable { let phrase: Int; let speaker: Bool; let cond: [[Int]] }   // cond = [[parámetro, máscara]]
    struct Event: Decodable { let id: Int; let name: String; let priority: Int; let params: Int; let alts: [[Piece]] }

    let index: Index
    let lang: String
    private let big: Data
    private var banksByPhrase: [Int: [Int]] = [:]
    private var eventsByName: [String: Event] = [:]
    private var cache: [Int: [Float]] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLock = NSLock()

    /// `root` = carpeta de datos del disco (map-data/<ID> o Application Support/Rockport/<ID>).
    init?(root: URL) {
        let dir = root.appendingPathComponent("radio")
        guard let j = try? Data(contentsOf: dir.appendingPathComponent("radio.json")),
              let idx = try? JSONDecoder().decode(Index.self, from: j),
              let b = try? Data(contentsOf: dir.appendingPathComponent("COPSPEECH.BIG"), options: .alwaysMapped) else { return nil }
        index = idx; big = b; lang = idx.lang
        for (i, bank) in idx.banks.enumerated() { banksByPhrase[bank.phrase, default: []].append(i) }
        for e in idx.events { eventsByName[e.name] = e }
    }

    var eventNames: [String] { index.events.map(\.name) }
    func has(_ event: String) -> Bool { eventsByName[event] != nil }
    /// Número de voces distintas (máximo de bancos por frase).
    var voices: Int { banksByPhrase.values.map(\.count).max() ?? 1 }

    /// Clips de una línea completa para `event`, dicha por la voz `voice`, con `params` (nº de parámetro → índice de valor).
    func line(_ event: String, voice: Int, params: [Int: Int] = [:], rng: inout SplitMix) -> [Int]? {
        guard let e = eventsByName[event] else { return nil }
        func allowed(_ p: Piece) -> Bool { p.cond.allSatisfy { c in params[c[0]].map { (c[1] >> $0) & 1 == 1 } ?? true } }
        let alts = e.alts.filter { $0.allSatisfy(allowed) }
        for alt in (alts.isEmpty ? e.alts : alts).shuffled(using: &rng) {
            var clips: [Int] = []
            for p in alt {
                guard let banks = banksByPhrase[p.phrase], !banks.isEmpty else { clips.removeAll(); break }
                let bank = index.banks[p.speaker ? banks[voice % banks.count] : banks[Int(rng.next() % UInt64(banks.count))]]
                var cand = Array(0..<bank.count)
                if let vals = bank.values {
                    // Dimensión d del clip = parámetro de la condición d de la pieza
                    let ok = cand.filter { k in
                        (0..<min(bank.dims, p.cond.count)).allSatisfy { d in params[p.cond[d][0]].map { vals[k][d] == $0 } ?? true }
                    }
                    if !ok.isEmpty { cand = ok }
                }
                clips.append(bank.first + cand[Int(rng.next() % UInt64(cand.count))])
            }
            if !clips.isEmpty { return clips }
        }
        return nil
    }

    /// Clips sueltos de una frase (p. ej. la estática 0x173 de StaticInterrupt).
    func phraseClips(_ phrase: Int) -> [Int] {
        (banksByPhrase[phrase] ?? []).flatMap { i -> [Int] in let b = index.banks[i]; return Array(b.first..<(b.first + b.count)) }
    }

    /// Decodifica un clip (mono, −1…1, a `sampleRate`). Guarda los últimos 64.
    func samples(_ clip: Int) -> [Float] {
        cacheLock.lock(); if let s = cache[clip] { cacheLock.unlock(); return s }; cacheLock.unlock()
        guard clip >= 0, clip < index.clips.count else { return [] }
        let c = index.clips[clip]
        let out: [Float] = big.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            let sub = UnsafeBufferPointer(rebasing: p[c[0]..<min(p.count, c[0] + c[1])])
            return MicroTalk.decodeMono(sub)?.samples ?? []
        }
        cacheLock.lock()
        cache[clip] = out; cacheOrder.append(clip)
        if cacheOrder.count > 64 { cache[cacheOrder.removeFirst()] = nil }
        cacheLock.unlock()
        return out
    }
}

extension SplitMix: RandomNumberGenerator {}
