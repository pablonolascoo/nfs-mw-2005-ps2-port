// Utilidades de la física del juego, copiadas de la decomp (dbalatoni13/nfsmw):
//   UMath.h (Ramp, Limit, Atan2a…), ConversionUtil.hpp (unidades), Misc/Table.cpp (Table, Graph, AverageWindow).
// La física trabaja en el ESPACIO DEL JUEGO ("Bond"): x derecha, y arriba, z adelante. Así cada fórmula queda
// literal. Se pasa al mundo del motor (X = z, Y = −x, Z = y, como bConvertFromBond) solo al consultar la
// colisión y al dibujar [D: doc 09].
import simd

typealias V3 = SIMD3<Float>

enum PM {
    static let epsilon: Float = 0.000001          // EPSILON de SuspensionRacer.cpp
    static let uEpsilon: Float = 1e-6              // UMath::Epsilon [I: mismo orden]

    // MARK: UMath [D: Libs/Support/Utility/UMath.h]
    @inline(__always) static func ramp(_ a: Float, _ lo: Float, _ hi: Float) -> Float {
        let r = hi - lo
        return r > uEpsilon ? max(0, min((a - lo) / r, 1)) : 0
    }
    @inline(__always) static func clamp(_ a: Float, _ lo: Float, _ hi: Float) -> Float { max(lo, min(a, hi)) }
    @inline(__always) static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    /// UMath::Limit: si a y l tienen el mismo signo, |a| no pasa de |l|; si no, a tal cual.
    @inline(__always) static func limit(_ a: Float, _ l: Float) -> Float {
        if a * l <= 0 { return a }
        return a > 0 ? min(a, l) : max(a, l)
    }

    // MARK: Unidades [D: Tools/Inc/ConversionUtil.hpp]. "Angle" del juego = vueltas (1 = 360°).
    static func mph2mps(_ x: Float) -> Float { x * 0.44703001 }
    static func mps2mph(_ x: Float) -> Float { x * 2.23699 }
    static func deg2angle(_ d: Float) -> Float { d / 360 }
    static func angle2deg(_ a: Float) -> Float { a * 360 }
    static func rad2angle(_ r: Float) -> Float { r / (2 * .pi) }
    static func angle2rad(_ a: Float) -> Float { a * 2 * .pi }
    static func deg2rad(_ d: Float) -> Float { d * 0.017453 }
    static func inch2m(_ x: Float) -> Float { x * 0.0254 }
    static func rpm2rps(_ x: Float) -> Float { x / 9.5492958 }
    static func rps2rpm(_ x: Float) -> Float { x * 9.549296 }
    static func lbin2nm(_ x: Float) -> Float { x * 175.1268 }
    static func ftlb2nm(_ x: Float) -> Float { x * 1.3558 }
    /// Atan2a: resultado en "Angle" (vueltas).
    static func atan2a(_ o: Float, _ a: Float) -> Float { atan2(o, a) / (2 * .pi) }
    static func atan2d(_ o: Float, _ a: Float) -> Float { atan2(o, a) * 180 / .pi }
    static func sina(_ a: Float) -> Float { sin(a * 2 * .pi) }

    static func unitCross(_ a: V3, _ b: V3) -> V3 {
        let c = simd_cross(a, b); let l = simd_length(c)
        return l > 1e-9 ? c / l : c
    }

    // MARK: Espacio del juego ↔ mundo del motor (Z arriba)
    @inline(__always) static func toWorld(_ g: V3) -> V3 { V3(g.z, -g.x, g.y) }
    @inline(__always) static func toGame(_ w: V3) -> V3 { V3(-w.y, w.z, w.x) }
}

/// Table [D: Misc/Table.cpp Table::GetValue]: tabla equiespaciada entre min y max, interpolación lineal, extremos fijos.
struct PTable {
    let data: [Float]; let minArg: Float; let maxArg: Float
    init(_ d: [Float], _ lo: Float, _ hi: Float) { data = d; minArg = lo; maxArg = hi }
    func value(_ arg: Float) -> Float {
        let n = data.count
        let normarg = Float(n - 1) / (maxArg - minArg) * (arg - minArg)
        let index = Int(normarg)                   // (int) trunca hacia cero
        if index < 0 || normarg < 0 { return data[0] }
        if index >= n - 1 { return data[n - 1] }
        var ind = Float(index); if ind > normarg { ind -= 1 }
        let delta = normarg - ind
        return (1 - delta) * data[index] + delta * data[index + 1]
    }
}

/// Graph / tGraph<float> [D: Misc/Table.cpp, Table.hpp]: puntos (x, y), interpolación lineal, extremos fijos.
struct PGraph {
    let pts: [(Float, Float)]
    init(_ p: [(Float, Float)]) { pts = p }
    func value(_ x: Float) -> Float {
        guard pts.count > 1 else { return pts.first?.1 ?? 0 }
        if x <= pts[0].0 { return pts[0].1 }
        if x >= pts[pts.count - 1].0 { return pts[pts.count - 1].1 }
        for i in 0..<(pts.count - 1) where x >= pts[i].0 && x < pts[i + 1].0 {
            let dx = pts[i + 1].0 - pts[i].0
            if abs(dx) > 1e-6 { return (x - pts[i].0) / dx * (pts[i + 1].1 - pts[i].1) + pts[i].1 }
            return (pts[i + 1].1 - pts[i].1) * 0.5 + pts[i].1
        }
        return pts[0].1
    }
}

/// AverageWindow [D: Misc/Table.cpp]: media de las muestras de los últimos `window` s (ranuras = window × freq).
final class AverageWindow {
    private var data: [Float], times: [Float]
    private let window: Float
    private var total: Float = 0, samples = 0, current = 0, oldest = 0
    private(set) var value: Float = 0
    init(_ window: Float, _ freq: Float) {
        let n = Int(window * freq + 0.5)
        self.window = window; data = Array(repeating: 0, count: n); times = Array(repeating: 0, count: n)
    }
    func reset(_ v: Float) {
        for i in data.indices { data[i] = v; times[i] = 0 }
        total = v * Float(data.count); value = 0; samples = 0; oldest = 0; current = 0
    }
    func record(_ v: Float, _ now: Float) {
        if data[current] == 0 && times[current] == 0 { samples += 1 } else { total -= data[current] }
        total += v; data[current] = v; times[current] = now
        while now - times[oldest] > window {
            if times[oldest] > 0 { total -= data[oldest]; data[oldest] = 0; times[oldest] = 0; samples -= 1 }
            oldest += 1; if oldest >= data.count { oldest = 0 }
        }
        current += 1
        value = total / Float(max(1, samples))
        if current >= data.count { current = 0 }
    }
}
