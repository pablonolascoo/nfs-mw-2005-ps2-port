// Ruta de una carrera sobre la red de carreteras del juego, cerrada por las vallas activas de la prueba.
//
// En el juego, los corredores de la IA navegan con WRoadNav en modo kLaneRacing y «race filter»: buscan camino
// (FindPath) hacia el siguiente punto de control y no pueden cruzar las vallas activas de TrackPath (TrackPathBarrier,
// EnableBarriers(grupo)) [D: AIVehicleRacecar::StartRace, AIActionRace::Update, World/TrackPath.cpp]. Aquí se hace lo
// mismo de una vez al empezar: tramo a tramo (salida → punto 1 → … → meta, y la vuelta para los circuitos) se busca el
// camino más corto por la red (Dijkstra) sin pasar por segmentos que crucen una valla activa, y se respeta el sentido de
// paso de cada punto de control (rumbo del marcador). El resultado es una polilínea con distancia acumulada: sirve para
// la IA (línea a seguir), para la posición de cada corredor (progreso), para el sentido contrario y para el minimapa.
import Foundation
import simd

/// Vallas activas (líneas 2D de TrackPathBarrier) con una rejilla para cruzarlas rápido.
final class RaceBarrierLines {
    struct Line { let a: float2; let b: float2; let group: String; let driveThrough: Bool }
    private(set) var lines: [Line] = []
    private var grid: [Int64: [Int32]] = [:]
    private let cell: Float = 64

    init(groups: [(name: String, group: RaceBarrierGroup)]) {
        for (name, g) in groups {
            for l in g.lines where l.count >= 4 {
                lines.append(Line(a: float2(l[0], l[1]), b: float2(l[2], l[3]), group: name, driveThrough: g.driveThrough))
            }
        }
        for (i, l) in lines.enumerated() {
            let x0 = Int((min(l.a.x, l.b.x) / cell).rounded(.down)), x1 = Int((max(l.a.x, l.b.x) / cell).rounded(.down))
            let y0 = Int((min(l.a.y, l.b.y) / cell).rounded(.down)), y1 = Int((max(l.a.y, l.b.y) / cell).rounded(.down))
            for x in x0...x1 { for y in y0...y1 { grid[key(x, y), default: []].append(Int32(i)) } }
        }
    }

    private func key(_ x: Int, _ y: Int) -> Int64 { Int64(Int32(x)) << 32 | Int64(UInt32(bitPattern: Int32(y))) }

    /// DoLinesIntersect del juego [D: TrackPath.cpp]: ¿cruza el paso a→b alguna valla?
    func crosses(_ a: float2, _ b: float2) -> Bool {
        let x0 = Int((min(a.x, b.x) / cell).rounded(.down)), x1 = Int((max(a.x, b.x) / cell).rounded(.down))
        let y0 = Int((min(a.y, b.y) / cell).rounded(.down)), y1 = Int((max(a.y, b.y) / cell).rounded(.down))
        for x in x0...x1 { for y in y0...y1 {
            guard let list = grid[key(x, y)] else { continue }
            for i in list where RaceBarrierLines.intersect(lines[Int(i)].a, lines[Int(i)].b, a, b) { return true }
        } }
        return false
    }

    static func intersect(_ a: float2, _ b: float2, _ c: float2, _ d: float2) -> Bool {
        let den = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
        if den == 0 { return false }
        let r = ((a.y - c.y) * (d.x - c.x) - (a.x - c.x) * (d.y - c.y)) / den
        if !(0...1).contains(r) { return false }
        let s = ((a.y - c.y) * (b.x - a.x) - (a.x - c.x) * (b.y - a.y)) / den
        return (0...1).contains(s)
    }

    var count: Int { lines.count }
}

