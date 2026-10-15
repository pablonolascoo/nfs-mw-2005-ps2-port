// Tuneo del taller: pintura, vinilo, llantas, alerón y kit de carrocería sobre el sistema de presets del juego
// (presets.json + CarSkin.swift) y la barra de luz (Input/LightBarConfig.swift).
//
// Cada coche del jugador (nombre de preset, p. ej. M3GTRCAREERSTART, o modelo de serie comprado, p. ej. RX7) puede llevar
// un `CarTune`: lo que cambia respecto a su preset. Se guarda en ~/Library/Application Support/Rockport/garage.json.
// Las piezas salen de los presets del disco: llantas de los paquetes WHEELS (las del juego), alerones de los paquetes
// SPOILER*, vinilos de los presets del mismo coche (CARS\<COCHE>\VINYLS.BIN) y las 48 pinturas de los presets [V].
import Foundation
import Metal
import simd

struct CarTune: Codable, Equatable {
    /// Nombre de la pintura del juego (PresetColour.name, p. ej. METAL_L1_COLOR02).
    var paint: String?
    /// Vinilo: nombre del preset del que se toma (mismo coche); "" = sin vinilo.
    var vinyl: String?
    /// Llantas: preset del que se toman (paquete WHEELS); "" = de serie.
    var rims: String?
    /// Alerón: preset del que se toma (paquetes SPOILER*); "" = sin alerón de tuneo.
    var spoiler: String?
    /// Kit de carrocería (KITnn de las piezas del coche).
    var kit: Int?
}

enum CarTuning {
    private struct File: Codable { var cars: [String: CarTune] = [:] }
    private static var file: File?
    static var url: URL { DataLocator.appSupport.appendingPathComponent("garage.json") }
    /// Las pruebas sin ventana no tocan los ajustes del usuario.
    static var persist = true

    static func tune(_ key: String) -> CarTune? {
        if file == nil { file = (persist ? (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) : nil) ?? File() }
        return file?.cars[key]
    }
    static func set(_ key: String, _ t: CarTune) {
        if file == nil { _ = tune(key) }
        file?.cars[key] = t
        guard persist, let f = file else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(f).write(to: url, options: .atomic)
    }

    /// Pinturas del juego (las de los presets del disco), sin repetir, ordenadas por acabado y nombre.
    static func paints(_ data: GameData) -> [PresetColour] {
        var seen = Set<String>(), out: [PresetColour] = []
        for p in CarPresets.all(data) { for c in [p.paint, p.rimPaint].compactMap({ $0 }) where seen.insert(c.name).inserted { out.append(c) } }
        return out.sorted { ($0.finish, $0.name) < ($1.finish, $1.name) }
    }
    /// Presets que traen llantas del paquete WHEELS (una por modelo de llanta).
    static func rimDonors(_ data: GameData) -> [CarPreset] {
        var seen = Set<String>(), out: [CarPreset] = []
        for p in CarPresets.all(data) {
            guard let w = p.solid("FRONT_WHEEL"), w.glb == "WHEELS", let r = p.rim else { continue }
            if seen.insert(r.name).inserted { out.append(p) }
        }
        return out
    }
    /// Presets con alerón de tuneo (paquetes SPOILER*).
    static func spoilerDonors(_ data: GameData) -> [CarPreset] {
        var seen = Set<String>(), out: [CarPreset] = []
        for p in CarPresets.all(data) {
            guard let s = p.solid("SPOILER"), s.glb.hasPrefix("SPOILER") else { continue }
            if seen.insert(s.node).inserted { out.append(p) }
        }
        return out
    }
    /// Presets del mismo coche con vinilo.
    static func vinylDonors(_ data: GameData, car: String) -> [CarPreset] {
        var seen = Set<String>(), out: [CarPreset] = []
        for p in CarPresets.all(data) where p.car == car { if let v = p.vinyl, seen.insert(v.name).inserted { out.append(p) } }
        return out
    }
    /// Kits del coche: los KITnn que tienen sus piezas (kit 0 = de serie).
    static func kits(_ data: GameData, car: String) -> [Int] {
        guard let f = try? GLB.load(data.url("cars/\(car).glb")) else { return [0] }
        var s = Set<Int>([0])
        for p in f.primitives { if let k = p.piece?.kit, p.piece?.slot == "BODY" { s.insert(k) } }
        return s.sorted()
    }

