// Colisión real de Rockport: map-data/<ID>/collision/<tx>_<ty>.bin (formato NFSC v1, tools/src/cli/collision.ts).
//   u32 'NFSC' · u32 versión (1) · u32 nTri · u32 nMuros · f32 tri[nTri×9] · f32 muro[nMuros×6] (ax, ay, bx, by, zMin, zMax)
// Coordenadas de mundo, Z arriba. Cada casilla de 400 m se indexa en celdas de 8 m para buscar el suelo rápido.
import Foundation
import simd

final class CollisionWorld {
    final class Tile {
        var tris: [Float] = []           // 9 por triángulo
        var walls: [Float] = []          // 6 por muro
        var cells: [[Int32]] = []        // índices de triángulos por celda
        let ox: Float, oy: Float
        static let cell: Float = 8
        static let n = 50                // 400 / 8
        init(ox: Float, oy: Float) { self.ox = ox; self.oy = oy }
    }

    let root: URL
    let size: Float = 400
    private var tiles: [String: Tile?] = [:]

    init(root: URL) { self.root = root.appendingPathComponent("collision") }

    var available: Bool { FileManager.default.fileExists(atPath: root.path) }

    func tile(tx: Int, ty: Int) -> Tile? {
        let key = "\(tx)_\(ty)"
        if let t = tiles[key] { return t }
        let t = load(key, tx: tx, ty: ty)
        tiles[key] = t
        return t
    }

    private func load(_ key: String, tx: Int, ty: Int) -> Tile? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("\(key).bin")), d.count >= 16 else { return nil }
        let t = Tile(ox: Float(tx) * size, oy: Float(ty) * size)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x4353464e else { return }
            let nt = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let nw = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            guard raw.count >= 16 + (nt * 9 + nw * 6) * 4 else { return }
            t.tris = (0..<(nt * 9)).map { raw.loadUnaligned(fromByteOffset: 16 + $0 * 4, as: Float.self) }
            t.walls = (0..<(nw * 6)).map { raw.loadUnaligned(fromByteOffset: 16 + (nt * 9 + $0) * 4, as: Float.self) }
        }
        let n = Tile.n
        t.cells = Array(repeating: [], count: n * n)
        for i in 0..<(t.tris.count / 9) {
            let b = i * 9
            let xs = [t.tris[b], t.tris[b + 3], t.tris[b + 6]], ys = [t.tris[b + 1], t.tris[b + 4], t.tris[b + 7]]
            let x0 = max(0, Int(((xs.min()! - t.ox) / Tile.cell).rounded(.down))), x1 = min(n - 1, Int(((xs.max()! - t.ox) / Tile.cell).rounded(.down)))
            let y0 = max(0, Int(((ys.min()! - t.oy) / Tile.cell).rounded(.down))), y1 = min(n - 1, Int(((ys.max()! - t.oy) / Tile.cell).rounded(.down)))
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 { for x in x0...x1 { t.cells[y * n + x].append(Int32(i)) } }
        }
        return t
    }

    /// Altura del suelo bajo (x, y): el triángulo más alto que no esté más de `step` m por encima de `z`.
    func ground(x: Float, y: Float, z: Float, step: Float = 2.5) -> (z: Float, normal: float3)? {
        let tx = Int((x / size).rounded(.down)), ty = Int((y / size).rounded(.down))
        guard let t = tile(tx: tx, ty: ty) else { return nil }
        let cx = Int(((x - t.ox) / Tile.cell).rounded(.down)), cy = Int(((y - t.oy) / Tile.cell).rounded(.down))
        guard cx >= 0, cy >= 0, cx < Tile.n, cy < Tile.n else { return nil }
        var best: (z: Float, normal: float3)? = nil
        for i in t.cells[cy * Tile.n + cx] {
            let b = Int(i) * 9
            let a = float3(t.tris[b], t.tris[b + 1], t.tris[b + 2])
            let p1 = float3(t.tris[b + 3], t.tris[b + 4], t.tris[b + 5])
            let p2 = float3(t.tris[b + 6], t.tris[b + 7], t.tris[b + 8])
            // Baricéntricas en planta
            let v0 = float2(p1.x - a.x, p1.y - a.y), v1 = float2(p2.x - a.x, p2.y - a.y), v2 = float2(x - a.x, y - a.y)
            let den = v0.x * v1.y - v1.x * v0.y
            if abs(den) < 1e-9 { continue }
            let u = (v2.x * v1.y - v1.x * v2.y) / den
            let v = (v0.x * v2.y - v2.x * v0.y) / den
            if u < -1e-4 || v < -1e-4 || u + v > 1 + 1e-4 { continue }
            let gz = a.z + u * (p1.z - a.z) + v * (p2.z - a.z)
            if gz > z + step { continue }
            if best == nil || gz > best!.z {
                var nrm = simd_normalize(simd_cross(p1 - a, p2 - a))
                if nrm.z < 0 { nrm = -nrm }
                best = (gz, nrm)
            }
        }
        return best
    }

    /// ¿Cruza el paso de `from` a `to` (en planta) algún muro cuya altura cubra z…z+1,5?
    func hitsWall(from: float3, to: float3) -> Bool {
        let tx = Int((to.x / size).rounded(.down)), ty = Int((to.y / size).rounded(.down))
        guard let t = tile(tx: tx, ty: ty) else { return false }
        let p = float2(from.x, from.y), r = float2(to.x - from.x, to.y - from.y)
        if simd_length_squared(r) < 1e-10 { return false }
        let w = t.walls
        var i = 0
        while i < w.count {
            defer { i += 6 }
            if w[i + 5] < from.z + 0.3 || w[i + 4] > from.z + 1.5 { continue }
            let q = float2(w[i], w[i + 1]), s = float2(w[i + 2] - w[i], w[i + 3] - w[i + 1])
            let rxs = r.x * s.y - r.y * s.x
            if abs(rxs) < 1e-9 { continue }
            let qp = q - p
            let tt = (qp.x * s.y - qp.y * s.x) / rxs
            let uu = (qp.x * r.y - qp.y * r.x) / rxs
            if tt >= 0 && tt <= 1 && uu >= 0 && uu <= 1 { return true }
        }
        return false
    }
}

// MARK: - Suelo y muros para la física del juego (Physics/PVehicle.swift)
extension CollisionWorld: PhysicsGround {
    /// Muros de las casillas que tocan el círculo (centro p, radio) en planta.
    func walls(near p: SIMD2<Float>, radius: Float) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] {
        var out: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        let tx0 = Int(((p.x - radius) / size).rounded(.down)), tx1 = Int(((p.x + radius) / size).rounded(.down))
        let ty0 = Int(((p.y - radius) / size).rounded(.down)), ty1 = Int(((p.y + radius) / size).rounded(.down))
        let r2 = radius * radius
        for ty in ty0...ty1 { for tx in tx0...tx1 {
            guard let t = tile(tx: tx, ty: ty) else { continue }
            let w = t.walls
            var i = 0
            while i + 5 < w.count {
                let a = SIMD2(w[i], w[i + 1]), b = SIMD2(w[i + 2], w[i + 3])
                // Distancia del punto al segmento en planta
                let ab = b - a, l2 = simd_length_squared(ab)
                let u = l2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
                if simd_length_squared(a + ab * u - p) <= r2 { out.append((a, b, min(w[i + 4], w[i + 5]), max(w[i + 4], w[i + 5]))) }
                i += 6
            }
        } }
        return out
    }
}
