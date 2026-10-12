// Red de carreteras del juego para la IA (tráfico y policía): map-data/<ID>/roads.json (tools/src/cli/roads.ts).
// Formato y banderas: docs/es/09-red-de-carreteras.md. Navegación como WRoadNav del juego [D: World/Common/WRoadNetwork.cpp]:
//  - Segmento = Bézier cúbica [inicio, inicio+startControl, fin+endControl, fin] si tiene la bandera "curved"; recta si no.
//  - Perfil de calzada por nodo: zonas [middleZone, numZones) = carriles "hacia delante" (de nodo 0 a nodo 1),
//    [0, middleZone) = carriles "hacia atrás"; n = 0 es el más cercano al centro. Un extremo "invertido" (StartInverted /
//    EndInverted) refleja el perfil. Con eso, el carril elegido queda SIEMPRE a la derecha del sentido de marcha a |offset|
//    metros del eje: conducción por la derecha [D: SetBoundPos, PullOver].
//  - Tráfico: solo zonas de tipo 1 (drivable_lanes[kLaneTraffic] = 2 → bit 1) [D: WRoadNetwork.h].
//  - Sentido único: solo de nodo 0 a nodo 1. NoTraffic: sin tráfico. Policía: tráfico permitido XOR CopsXorTraffic [D].
//  - En un nodo: primero la continuación que no es de decisión; si no hay, una de decisión (tramo de cruce) al azar
//    cuya salida tenga continuación válida [D: GetNextTraffic].
import Foundation
import simd

struct RoadSegFlags {
    static let decision = 1 << 0, noTraffic = 1 << 1, intersection = 1 << 3, entrance = 1 << 4
    static let copsXorTraffic = 1 << 5, oneWay = 1 << 6, curved = 1 << 8, endInverted = 1 << 9, startInverted = 1 << 10
}

final class RoadNet {
    struct Lane: Decodable { let type: Int; let width: Float; let offset: Float }
    struct Profile: Decodable { let numZones: Int; let middleZone: Int; let lanes: [Lane] }
    private struct NodeJ: Decodable { let p: [Float]; let profile: Int; let segments: [Int] }
    private struct SegJ: Decodable { let nodes: [Int]; let length: Float; let flags: Int; let startControl: [Float]; let endControl: [Float] }
    private struct File: Decodable { let nodes: [NodeJ]; let segments: [SegJ]; let profiles: [Profile] }

    struct Seg {
        let n0: Int, n1: Int, flags: Int
        let p0: float3, p1: float3, p2: float3, p3: float3
        let curved: Bool
        var length: Float = 0
        var lut: [Float] = []   // longitud acumulada en LUTN+1 puntos (t = i/LUTN)
        func has(_ f: Int) -> Bool { flags & f != 0 }
    }

    static let lutN = 16
    let nodePos: [float3]
    let nodeProfile: [Int]
    let nodeSegs: [[Int]]
    let profiles: [Profile]
    private(set) var segs: [Seg] = []
    // Rejilla espacial (celdas de 50 m) → segmentos que pasan por la celda
    private let cell: Float = 50
    private var grid: [Int64: [Int32]] = [:]