/// Polilínea de la carrera con distancia acumulada y anchura de calzada a cada lado.
final class RaceRoute {
    struct Point {
        var p: float3
        var dist: Float            // metros desde la salida
        var tangent: float3        // sentido de la marcha (planta)
        var left: Float            // calzada utilizable a la izquierda del eje (m)
        var right: Float           // … y a la derecha
    }
    private(set) var points: [Point] = []
    /// Distancia en la ruta de cada puerta (punto de control o meta), en orden de paso. Para circuitos, todas las vueltas.
    private(set) var gateDistances: [Float] = []
    /// Longitud de una vuelta (circuitos) o de toda la prueba.
    private(set) var lapLength: Float = 0
    private(set) var firstLapLength: Float = 0
    /// Tramos que no encontraron camino por la red (se unen en línea recta) — `GetRaceRouteError` del juego [D].
    private(set) var legErrors = 0
    var length: Float { points.last?.dist ?? 0 }

    static let step: Float = 4

    // MARK: Construcción

    /// Pieza de ruta por la red: segmento, sentido, tramo [d0, d1] en metros medidos en el sentido de marcha.
    private struct Piece { let seg: Int; let forward: Bool; let d0: Float; let d1: Float }

    init(net: RoadNet, barriers: RaceBarrierLines, start: RaceMarker, gates: [RaceMarker], laps: Int, loopGates: [RaceMarker]? = nil) {
        var blockCache: [Int: Bool] = [:]
        func segBlocked(_ i: Int) -> Bool {
            if let b = blockCache[i] { return b }
            let n = max(2, Int(net.segs[i].length / 3))
            var prev = net.point(i, 0), hit = false
            for k in 1...n {
                let q = net.point(i, Float(k) / Float(n))
                if barriers.crosses(float2(prev.x, prev.y), float2(q.x, q.y)) { hit = true; break }
                prev = q
            }
            blockCache[i] = hit
            return hit
        }
        func usable(_ i: Int) -> Bool {
            // Carriles para conducir (tráfico 1, carreras 10, otros 4) [D: drivable_lanes] y sin valla activa
            net.roadExtents(i, end: 0) != nil && !segBlocked(i)
        }
        // Punto de la red para un marcador: segmento más cercano (planta + altura), con su sentido según el rumbo.
        func anchor(_ m: RaceMarker) -> (seg: Int, d: Float, forward: Bool)? {
            guard let h = net.nearest(m.p, maxDist: 45, filter: usable) ?? net.nearest(m.p, maxDist: 45) else { return nil }
            let tan = net.tangent(h.seg, h.t)
            let fwd = simd_dot(float2(tan.x, tan.y), float2(m.dir.x, m.dir.y)) >= 0
            let d = net.distance(h.seg, atT: h.t)
            return (h.seg, fwd ? d : net.segs[h.seg].length - d, fwd)
        }
        // Dijkstra de nodos desde `fromNode` (coste inicial) hasta la entrada del segmento objetivo.
        func path(fromNode: Int, toNode: Int, avoidSeg: Int) -> (segs: [Int], cost: Float)? {
            if fromNode == toNode { return ([], 0) }
            var dist = [Float](repeating: .greatestFiniteMagnitude, count: net.nodePos.count)
            var prevSeg = [Int](repeating: -1, count: net.nodePos.count)
            dist[fromNode] = 0
            var heap: [(Float, Int)] = [(0, fromNode)]
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
            var settled = 0
            while !heap.isEmpty {
                let (d, v) = pop()
                if d > dist[v] { continue }
                if v == toNode { break }
                settled += 1
                if settled > 60000 { break }
                for s in net.nodeSegs[v] where s < net.count && s != avoidSeg && usable(s) {
                    let u = net.otherNode(s, v)
                    // U-turn penalty: none; length cost
                    let nd = d + net.segs[s].length
                    if nd < dist[u] { dist[u] = nd; prevSeg[u] = s; push((nd, u)) }
                }
            }
            guard dist[toNode] < .greatestFiniteMagnitude else { return nil }
            var segs: [Int] = []
            var v = toNode
            var guardN = 0
            while v != fromNode && guardN < 100000 { let s = prevSeg[v]; if s < 0 { return nil }; segs.append(s); v = net.otherNode(s, v); guardN += 1 }
            return (segs.reversed(), dist[toNode])
        }

        var out: [Point] = []
        func emit(_ p: float3, _ left: Float, _ right: Float) {
            if let last = out.last {
                let d = simd_distance(float2(p.x, p.y), float2(last.p.x, last.p.y))
                if d < 0.5 { return }
                out.append(Point(p: p, dist: last.dist + d, tangent: .zero, left: left, right: right))
            } else { out.append(Point(p: p, dist: 0, tangent: .zero, left: left, right: right)) }
        }
        // Línea de carrera: el centro de los carriles del sentido de la marcha (tráfico 1, carreras 10, otros 4), no el eje
        // de la red: en las avenidas con mediana el eje pasa por encima de los muros de la mediana [V: colisión de STREAML2RA].
        func laneCenter(_ seg: Int, _ forward: Bool, _ u: Float) -> Float {
            let types: Set<Int> = [1, 4, 10]
            let a = net.laneOffsets(seg, forward: forward, end: forward ? 0 : 1, types: types)
            let b = net.laneOffsets(seg, forward: forward, end: forward ? 1 : 0, types: types)
            func mid(_ l: [Float]) -> Float? { l.isEmpty ? nil : (l.min()! + l.max()!) * 0.5 }
            let ca = mid(a) ?? mid(b) ?? 0, cb = mid(b) ?? ca
            return ca + (cb - ca) * u
        }
        func extents(_ seg: Int, _ forward: Bool, _ t: Float, center c: Float) -> (Float, Float) {
            let a = net.roadExtents(seg, end: 0) ?? (-6, 6), b = net.roadExtents(seg, end: 1) ?? a
            let lo = a.0 + (b.0 - a.0) * t, hi = a.1 + (b.1 - a.1) * t
            // roadExtents: metros a la DERECHA del sentido nodo 0 → 1 → al sentido de la marcha
            let (loT, hiT) = forward ? (lo, hi) : (-hi, -lo)
            return (max(1.5, c - loT), max(1.5, hiT - c))
        }
        func emitPiece(_ pc: Piece) {
            let L = net.segs[pc.seg].length
            let len = pc.d1 - pc.d0
            let n = max(1, Int(ceil(abs(len) / RaceRoute.step)))
            for k in 0...n {
                let d = pc.d0 + len * Float(k) / Float(n)
                let along = pc.forward ? d : L - d
                let t = net.t(pc.seg, atDistance: along)
                let c = laneCenter(pc.seg, pc.forward, max(0, min(1, d / max(L, 0.01))))
                var tan = net.tangent(pc.seg, t); if !pc.forward { tan = -tan }
                let right = simd_normalize(float3(tan.y, -tan.x, 0) + 1e-9)
                let (l, r) = extents(pc.seg, pc.forward, t, center: c)
                emit(net.point(pc.seg, t) + right * c, l, r)
            }
        }
        func straight(_ a: float3, _ b: float3) {
            let n = max(1, Int(simd_distance(a, b) / RaceRoute.step))
            for k in 0...n { emit(a + (b - a) * Float(k) / Float(n), 8, 8) }
        }

        // Estado: punto de partida en la red
        var cur = anchor(start)
        var curPoint = start.p
        if cur == nil { legErrors += 1 }
        var gateIdx: [Int] = []

        func leg(to g: RaceMarker) {
            guard let c = cur, let a0 = anchor(g) else {
                straight(out.last?.p ?? curPoint, g.p)
                legErrors += 1
                cur = anchor(g); curPoint = g.p
                gateIdx.append(max(0, out.count - 1))
                return
            }
            // Los dos sentidos posibles por el segmento de la puerta: el más corto, penalizando el que va contra el rumbo
            // del marcador (evita bucles cuando la puerta cae en un tramo de cruce corto) [I]
            let L = net.segs[a0.seg].length
            let tAlong = a0.forward ? a0.d : L - a0.d          // metros desde el nodo 0
            var best: (goal: (seg: Int, d: Float, forward: Bool), path: [Int]?, cost: Float)? = nil
            for fwd in [a0.forward, !a0.forward] {
                let goal = (seg: a0.seg, d: fwd ? tAlong : L - tAlong, forward: fwd)
                var tan = net.tangent(a0.seg, net.t(a0.seg, atDistance: tAlong)); if !fwd { tan = -tan }
                let penalty: Float = simd_dot(float2(tan.x, tan.y), float2(g.dir.x, g.dir.y)) < -0.3 ? 250 : 0
                if c.seg == goal.seg && c.forward == goal.forward && goal.d >= c.d - 1 {
                    let cost = goal.d - c.d + penalty
                    if best == nil || cost < best!.cost { best = (goal, nil, cost) }
                    continue
                }
                let s = net.segs[c.seg]
                let exitNode = c.forward ? s.n1 : s.n0
                let gs = net.segs[goal.seg]
                let entryNode = goal.forward ? gs.n0 : gs.n1
                if let p = path(fromNode: exitNode, toNode: entryNode, avoidSeg: -1) {
                    let cost = (s.length - c.d) + p.cost + goal.d + penalty
                    if best == nil || cost < best!.cost { best = (goal, p.segs, cost) }
                }
            }
            guard let b = best else {
                legErrors += 1
                straight(out.last?.p ?? curPoint, g.p)
                cur = a0; curPoint = g.p
                gateIdx.append(max(0, out.count - 1))
                return
            }
            if let p = b.path {
                let s = net.segs[c.seg]
                let exitNode = c.forward ? s.n1 : s.n0
                emitPiece(Piece(seg: c.seg, forward: c.forward, d0: c.d, d1: s.length))
                var node = exitNode
                for sg in p {
                    let fwd = net.segs[sg].n0 == node
                    emitPiece(Piece(seg: sg, forward: fwd, d0: 0, d1: net.segs[sg].length))
                    node = net.otherNode(sg, node)
                }
                emitPiece(Piece(seg: b.goal.seg, forward: b.goal.forward, d0: 0, d1: b.goal.d))
            } else {
                emitPiece(Piece(seg: c.seg, forward: c.forward, d0: c.d, d1: b.goal.d))
            }
            gateIdx.append(max(0, out.count - 1))
            cur = b.goal; curPoint = g.p
        }

        for g in gates { leg(to: g) }
        let firstLapGates = gateIdx.count
        let loop = loopGates ?? gates
        if laps > 1 { for _ in 1..<laps { for g in loop { leg(to: g) } } }

        // Quitar bucles pequeños (vuelta sobre sí misma en < 80 m) y recalcular distancias [I]
        var keep = [Bool](repeating: true, count: out.count)
        var i = 0
        while i < out.count {
            var cut = -1
            for j in stride(from: min(out.count - 1, i + 25), to: i + 4, by: -1) where simd_distance(out[i].p, out[j].p) < 4 { cut = j; break }
            if cut > 0 { for k in (i + 1)..<cut { keep[k] = false }; i = cut } else { i += 1 }
        }
        var remap = [Int](repeating: 0, count: out.count)
        var kept: [Point] = []
        for k in out.indices { if keep[k] { kept.append(out[k]) }; remap[k] = max(0, kept.count - 1) }
        for k in kept.indices { kept[k].dist = k == 0 ? 0 : kept[k - 1].dist + simd_distance(float2(kept[k].p.x, kept[k].p.y), float2(kept[k - 1].p.x, kept[k - 1].p.y)) }
        out = kept
        let gatesD = gateIdx.map { out[min(remap[$0], out.count - 1)].dist }
        firstLapLength = firstLapGates > 0 ? gatesD[firstLapGates - 1] : (out.last?.dist ?? 0)
        lapLength = laps > 1 ? ((out.last?.dist ?? 0) - firstLapLength) / Float(laps - 1) : firstLapLength
        gateDistances = gatesD
        // Tangentes
        for i in out.indices {
            let a = out[max(0, i - 2)].p, b = out[min(out.count - 1, i + 2)].p
            var t = float3(b.x - a.x, b.y - a.y, 0)
            if simd_length(t) < 1e-3 { t = float3(1, 0, 0) }
            out[i].tangent = simd_normalize(t)
        }
        points = out
    }

