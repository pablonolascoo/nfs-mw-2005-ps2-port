// Tablas de IA del juego: map-data/<ID>/ai.json (tools/src/cli/ai-attribs.ts, de GLOBAL\ATTRIBUTES.BIN y TRACKS\L2RA.BUN).
// Todo lo que decide la IA sale de aquí; si falta un valor se usa el de la decomp (AITrafficManager.cpp, AIPursuit.cpp).
// Etiquetas: [V] valor leído del disco · [D] decomp · [I] inferido · [H] hipótesis.
import Foundation
import simd

struct TrafficPattern {
    struct Vehicle { let name: String; let model: String; let rate: Float; let maxInstances: Int; let percent: Int }
    let name: String
    let spawnTime: Float           // s
    let speedStreet: Float         // m/s (mph en el disco)
    let speedHighway: Float        // m/s
    let vehicles: [Vehicle]
}

/// Un nivel de persecución (clase pursuitlevels, colección heat_NN) [V].
struct PursuitLevel {
    struct Cop { let type: String; let model: String; let count: Int; let chance: Int }
    struct Formation { let type: Int; let duration: Float; let frequency: Float }
    let name: String
    let raw: [String: Any]
    let cops: [Cop]
    let formations: [Formation]
    func num(_ k: String, _ def: Float) -> Float { (raw[k] as? NSNumber)?.floatValue ?? def }
    var numPatrolCars: Int { Int(num("NumPatrolCars", 1)) }
    var fullEngagementCopCount: Int { Int(num("FullEngagementCopCount", 5)) }
    var evadeTimeout: Float { num("evadetimeout", 60) }
    var bustSpeedKmh: Float { num("BustSpeed", 5) }
    var frontLOS: Float { num("frontLOSdistance", 150) }
    var rearLOS: Float { num("rearLOSdistance", 50) }
    var timeBetweenCopSpawn: Float { num("TimeBetweenCopSpawn", 10) }
    var roadblockProbability: Float { num("roadblockprobability", 0) }
    var roadblockSpikeChance: Float { num("roadblockspikechance", 0) }
    var searchModeCityMph: Float { num("SearchModeCityMPH", 50) }
    var hiddenZoneTimeMultiplier: Float { num("HiddenZoneTimeMultiplier", 3) }
    var timePerHeatLevel: Float { num("TimePerHeatLevel", 60) }
    var collapseSpeedKmh: Float { num("CollapseSpeed", 50) }
    var collapseInnerRadius: Float { max(3, num("CollapseInnerRadius", 6)) }
    var boxinTightness: Float { num("BoxinTightness", 0.5) }
    var meterDeadZoneBusted: Float { num("MeterDeadZoneBustedDistance", 35) }
    var meterDeadZoneEvade: Float { num("MeterDeadZoneEvadeDist", 50) }
    var evadeSuccessHeatAdjust: Float { num("EvadeSuccessHeatAdjust", 0.95) }
    func scaleEscalation(bucket: Int) -> Float {
        guard let a = raw["ScaleEscalationPerBucket"] as? [NSNumber], !a.isEmpty else { return 1 }
        return a[max(0, min(a.count - 1, bucket))].floatValue
    }
}