    /// Preset del coche con el tuneo aplicado (nil = coche de serie sin preset).
    static func preset(_ key: String, data: GameData, tune: CarTune?) -> CarPreset? {
        guard let base = CarPresets.named(key, in: data) else { return nil }
        guard let t = tune else { return base }
        var solids = base.solids
        var rim = base.rim, rimPaint = base.rimPaint, vinyl = base.vinyl
        let paint = t.paint.flatMap { n in paints(data).first { $0.name == n } } ?? base.paint
        if let r = t.rims {
            if r.isEmpty {
                // De serie: las ruedas del propio coche
                solids.removeAll { $0.slot == "FRONT_WHEEL" || $0.slot == "REAR_WHEEL" }
                solids.append(.init(slot: "FRONT_WHEEL", part: "WHEEL", glb: base.car, node: "\(base.car)_KIT00_FRONT_TIRE_B"))
                rim = nil
            } else if let d = CarPresets.named(r, in: data) {
                solids.removeAll { $0.slot == "FRONT_WHEEL" || $0.slot == "REAR_WHEEL" }
                solids += d.solids.filter { $0.slot == "FRONT_WHEEL" || $0.slot == "REAR_WHEEL" }
                rim = d.rim; rimPaint = d.rimPaint ?? rimPaint
            }
        }
        if let s = t.spoiler {
            solids.removeAll { $0.slot == "SPOILER" || $0.slot == "UNIVERSAL_SPOILER_BASE" }
            if !s.isEmpty, let d = CarPresets.named(s, in: data) {
                solids += d.solids.filter { $0.slot == "SPOILER" || $0.slot == "UNIVERSAL_SPOILER_BASE" }
            }
        }
        if let v = t.vinyl {
            vinyl = v.isEmpty ? nil : CarPresets.named(v, in: data)?.vinyl
        }
        // Nombre propio por combinación: CarSkin guarda la piel compuesta por nombre de preset
        let tag = [paint?.name ?? "-", vinyl?.name ?? "-", rim?.name ?? "-", rimPaint?.name ?? "-"].joined(separator: "~")
        return CarPreset(name: base.name + "~" + tag, car: base.car, base: base.base, blacklist: base.blacklist, kit: t.kit ?? base.kit, solids: solids,
                         paint: paint, vinyl: vinyl, rim: rim, rimPaint: rimPaint, windowTint: base.windowTint, licensePlate: base.licensePlate)
    }

    /// Coche montado: preset del juego con su tuneo, o modelo de serie con pintura/kit.
    static func build(_ key: String, engine: Engine, tune override: CarTune? = nil) -> Car? {
        let t = override ?? tune(key)
        if let p = preset(key, data: engine.data, tune: t) {
            return Car(device: engine.device, data: engine.data, textures: engine.textures, name: p.car, paint: Config.playerPaint, preset: p)
        }
        let paint = t?.paint.flatMap { n in paints(engine.data).first { $0.name == n }?.srgb } ?? Config.playerPaint
        var cfg = CarConfig(); cfg.kit = t?.kit ?? 0
        return Car(device: engine.device, data: engine.data, textures: engine.textures, name: key, paint: paint, config: cfg)
    }

    /// Cambia el coche del jugador por uno nuevo en el mismo sitio (tras tunear o comprar).
    static func replacePlayerCar(_ engine: Engine, key: String, tune override: CarTune? = nil) {
        guard let new = build(key, engine: engine, tune: override) else { return }
        if let old = engine.car {
            new.place(old.position + float3(0, 0, 0.6), yaw: old.yaw, collision: engine.collision, probe: 2)
        }
        engine.car = new
        LightBar.shared.select(car: new.specs?.model ?? key)
    }
}
