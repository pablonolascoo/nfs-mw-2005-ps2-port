// Intersección de volúmenes (Dynamics::Collision::Geometry::FindIntersection [D: solo la cabecera; Geometry.cpp está vacío]):
// cajas orientadas (OBB) por el teorema del eje separador con 15 ejes, esferas contra cajas y esferas contra esferas.
// Devuelve la normal (hacia A: dirección en la que hay que empujar A), la penetración y un punto de contacto [I].
// Todo en el mundo del motor (Z arriba).
import simd

struct CrashPrim {
    var c: float3            // centro
    var ax: float3x3         // ejes (columnas, unitarios)
    var e: float3            // medias medidas
    var sphere: Bool
    var r: Float             // radio (esferas) o radio envolvente (cajas)
    var surface: String?

    func corners() -> [float3] {
        var out: [float3] = []
        out.reserveCapacity(8)
        for sx in [-1, 1] as [Float] { for sy in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {
            out.append(c + ax.columns.0 * (e.x * sx) + ax.columns.1 * (e.y * sy) + ax.columns.2 * (e.z * sz))
        } } }
        return out
    }
    /// ¿Está p dentro de la caja (con margen)?
    func contains(_ p: float3, margin: Float = 0.02) -> Bool {
        let d = p - c
        return abs(simd_dot(d, ax.columns.0)) <= e.x + margin && abs(simd_dot(d, ax.columns.1)) <= e.y + margin && abs(simd_dot(d, ax.columns.2)) <= e.z + margin
    }
    /// Punto de la caja más cercano a p.
    func closest(_ p: float3) -> float3 {
        let d = p - c
        var q = c
        for i in 0..<3 {
            let a = ax[i], h = e[i]
            q += a * max(-h, min(h, simd_dot(d, a)))
        }
        return q
    }
    func support(_ dir: float3) -> float3 {
        if sphere { return c + simd_normalize(dir) * r }
        var p = c
        for i in 0..<3 { let a = ax[i]; p += a * (simd_dot(dir, a) >= 0 ? e[i] : -e[i]) }
        return p
    }
}

enum CrashGeometry {
    struct Contact { var n: float3; var depth: Float; var p: float3 }

    static func intersect(_ a: CrashPrim, _ b: CrashPrim) -> Contact? {
        if a.sphere && b.sphere {
            let d = a.c - b.c, l = simd_length(d)
            guard l < a.r + b.r else { return nil }
            let n = l > 1e-5 ? d / l : float3(0, 0, 1)
            return Contact(n: n, depth: a.r + b.r - l, p: b.c + n * b.r)
        }
        if a.sphere { return sphereBox(a, b) }
        if b.sphere { return sphereBox(b, a).map { Contact(n: -$0.n, depth: $0.depth, p: $0.p) } }
        return boxBox(a, b)
    }

    /// Esfera s contra caja b: normal hacia la esfera.
    private static func sphereBox(_ s: CrashPrim, _ b: CrashPrim) -> Contact? {
        let q = b.closest(s.c)
        let d = s.c - q, l = simd_length(d)
        if l > 1e-5 {
            guard l < s.r else { return nil }
            return Contact(n: d / l, depth: s.r - l, p: q)
        }
        // Centro dentro de la caja: la cara más cercana
        let rel = s.c - b.c
        var best = (n: float3(0, 0, 1), depth: Float.greatestFiniteMagnitude)
        for i in 0..<3 {
            let a = b.ax[i], x = simd_dot(rel, a)
            let dep = b.e[i] - abs(x) + s.r
            if dep < best.depth { best = (x >= 0 ? a : -a, dep) }
        }
        return Contact(n: best.n, depth: best.depth, p: s.c)
    }

    /// Caja contra caja (SAT, 15 ejes). Normal hacia A.
    private static func boxBox(_ a: CrashPrim, _ b: CrashPrim) -> Contact? {
        let d = a.c - b.c
        var bestAxis = float3(0, 0, 1), bestDepth = Float.greatestFiniteMagnitude
        func test(_ axis0: float3) -> Bool {
            let l = simd_length(axis0)
            if l < 1e-4 { return true }
            let axis = axis0 / l
            let ra = a.e.x * abs(simd_dot(a.ax.columns.0, axis)) + a.e.y * abs(simd_dot(a.ax.columns.1, axis)) + a.e.z * abs(simd_dot(a.ax.columns.2, axis))
            let rb = b.e.x * abs(simd_dot(b.ax.columns.0, axis)) + b.e.y * abs(simd_dot(b.ax.columns.1, axis)) + b.e.z * abs(simd_dot(b.ax.columns.2, axis))
            let dist = simd_dot(d, axis)
            let pen = ra + rb - abs(dist)
            if pen <= 0 { return false }
            // Las aristas cruzadas solo ganan si son claramente mejores (evita normales inestables) [I]
            if pen < bestDepth * (l < 0.999 ? 0.95 : 1) { bestDepth = pen; bestAxis = dist >= 0 ? axis : -axis }
            return true
        }
        for i in 0..<3 { if !test(a.ax[i]) { return nil } }
        for i in 0..<3 { if !test(b.ax[i]) { return nil } }
        for i in 0..<3 { for j in 0..<3 { if !test(simd_cross(a.ax[i], b.ax[j])) { return nil } } }
        // Punto de contacto: media de las esquinas de una caja dentro de la otra; si no hay (arista contra arista), el punto
        // medio entre los soportes de las dos cajas en la dirección de la normal [I].
        var sum = float3(0, 0, 0), n = 0
        for p in a.corners() where b.contains(p) { sum += p; n += 1 }
        for p in b.corners() where a.contains(p) { sum += p; n += 1 }
        let p = n > 0 ? sum / Float(n) : (a.support(-bestAxis) + b.support(bestAxis)) * 0.5
        return Contact(n: bestAxis, depth: bestDepth, p: p)
    }
}
