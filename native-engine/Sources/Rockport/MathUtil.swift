// Matemática mínima (simd). Mundo con Z arriba, metros. Matrices en columnas (como Metal).
import simd

typealias float2 = SIMD2<Float>
typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>

extension float4x4 {
    static let identity = matrix_identity_float4x4

    init(translation t: float3) {
        self = matrix_identity_float4x4
        columns.3 = float4(t.x, t.y, t.z, 1)
    }

    init(scale s: float3) {
        self = float4x4(diagonal: float4(s.x, s.y, s.z, 1))
    }

    init(rotationZ a: Float) {
        let c = cos(a), s = sin(a)
        self = float4x4(columns: (float4(c, s, 0, 0), float4(-s, c, 0, 0), float4(0, 0, 1, 0), float4(0, 0, 0, 1)))
    }

    init(rotationY a: Float) {
        let c = cos(a), s = sin(a)
        self = float4x4(columns: (float4(c, 0, -s, 0), float4(0, 1, 0, 0), float4(s, 0, c, 0), float4(0, 0, 0, 1)))
    }

    init(rotationX a: Float) {
        let c = cos(a), s = sin(a)
        self = float4x4(columns: (float4(1, 0, 0, 0), float4(0, c, s, 0), float4(0, -s, c, 0), float4(0, 0, 0, 1)))
    }

    /// Vista: cámara en `eye` mirando a `target`, con `up` (Z del mundo). Espacio de vista: -Z adelante.
    static func lookAt(eye: float3, target: float3, up: float3) -> float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (
            float4(s.x, u.x, -f.x, 0),
            float4(s.y, u.y, -f.y, 0),
            float4(s.z, u.z, -f.z, 0),
            float4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Perspectiva con Z invertida y plano lejano infinito (profundidad 1 cerca, 0 en el infinito).
    /// Da precisión de sobra para una ciudad de 6 km con plano cercano de 0,3 m.
    static func perspectiveReversedInfinite(fovY: Float, aspect: Float, near: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        return float4x4(columns: (
            float4(x, 0, 0, 0),
            float4(0, y, 0, 0),
            float4(0, 0, 0, -1),
            float4(0, 0, near, 0)))
    }
}

/// Caja alineada con los ejes.
struct AABB {
    var min: float3
    var max: float3
    static let empty = AABB(min: float3(repeating: .greatestFiniteMagnitude), max: float3(repeating: -.greatestFiniteMagnitude))
    mutating func add(_ p: float3) { min = simd_min(min, p); max = simd_max(max, p) }
    var center: float3 { (min + max) * 0.5 }
    var size: float3 { max - min }
    var isEmpty: Bool { min.x > max.x }
    func distance(to p: float3) -> Float {
        let d = simd_max(simd_max(min - p, p - max), float3(repeating: 0))
        return simd_length(d)
    }
}

/// Planos del frustum a partir de viewProj (para descartar casillas fuera de cámara).
struct Frustum {
    var planes: [float4] = []
    init(_ m: float4x4) {
        let r0 = float4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = float4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = float4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = float4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        // Z invertida e infinita: el plano "cercano" es r3 - r2 (z <= w), sin plano lejano.
        planes = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2]
    }
    func intersects(_ b: AABB) -> Bool {
        for p in planes {
            let n = float3(p.x, p.y, p.z)
            let v = float3(n.x >= 0 ? b.max.x : b.min.x, n.y >= 0 ? b.max.y : b.min.y, n.z >= 0 ? b.max.z : b.min.z)
            if simd_dot(n, v) + p.w < 0 { return false }
        }
        return true
    }
}

func srgbToLinear(_ c: float3) -> float3 {
    func f(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4) }
    return float3(f(c.x), f(c.y), f(c.z))
}
