// Barra de luz del DualShock 4 / DualSense como opción de tuneo, igual que alerones o llantas.
//
// Modos (LightBarMode): pintura del coche (por defecto) · color propio · luces de policía · según el calor · apagada.
// Encima de cualquier modo (salvo «apagada») van los colores de estado de la persecución, si `stateColors` está activo:
//   persecución  → rojo/azul con el mismo patrón que las luces de los coches patrulla del juego [D: CarRender.cpp
//                  coplightflicker2: rojo si cos(8t) > 0,2, azul si cos(8t + π) > 0,2, brillo cos²(24t)];
//                  el calor acelera el patrón y sube el brillo [diseño propio]
//   enfriamiento → pulso lento ámbar/azul (2,4 s) [diseño propio]
//   arrestado    → rojo fijo que late [diseño propio]
//   escapado     → tres destellos verdes y vuelta al modo normal [diseño propio]
//
// Se guarda en ~/Library/Application Support/Rockport/settings.json, clave "lightBar" (el resto del archivo no se toca):
//   { "lightBar": { "default": { "mode": "paint", … }, "cars": { "BMWM3GTRE46": { "mode": "custom", "color": [1,0,0.5] } } } }
// Cada coche puede llevar la suya (`select(car:)`); si no tiene, se usa "default".
//
// API para el menú de tuneo / garaje (UI/*) y los coches (Car*.swift):
//   LightBar.shared.setMode(.custom); LightBar.shared.setCustomColor(SIMD3(1, 0, 0.5))
//   LightBar.shared.setBrightness(0.8); LightBar.shared.setStateColors(true)
//   LightBar.shared.select(car: "BMWM3GTRE46")         // al cambiar de coche
//   LightBar.shared.settings / LightBar.modes            // para pintar el menú
// Para probar al arrancar (no se guarda): --lightbar paint|police|heat|off|custom:FF0080   (o ROCKPORT_LIGHTBAR)
// Mandos sin barra de luz: no pasa nada (Controllers solo la aplica si el mando tiene `light`).
import Foundation
import simd

enum LightBarMode: String, Codable, CaseIterable {
    case paint, custom, police, heat, off
}

/// Ajustes de la barra de luz de un coche (o por defecto). Codable: se puede guardar también dentro de la configuración del coche.
struct LightBarSettings: Codable, Equatable {
    var mode: LightBarMode = .paint
    /// Color propio (sRGB 0…1) para el modo `.custom`.
    var color: [Float] = [1, 0.4, 0]
    /// Brillo general 0…1.
    var brightness: Float = 1
    /// Colores de estado de la persecución por encima del modo.
    var stateColors: Bool = true
}

/// Estado de la persecución que interesa a la luz (y a la radio). Lo rellena PursuitFX desde PoliceManager.
enum PursuitLight: Equatable { case none, chase, cooldown, busted, evaded }

final class LightBar {
    static let shared = LightBar()

    /// Para el menú: modo, nombre en castellano, nombre en inglés.
    static let modes: [(LightBarMode, String, String)] = [
        (.paint, "Color de la pintura", "Paint colour"), (.custom, "Color propio", "Custom colour"),
        (.police, "Luces de policía", "Police lights"), (.heat, "Según el calor", "Heat level"), (.off, "Apagada", "Off"),
    ]

    private(set) var settings = LightBarSettings()
    private var perCar: [String: LightBarSettings] = [:]
    private var defaults = LightBarSettings()
    private var car: String?
    private var override: LightBarSettings?        // --lightbar: solo esta sesión
    private(set) var pursuit: PursuitLight = .none
    private(set) var heat: Float = 1
    private var stateSince: Double = 0
    private var lastClock: Double = 0
    /// Avisos al cambiar (p. ej. para refrescar el menú).
    var onChange: ((LightBarSettings) -> Void)?