    init(url: URL) throws {
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        nodePos = f.nodes.map { float3($0.p[0], $0.p[1], $0.p[2]) }
        nodeProfile = f.nodes.map { $0.profile }
        nodeSegs = f.nodes.map { $0.segments }
        profiles = f.profiles
        segs = f.segments.map { s in
            let a = nodePos[s.nodes[0]], b = nodePos[s.nodes[1]]
            let sc = float3(s.startControl[0], s.startControl[1], s.startControl[2]), ec = float3(s.endControl[0], s.endControl[1], s.endControl[2])
            return Seg(n0: s.nodes[0], n1: s.nodes[1], flags: s.flags, p0: a, p1: a + sc, p2: b + ec, p3: b, curved: s.flags & RoadSegFlags.curved != 0)
        }
        for i in segs.indices {
            var lut = [Float](repeating: 0, count: RoadNet.lutN + 1)
            var prev = point(i, 0), acc: Float = 0
            for k in 1...RoadNet.lutN { let p = point(i, Float(k) / Float(RoadNet.lutN)); acc += simd_distance(p, prev); lut[k] = acc; prev = p }
            segs[i].lut = lut
            segs[i].length = max(acc, 0.01)
            // Rejilla: un punto cada ~10 m
            let n = max(2, Int(acc / 10) + 1)
            var seen = Set<Int64>()
            for k in 0...n {
                let p = point(i, Float(k) / Float(n))
                for dx in [-6, 6] as [Float] { for dy in [-6, 6] as [Float] {
                    let key = cellKey(p.x + dx, p.y + dy)
                    if seen.insert(key).inserted { grid[key, default: []].append(Int32(i)) }
                } }
            }
        }
    }

    private func cellKey(_ x: Float, _ y: Float) -> Int64 {
        Int64(Int32((x / cell).rounded(.down))) << 32 | Int64(UInt32(bitPattern: Int32((y / cell).rounded(.down))))
    }

    var count: Int { segs.count }

    // MARK: Geometría
    func point(_ i: Int, _ t: Float) -> float3 {
        let s = segs[i]
        if !s.curved { return s.p0 + (s.p3 - s.p0) * t }
        let u = 1 - t
        return s.p0 * (u * u * u) + s.p1 * (3 * u * u * t) + s.p2 * (3 * u * t * t) + s.p3 * (t * t * t)
    }

    func tangent(_ i: Int, _ t: Float) -> float3 {
        let s = segs[i]
        var d: float3
        if !s.curved { d = s.p3 - s.p0 } else {
            let u = 1 - t
            d = (s.p1 - s.p0) * (3 * u * u) + (s.p2 - s.p1) * (6 * u * t) + (s.p3 - s.p2) * (3 * t * t)
            if simd_length_squared(d) < 1e-8 { d = s.p3 - s.p0 }
        }
        let l = simd_length(d)
        return l > 1e-6 ? d / l : float3(1, 0, 0)
    }

    /// t (0…1) para una distancia en metros desde el nodo 0, con la tabla de longitudes.
    func t(_ i: Int, atDistance d: Float) -> Float {
        let lut = segs[i].lut
        if d <= 0 { return 0 }
        if d >= lut[RoadNet.lutN] { return 1 }
        var lo = 0, hi = RoadNet.lutN
        while hi - lo > 1 { let m = (lo + hi) / 2; if lut[m] <= d { lo = m } else { hi = m } }
        let f = (d - lut[lo]) / max(lut[hi] - lut[lo], 1e-5)
        return (Float(lo) + f) / Float(RoadNet.lutN)
    }

    func distance(_ i: Int, atT t: Float) -> Float {
        let x = max(0, min(1, t)) * Float(RoadNet.lutN), k = min(Int(x), RoadNet.lutN - 1)
        let lut = segs[i].lut
        return lut[k] + (lut[k + 1] - lut[k]) * (x - Float(k))
    }

    // MARK: Reglas
    /// Tramos que atraviesan un muro de colisión (vallas de la historia, BARRIER_LOCKED: en el juego se marcan al cargar
    /// con CrossesBarrier según las barreras activas [D: TrackPathBarrier]). Se calcula al primer uso con `wallTest`.
    var wallTest: ((float3, float3) -> Bool)?
    private var blockedCache: [Int8] = []
    func blocked(_ i: Int) -> Bool {
        if blockedCache.isEmpty { blockedCache = [Int8](repeating: -1, count: segs.count) }
        if blockedCache[i] >= 0 { return blockedCache[i] == 1 }
        var b = false
        if let test = wallTest {
            let n = max(2, Int(segs[i].length / 4))
            var prev = point(i, 0)
            for k in 1...n {
                let q = point(i, Float(k) / Float(n))
                if test(prev + float3(0, 0, 0.5), q + float3(0, 0, 0.5)) { b = true; break }
                prev = q
            }
        }
        blockedCache[i] = b ? 1 : 0
        return b
    }
    func trafficAllowed(_ i: Int) -> Bool { !segs[i].has(RoadSegFlags.noTraffic) && !blocked(i) }
    func copsAllowed(_ i: Int) -> Bool { !blocked(i) && (!segs[i].has(RoadSegFlags.noTraffic) != segs[i].has(RoadSegFlags.copsXorTraffic)) }
    func allowed(_ i: Int, cops: Bool) -> Bool { cops ? copsAllowed(i) : trafficAllowed(i) }