    // MARK: Consultas

    /// Índice del punto de ruta para una distancia (búsqueda binaria).
    func index(at d: Float) -> Int {
        var lo = 0, hi = points.count - 1
        if hi <= 0 { return 0 }
        while hi - lo > 1 { let m = (lo + hi) / 2; if points[m].dist <= d { lo = m } else { hi = m } }
        return lo
    }

    /// Punto interpolado a la distancia `d`.
    func sample(_ d: Float) -> Point {
        guard points.count > 1 else { return points.first ?? Point(p: .zero, dist: 0, tangent: float3(1, 0, 0), left: 6, right: 6) }
        let dd = max(0, min(length, d))
        let i = index(at: dd), j = min(points.count - 1, i + 1)
        let a = points[i], b = points[j]
        let f = b.dist > a.dist ? (dd - a.dist) / (b.dist - a.dist) : 0
        return Point(p: a.p + (b.p - a.p) * f, dist: dd, tangent: simd_normalize(a.tangent + (b.tangent - a.tangent) * f + 1e-6),
                     left: a.left + (b.left - a.left) * f, right: a.right + (b.right - a.right) * f)
    }

    /// Proyección de `p` sobre la ruta buscando cerca de la última distancia conocida (`hint`).
    /// Devuelve la distancia a lo largo de la ruta y la separación lateral (m, + = derecha).
    func project(_ p: float3, hint: Float, back: Float = 60, ahead: Float = 160) -> (dist: Float, lateral: Float, gap: Float) {
        guard points.count > 1 else { return (0, 0, 0) }
        let i0 = index(at: max(0, hint - back)), i1 = index(at: min(length, hint + ahead))
        var best = (dist: hint, lateral: Float(0), gap: Float.greatestFiniteMagnitude)
        for i in i0..<max(i0 + 1, min(i1 + 1, points.count - 1)) {
            let a = points[i], b = points[i + 1]
            let ab = float2(b.p.x - a.p.x, b.p.y - a.p.y)
            let l2 = simd_length_squared(ab)
            let ap = float2(p.x - a.p.x, p.y - a.p.y)
            let u = l2 > 0 ? max(0, min(1, simd_dot(ap, ab) / l2)) : 0
            let q = a.p + (b.p - a.p) * u
            let g = simd_length(float2(p.x - q.x, p.y - q.y)) + abs(p.z - q.z) * 0.5
            if g < best.gap {
                let t = a.tangent
                let right = float2(t.y, -t.x)
                best = (a.dist + (b.dist - a.dist) * u, simd_dot(float2(p.x - q.x, p.y - q.y), right), g)
            }
        }
        return best
    }

    /// Búsqueda global (al colocar o tras un reinicio): punto más cercano de toda la ruta.
    func projectGlobal(_ p: float3) -> (dist: Float, lateral: Float, gap: Float) {
        project(p, hint: length / 2, back: length, ahead: length)
    }

    /// Curvatura media (rad/m) entre `d` y `d + span` (CookieTrailCurvature del juego [D], sobre la ruta).
    func curvature(at d: Float, span: Float) -> Float {
        let a = sample(d).tangent, b = sample(d + max(span, 4)).tangent
        let c = max(-1, min(1, simd_dot(float2(a.x, a.y), float2(b.x, b.y))))
        return acos(c) / max(span, 4)
    }

    /// Puntos para el minimapa (uno cada ~40 m).
    func minimapPoints() -> [float3] {
        var out: [float3] = []
        var next: Float = 0
        for p in points where p.dist >= next { out.append(p.p); next = p.dist + 40 }
        if let l = points.last { out.append(l.p) }
        return out
    }
}