    static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rockport/settings.json")
    }

    private init() {
        load()
        let args = CommandLine.arguments
        let arg = args.firstIndex(of: "--lightbar").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["ROCKPORT_LIGHTBAR"]
        if let arg { override = LightBar.parse(arg, base: settings); if let o = override { settings = o } }
    }

    /// "paint", "police", "heat", "off", "custom:FF0080" o "#FF0080".
    static func parse(_ s: String, base: LightBarSettings) -> LightBarSettings? {
        var r = base
        let low = s.lowercased()
        if let m = LightBarMode(rawValue: low) { r.mode = m; return r }
        let hex = low.hasPrefix("custom:") ? String(low.dropFirst(7)) : low.hasPrefix("#") ? String(low.dropFirst()) : ""
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { fputs("--lightbar: valor no válido «\(s)» (paint|police|heat|off|custom:RRGGBB)\n", stderr); return nil }
        r.mode = .custom
        r.color = [Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255]
        return r
    }

    // MARK: API

    func setMode(_ m: LightBarMode) { change { $0.mode = m } }
    func setCustomColor(_ rgb: SIMD3<Float>) { change { $0.color = [rgb.x, rgb.y, rgb.z]; $0.mode = .custom } }
    func setBrightness(_ b: Float) { change { $0.brightness = max(0, min(1, b)) } }
    func setStateColors(_ on: Bool) { change { $0.stateColors = on } }
    /// Sustituye todos los ajustes del coche actual (p. ej. al cargar una configuración guardada con el coche).
    func apply(_ s: LightBarSettings) { change { $0 = s } }

    /// Coche activo: carga sus ajustes (o los de por defecto).
    func select(car name: String?) {
        car = name
        if override == nil { settings = name.flatMap { perCar[$0] } ?? defaults }
        onChange?(settings)
    }

    /// Lo llama PursuitFX cada fotograma con el estado de la persecución.
    func note(_ p: PursuitLight, heat h: Float) {
        if p != pursuit { pursuit = p; stateSince = lastClock }
        heat = h
    }

    private func change(_ f: (inout LightBarSettings) -> Void) {
        f(&settings)
        if override != nil { override = settings; onChange?(settings); return }   // sesión de prueba: no se guarda
        if let car { perCar[car] = settings } else { defaults = settings }
        save()
        onChange?(settings)
    }

    // MARK: Color

    /// Color de la barra (sRGB 0…1) en el instante `t` (s). `paint` = color de la pintura del coche.
    func color(time t: Double, paint: SIMD3<Float>) -> SIMD3<Float> {
        lastClock = t
        let s = settings
        if s.mode == .off { return .zero }
        let k = t - stateSince
        let h = max(1, min(10, heat))
        var c: SIMD3<Float>
        switch s.mode {
        case .paint: c = paint
        case .custom: c = s.color.count == 3 ? SIMD3(s.color[0], s.color[1], s.color[2]) : paint
        case .police: c = LightBar.strobe(t, speed: 0.8, intensity: 0.85)
        case .heat: c = LightBar.heatColor(h, t)
        case .off: c = .zero
        }
        if s.stateColors {
            switch pursuit {
            case .none: break
            case .chase:
                // El calor 1…5 acelera el patrón (×1 → ×1,6) y sube el brillo
                c = LightBar.strobe(t, speed: 1 + 0.15 * Double(min(h, 5) - 1), intensity: 0.7 + 0.075 * min(h, 5) - 0.075)
            case .cooldown:
                let ph = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
                let w = Float(pow(sin(ph * 2 * .pi), 2))
                c = (ph < 0.5 ? SIMD3<Float>(1, 0.5, 0) : SIMD3<Float>(0, 0.25, 1)) * (0.15 + 0.85 * w)
            case .busted:
                c = SIMD3<Float>(1, 0, 0) * Float(0.35 + 0.65 * abs(sin(k * .pi / 0.8)))
            case .evaded:
                if k < 1.2 { c = SIMD3<Float>(0, 1, 0.25) * Float(Int(k / 0.2) % 2 == 0 ? 1 : 0.1) }
                else if k < 2.0 { let a = Float((k - 1.2) / 0.8); c = SIMD3<Float>(0, 1, 0.25) * (1 - a) + c * a }
            }
        }
        return simd_clamp(c * s.brightness, .zero, SIMD3(repeating: 1))
    }

    /// Patrón de las luces de los coches patrulla del juego [D: CarRender.cpp coplightflicker2]:
    /// rojo si cos(8t) > 0,2; azul si cos(8t + π) > 0,2; los dos con brillo cos²(24t) (aquí suavizado a 0,55…1).
    static func strobe(_ t: Double, speed: Double, intensity: Float) -> SIMD3<Float> {
        let x = t * speed
        let pulse = Float(0.55 + 0.45 * pow(cos(24 * x), 2))
        let red: Float = cos(8 * x) > 0.2 ? 1 : 0
        let blue: Float = cos(8 * x + .pi) > 0.2 ? 1 : 0
        return (SIMD3<Float>(1, 0, 0) * red + SIMD3<Float>(0, 0.25, 1) * blue) * pulse * intensity
    }

    /// Calor 1 verde → 2 amarillo → 3 naranja → 4 rojo → 5+ rojo/magenta latiendo [diseño propio].
    static func heatColor(_ h: Float, _ t: Double) -> SIMD3<Float> {
        let stops: [SIMD3<Float>] = [SIMD3(0, 1, 0.2), SIMD3(1, 0.9, 0), SIMD3(1, 0.45, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0.5)]
        let x = min(max(h - 1, 0), 4)
        let i = min(Int(x), 3), f = x - Float(i)
        var c = stops[i] * (1 - f) + stops[i + 1] * f
        if h >= 5 { c *= Float(0.6 + 0.4 * abs(sin(t * .pi * 1.5))) }
        return c
    }

    // MARK: Archivo

    private func load() {
        guard let d = try? Data(contentsOf: LightBar.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let lb = root["lightBar"], let raw = try? JSONSerialization.data(withJSONObject: lb) else { return }
        struct File: Codable { var `default`: LightBarSettings?; var cars: [String: LightBarSettings]? }
        guard let f = try? JSONDecoder().decode(File.self, from: raw) else { fputs("settings.json: «lightBar» no válido, se usan los valores por defecto\n", stderr); return }
        defaults = f.default ?? LightBarSettings()
        perCar = f.cars ?? [:]
        settings = defaults
    }

    private func save() {
        let url = LightBar.settingsURL
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let enc = JSONEncoder()
        func obj(_ s: LightBarSettings) -> Any { (try? JSONSerialization.jsonObject(with: enc.encode(s))) ?? [:] }
        root["lightBar"] = ["default": obj(defaults), "cars": perCar.mapValues(obj)]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { fputs("No se pudo guardar \(url.path): \(error.localizedDescription)\n", stderr) }
    }
}