    /// Desplazamientos (m, positivos = a la derecha del sentido de marcha) de los carriles de tráfico en el extremo `end`
    /// (0 = nodo 0, 1 = nodo 1) para quien circula en `forward` (de nodo 0 a 1). Ordenados del centro hacia el bordillo.
    func laneOffsets(_ i: Int, forward: Bool, end: Int, types: Set<Int> = [1]) -> [Float] {
        let s = segs[i]
        let node = end == 0 ? s.n0 : s.n1
        let pi = nodeProfile[node]
        guard pi >= 0, pi < profiles.count else { return [] }
        let p = profiles[pi]
        let inverted = s.has(end == 0 ? RoadSegFlags.startInverted : RoadSegFlags.endInverted)
        let effForward = forward != inverted
        let n = min(p.numZones, p.lanes.count), mid = min(p.middleZone, n)
        let zones: [Int] = effForward ? Array(mid..<n) : Array((0..<mid).reversed())
        return zones.filter { types.contains(p.lanes[$0].type) }.map { abs(p.lanes[$0].offset) }
    }

    /// Bordes de la calzada (tipos de tráfico, mediana y carreras) en el extremo `end`, en metros a la derecha del sentido
    /// nodo 0 → 1: (izquierda, derecha).
    func roadExtents(_ i: Int, end: Int) -> (Float, Float)? {
        let s = segs[i]
        let pi = nodeProfile[end == 0 ? s.n0 : s.n1]
        guard pi >= 0, pi < profiles.count else { return nil }
        let p = profiles[pi]
        let inv: Float = s.has(end == 0 ? RoadSegFlags.startInverted : RoadSegFlags.endInverted) ? -1 : 1
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        let n = min(p.numZones, p.lanes.count)
        for k in 0..<n where [1, 4, 10].contains(p.lanes[k].type) {
            let l = p.lanes[k]
            let c = (k >= p.middleZone ? abs(l.offset) : -abs(l.offset)) * inv
            lo = min(lo, c - abs(l.width) / 2); hi = max(hi, c + abs(l.width) / 2)
        }
        return lo < hi ? (lo, hi) : nil
    }

    /// ¿Se puede entrar en `i` desde el nodo `from` (sentido único, permisos y carriles)?
    func canEnter(_ i: Int, from node: Int, cops: Bool) -> Bool {
        let s = segs[i]
        guard allowed(i, cops: cops) else { return false }
        let forward = s.n0 == node
        if s.has(RoadSegFlags.oneWay) && !forward { return false }
        return !laneOffsets(i, forward: forward, end: forward ? 0 : 1).isEmpty
    }

    func otherNode(_ i: Int, _ node: Int) -> Int { segs[i].n0 == node ? segs[i].n1 : segs[i].n0 }