struct AIZone {
    let type: String           // hidden, trafficPattern, neighbourhood, noCopSpawn, pursuitStart
    let data: String           // patrón de tráfico (trafficPattern)
    let bboxMin: float2, bboxMax: float2
    let points: [float2]
    func contains(_ p: float2) -> Bool {
        guard p.x >= bboxMin.x, p.y >= bboxMin.y, p.x <= bboxMax.x, p.y <= bboxMax.y, points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

struct AIVehicleAttribs {
    let maxSpeedKmh: Float; let topSpeedMultiplier: Float; let accelerationMultiplier: Float
    /// RepPointsForDestroying por nivel de calor (formato 11) [D: AIPursuit::IncNumCopsDestroyed]
    var repPointsForDestroying: [Int] = []
}

final class AITables {
    var trafficPatterns: [String: TrafficPattern] = [:]
    var heatLevels: [PursuitLevel] = []          // índice 0 = calor 1 (pursuitescalation.heattable) [V]
    var supportDelay: [Float] = []               // pursuitsupport.MinimumSupportDelay por nivel de calor
    var aiVehicle: [String: AIVehicleAttribs] = [:]
    var vehicleModel: [String: String] = [:]     // pvehicle → MODEL
    var infractions: [String: Float] = [:]
    var zones: [AIZone] = []

    static func mph(_ v: Float) -> Float { v * 0.44704 }

    init(url: URL) throws {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        func f(_ x: Any?) -> Float { (x as? NSNumber)?.floatValue ?? 0 }
        for (name, v) in obj["trafficPatterns"] as? [String: [String: Any]] ?? [:] {
            let vs = (v["vehicles"] as? [[String: Any]] ?? []).map {
                TrafficPattern.Vehicle(name: $0["vehicle"] as? String ?? "", model: $0["model"] as? String ?? "", rate: f($0["rate"]),
                                       maxInstances: Int(f($0["maxInstances"])), percent: Int(f($0["percent"])))
            }
            trafficPatterns[name] = TrafficPattern(name: name, spawnTime: f(v["spawnTime"]), speedStreet: AITables.mph(f(v["speedStreetMph"])),
                                                   speedHighway: AITables.mph(f(v["speedHighwayMph"])), vehicles: vs.filter { !$0.model.isEmpty })
        }
        let levels = obj["pursuitLevels"] as? [String: [String: Any]] ?? [:]
        for name in obj["heatTable"] as? [String] ?? [] {
            guard let l = levels[name] else { continue }
            let cops = (l["cops"] as? [[String: Any]] ?? []).map {
                PursuitLevel.Cop(type: $0["copType"] as? String ?? "", model: $0["model"] as? String ?? "", count: Int(f($0["count"])), chance: Int(f($0["chance"])))
            }
            let forms = (l["formations"] as? [[String: Any]] ?? []).map {
                PursuitLevel.Formation(type: Int(f($0["formationId"])), duration: f($0["duration"]), frequency: f($0["frequency"]))
            }
            heatLevels.append(PursuitLevel(name: name, raw: l, cops: cops, formations: forms))
        }
        let support = obj["pursuitSupport"] as? [String: [String: Any]] ?? [:]
        supportDelay = (obj["supportTable"] as? [String] ?? []).map { f(support[$0]?["minimumSupportDelay"]) }
        for (k, v) in obj["aiVehicle"] as? [String: [String: Any]] ?? [:] {
            aiVehicle[k] = AIVehicleAttribs(maxSpeedKmh: f(v["maxSpeedKmh"]), topSpeedMultiplier: f(v["topSpeedMultiplier"]), accelerationMultiplier: f(v["accelerationMultiplier"]),
                                            repPointsForDestroying: (v["repPointsForDestroying"] as? [NSNumber])?.map(\.intValue) ?? [])
        }
        for (k, v) in obj["vehicles"] as? [String: [String: Any]] ?? [:] { vehicleModel[k] = v["model"] as? String }
        for (k, v) in obj["infractions"] as? [String: Any] ?? [:] { infractions[k] = f(v) }
        for z in obj["zones"] as? [[String: Any]] ?? [] {
            let bb = (z["bbox"] as? [NSNumber] ?? []).map { $0.floatValue }
            let pts = (z["points"] as? [[NSNumber]] ?? []).map { float2($0[0].floatValue, $0[1].floatValue) }
            guard bb.count == 4 else { continue }
            let d = (z["data"] as? [Any])?.first.map { "\($0)" } ?? ""
            zones.append(AIZone(type: z["type"] as? String ?? "", data: d, bboxMin: float2(bb[0], bb[1]), bboxMax: float2(bb[2], bb[3]), points: pts))
        }
    }

    /// Nivel de calor 1…n → tabla (se recorta a los niveles que hay).
    func level(_ heat: Float) -> PursuitLevel? {
        guard !heatLevels.isEmpty else { return nil }
        return heatLevels[max(0, min(heatLevels.count - 1, Int(heat) - 1))]
    }

    /// Patrón de tráfico del barrio donde está `p` (zona TRAFFIC_PATTERN de TrackPathManager) o "default" [D: ChoosePattern].
    func pattern(at p: float2) -> TrafficPattern? {
        if let z = zones.first(where: { $0.type == "trafficPattern" && $0.contains(p) }), let tp = trafficPatterns[z.data] { return tp }
        return trafficPatterns["default"] ?? trafficPatterns.values.first
    }

    func inZone(_ type: String, _ p: float2) -> Bool { zones.contains { $0.type == type && $0.contains(p) } }
}