    /// Siguiente segmento al llegar a `node` por `cur` [D: GetNextTraffic]. Con `field` (distancias por la red hasta el
    /// objetivo, ver `distanceField`), elige el que más acerca (persecución); sin él, al azar entre los tramos de cruce.
    /// nil = callejón sin salida.
    func next(from cur: Int, at node: Int, cops: Bool, field: [Float]? = nil, rng: inout SplitMix) -> Int? {
        let cands = nodeSegs[node].filter { $0 != cur && $0 < segs.count && canEnter($0, from: node, cops: cops) }
        if cands.isEmpty { return nil }
        if let field {
            return cands.min { segs[$0].length + field[otherNode($0, node)] < segs[$1].length + field[otherNode($1, node)] }
        }
        let straight = cands.filter { !segs[$0].has(RoadSegFlags.decision) }
        if let s = straight.first { return s }
        let decisions = cands.filter { c in
            let far = otherNode(c, node)
            return nodeSegs[far].contains { $0 != c && !segs[$0].has(RoadSegFlags.decision) && canEnter($0, from: far, cops: cops) }
        }
        let pool = decisions.isEmpty ? cands : decisions
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    /// Dijkstra inverso: distancia (m) por la red desde cada nodo hasta `target`, respetando sentidos únicos y permisos.
    func distanceField(to target: Int, cops: Bool) -> [Float] {
        var dist = [Float](repeating: .greatestFiniteMagnitude, count: nodePos.count)
        guard target >= 0, target < dist.count else { return dist }
        dist[target] = 0
        var heap: [(Float, Int)] = [(0, target)]
        func push(_ e: (Float, Int)) {
            heap.append(e); var i = heap.count - 1
            while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p }
        }
        func pop() -> (Float, Int) {
            let top = heap[0]; let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last; var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1; var m = i
                    if l < heap.count && heap[l].0 < heap[m].0 { m = l }
                    if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                    if m == i { break }; heap.swapAt(m, i); i = m
                }
            }
            return top
        }
        while !heap.isEmpty {
            let (d, v) = pop()
            if d > dist[v] { continue }
            for sgi in nodeSegs[v] where sgi < segs.count {
                let u = otherNode(sgi, v)
                guard allowed(sgi, cops: cops) else { continue }
                if segs[sgi].has(RoadSegFlags.oneWay) && segs[sgi].n0 != u { continue }
                let nd = d + segs[sgi].length
                if nd < dist[u] { dist[u] = nd; push((nd, u)) }
            }
        }
        return dist
    }

    /// Segmento más cercano a `p` (en planta, con la altura como desempate) dentro de `maxDist` m.
    func nearest(_ p: float3, maxDist: Float = 60, filter: (Int) -> Bool = { _ in true }) -> (seg: Int, t: Float, dist: Float)? {
        var best: (Int, Float, Float)? = nil
        var tested = Set<Int32>()
        let r = Int((maxDist / cell).rounded(.up))
        let cx = Int((p.x / cell).rounded(.down)), cy = Int((p.y / cell).rounded(.down))
        for dx in -r...r { for dy in -r...r {
            let key = Int64(Int32(cx + dx)) << 32 | Int64(UInt32(bitPattern: Int32(cy + dy)))
            guard let list = grid[key] else { continue }
            for s32 in list where tested.insert(s32).inserted {
                let s = Int(s32)
                guard filter(s) else { continue }
                var bt: Float = 0, bd: Float = .greatestFiniteMagnitude
                for k in 0...RoadNet.lutN {
                    let t = Float(k) / Float(RoadNet.lutN), q = point(s, t)
                    let d = simd_length(float2(q.x - p.x, q.y - p.y)) + abs(q.z - p.z) * 0.5
                    if d < bd { bd = d; bt = t }
                }
                // refinado
                var step: Float = 1 / Float(RoadNet.lutN)
                for _ in 0..<5 {
                    step *= 0.5
                    for t in [bt - step, bt + step] where t >= 0 && t <= 1 {
                        let q = point(s, t)
                        let d = simd_length(float2(q.x - p.x, q.y - p.y)) + abs(q.z - p.z) * 0.5
                        if d < bd { bd = d; bt = t }
                    }
                }
                if bd < maxDist && (best == nil || bd < best!.2) { best = (s, bt, bd) }
            }
        } }
        return best.map { (seg: $0.0, t: $0.1, dist: $0.2) }
    }
}

/// Generador pseudoaleatorio pequeño y determinista (las pruebas sin ventana dan siempre lo mismo).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * float() }
}
