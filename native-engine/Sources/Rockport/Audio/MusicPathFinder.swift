// Reproductor PathFinder 5 (una «pista» = un proyecto .MPF): recorre el grafo de nodos con la intensidad que manda el juego
// y ejecuta los eventos (doc 25 §3). Lo que no está en la decomp (las funciones PATH_* solo existen en ensamblador) se
// deduce de los datos y va marcado:
//   · Ramas: al acabar una onda se sigue la rama con mín < control ≤ máx [V: tramos de los datos]; si ninguna cumple, la más
//     cercana [H]. Los nodos de fin con byte 3 = 0xF8 repiten (rama {1,127}) [H]. Nodos mudos (0) se atraviesan; −3 lanza su evento cuando la música llega ahí; −1 termina (o sigue su rama).
//   · Eventos: 4/15 vaciar la cola y cortar · 4/3 ir al nodo (sin vaciar: al acabar la onda actual) · 13/15 llamada al juego
//     · 5/12 fundido (p0 = 0x100 | volumen 0–127, p1 = ms) · 2/12 esperar p0 ms · 8/13 volumen · 8/6 variable = valor
//     · 9/0 lanzar el evento (p1 << 16 | p0) · 1/x condiciones: 0x9_ «si ==», 0x11_ «si ≠», 0xA_ «si no, si ==»,
//     0x12_ «si no, si ≠», 0x40 cierra; _E = variable del proyecto, _D = variable del sistema (3 = parte actual,
//     4 = 1 si suena algo) [H: cuadra con todos los eventos de los 5 proyectos].
//   · Routers: si se pide ir a un destino y la onda actual tiene un router (b4 − 1) con un par (paso, destino), antes se toca
//     la onda de paso: así cada final de persecución suena con el remate que encaja con la capa que sonaba [I: los pares de
//     cada router apuntan a ondas WIN_END/LOSE_END/ELUDE_END y a los dos nodos de pausa final].
import Foundation

protocol MusicTrackDelegate: AnyObject {
    /// EventActionCallback(id, parámetro) [D]: 1 = fin de canción, 2 = InteractiveDone, 3 = Swap.
    func musicCallback(_ track: MusicTrack, id: Int, param: Int)
    /// SongProgressCallback(nodo de la parte) [D].
    func musicPart(_ track: MusicTrack, partNode: Int)
}

final class MusicTrack {
    let project: MusicProject
    let channel: MusicChannel
    weak var delegate: MusicTrackDelegate?
    /// Intensidad 0–127 (PATH_control). En MW_MUSIC el juego no la manda y vale 0 [I: con más de 63/70 las cabeceras de
    /// «Feels Just Like It Should» y «Feed The Addiction» saltarían la canción].
    var control = 0
    private(set) var vars: [Int]
    private(set) var partNode = 0
    /// Volumen del proyecto 0–127 (acciones 8/13 y 5/12).
    private(set) var volume: Float = 127
    private var nextID = 1
    /// Nodo a partir del cual se decide lo siguiente (la última onda encolada) o nodo por el que empezar.
    private var cursor: Int?
    private var startAt: Int?
    private var pendingGoto: Int?
    private var playingNode: Int?
    private var programs: [(actions: [[Int]], pc: Int, conds: [Cond], resume: Double, name: String)] = []
    private var clock: Double = 0
    private var decodeCache: [Int: MusicPCM] = [:]
    private var cacheOrder: [Int] = []
    private(set) var stopped = true
    /// Registro de lo que pasa (pruebas: --music-test).
    var trace: ((String) -> Void)?
    /// Segundos por delante a los que se encola la siguiente onda.
    var lookahead = 0.6

    private struct Cond { var active: Bool; var taken: Bool; var parentActive: Bool }

    init(project: MusicProject, channel: MusicChannel) {
        self.project = project; self.channel = channel
        vars = project.vars.map(\.value) + [Int](repeating: 0, count: max(0, 8 - project.vars.count))
    }

    var isPlaying: Bool { !stopped }

    func setVar(named n: String, _ v: Int) { if let i = project.vars.firstIndex(where: { $0.name == n }) { vars[i] = v } }

    // MARK: Eventos

    /// PATH_event: ejecuta el evento (24 bits bajos del id). false si el proyecto no lo tiene.
    @discardableResult
    func event(_ id: Int) -> Bool {
        guard let e = project.event(id: id) else { trace?("\(project.name): evento 0x\(String(id & 0xFFFFFF, radix: 16)) no existe"); return false }
        trace?("\(project.name): evento \(e.name.isEmpty ? "0x" + String(e.id, radix: 16) : e.name)")
        run(e.actions, pc: 0, conds: [], name: e.name)
        return true
    }

    /// Para todo (PATH_stop).
    func stop(fadeMs: Double = 25) {
        channel.stop(fadeMs: fadeMs)
        programs.removeAll()
        cursor = nil; cursorIsMarker = false; startAt = nil; pendingGoto = nil; playingNode = nil
        stopped = true
    }

    private func run(_ actions: [[Int]], pc start: Int, conds c0: [Cond], name: String) {
        var conds = c0
        var pc = start
        var active: Bool { conds.last?.active ?? true }
        while pc < actions.count {
            let a = actions[pc]; pc += 1
            guard a.count >= 4 else { continue }
            let type = a[0], code = a[1], p0 = a[2], p1 = a[3]
            if type == 1 {
                if code == 0x40 { if !conds.isEmpty { conds.removeLast() }; continue }
                let op = code >> 4, sys = code & 0xF == 0xD
                let v = sys ? sysVar(p0) : (p0 < vars.count ? vars[p0] : 0)
                let eq = v == p1
                switch op {
                case 0x9, 0x11:
                    let ok = op == 0x9 ? eq : !eq
                    conds.append(Cond(active: active && ok, taken: ok, parentActive: active))
                case 0xA, 0x12:
                    let ok = op == 0xA ? eq : !eq
                    if var top = conds.popLast() {
                        if !top.taken && ok { top.active = top.parentActive; top.taken = true } else { top.active = false }
                        conds.append(top)
                    }
                default: trace?("\(project.name): condición desconocida 0x\(String(code, radix: 16))")
                }
                continue
            }
            guard active else { continue }
            switch (type, code) {
            case (4, 15):   // vaciar la cola y cortar
                channel.stop(fadeMs: 25)
                cursor = nil; cursorIsMarker = false; pendingGoto = nil; playingNode = nil; startAt = nil
            case (4, 3):    // ir al nodo: ya si no suena nada; si suena, al acabar la onda actual
                let st = channel.poll()
                if st.playing == nil && st.queued == 0 { startAt = p0; pendingGoto = nil }
                else {
                    pendingGoto = p0
                    channel.dropQueued()
                    if let pn = st.playing?.node { cursor = pn; cursorIsMarker = false }
                }
                stopped = false
            case (13, 15):  // llamada al juego
                trace?("\(project.name): llamada al juego \(p1)/\(p0)")
                delegate?.musicCallback(self, id: p1, param: p0)
            case (5, 12):   // fundido a p0 & 0xFF en p1 ms
                volume = Float(p0 & 0xFF)
                channel.setGain(volume / 127, ms: Double(p1))
            case (2, 12):   // esperar
                programs.append((actions, pc, conds, clock + Double(p0) / 1000, name))
                return
            case (8, 13):   // volumen inmediato
                volume = Float(p0); channel.setGain(volume / 127, ms: 0)
            case (8, 6):    // variable = valor
                if p0 < vars.count { vars[p0] = p1 }
            case (9, 0):    // otro evento
                let id = (p1 << 16) | p0
                if id & 0xFFFFFF != 0 { event(id) }
            default: break   // 4/2, 14/x: routers y variables internas [H: sin efecto aquí]
            }
        }
    }

    private func sysVar(_ i: Int) -> Int {
        switch i {
        case 3: return partNode
        case 4: return stopped ? 0 : 1
        default: return 0
        }
    }

    // MARK: Grafo

    private func branch(_ n: MusicNode) -> Int? {
        guard !n.branches.isEmpty else { return nil }
        // Nodos de fin con 0xF8 ({0,0} siguiente · {1,127} repetir): la rama de repetir [H: los ambientes se repiten hasta que
        // el juego cambia de zona; el valor con el que comparan no se manda nunca con control]
        if n.b3 == 0xF8, let loop = n.branches.max(by: { $0.max < $1.max }) { return loop.dest }
        let c = control
        if let b = n.branches.first(where: { $0.min < c && c <= $0.max }) { return b.dest }
        // Ninguna: la del tramo más cercano [H]
        return n.branches.min { a, b in
            func d(_ x: (min: Int, max: Int, dest: Int)) -> Int { c <= x.min ? x.min - c + 1 : c - x.max }
            return d(a) < d(b)
        }?.dest
    }

    /// Avanza la pista (hilo del juego). `dt` en segundos de reloj real.
    func update(dt: Double) {
        clock += dt
        // Programas de eventos que esperaban (acción 2/12)
        if !programs.isEmpty {
            let due = programs.filter { $0.resume <= clock }
            programs.removeAll { $0.resume <= clock }
            for p in due { run(p.actions, pc: p.pc, conds: p.conds, name: p.name) }
        }
        // Ondas que empezaron a sonar: parte actual (SongProgressCallback)
        var st = channel.poll(consume: true)
        for s in st.started {
            playingNode = s.node
            let ref = project.nodes[s.node].ref
            if ref != partNode { partNode = ref; trace?("\(project.name): parte → nodo \(ref)") }
            delegate?.musicPart(self, partNode: ref)
        }
        if st.playing == nil && st.queued == 0 { playingNode = nil }
        // Encolar lo siguiente cuando falta poco para acabar lo que suena
        var guardSteps = 0
        outer: while guardSteps < 64 {
            guardSteps += 1
            st = channel.poll()
            if st.queued > 0 { break }
            let busy = st.playing != nil
            if busy && st.remaining > lookahead { break }
            var node: Int
            if let s = startAt { node = s; startAt = nil; cursorIsMarker = false }
            else if let g = pendingGoto {
                pendingGoto = nil
                // Router de la onda actual: antes, la onda de paso hacia este destino [I]
                if let c = cursor, !cursorIsMarker, project.nodes[c].wave > 0, project.nodes[c].b4 > 0, project.nodes[c].b4 - 1 < project.routers.count,
                   let via = project.routers[project.nodes[c].b4 - 1].first(where: { $0.target == g })?.via {
                    trace?("\(project.name): router \(project.nodes[c].b4 - 1): onda \(c) → paso \(via) → \(g)")
                    node = via
                } else { node = g }
                cursorIsMarker = false
            } else if let c = cursor {
                if cursorIsMarker {
                    if busy { break }          // el nodo −3/−1 se atiende cuando la música llega ahí
                    cursorIsMarker = false
                    node = c
                } else {
                    guard let b = branch(project.nodes[c]) else { cursor = nil; continue }
                    node = b
                }
            } else {
                if !busy && !stopped { stopped = true; trace?("\(project.name): fin") }
                break
            }
            // Recorre los nodos sin onda hasta la siguiente onda
            for _ in 0..<64 {
                guard node >= 0, node < project.nodes.count else {
                    cursor = nil
                    if !busy { stopped = true; trace?("\(project.name): fin (nodo \(node))") }
                    break outer
                }
                let n = project.nodes[node]
                if n.wave > 0 {
                    let smp = n.wave - 1
                    let pcm: MusicPCM
                    switch self.pcm(smp) {
                    case .ready(let p): pcm = p
                    case .pending: startAt = node; break outer          // decodificándose en otro hilo: se encola en cuanto esté
                    case .failed: trace?("\(project.name): muestra \(smp) ilegible"); cursor = nil; break outer
                    }
                    let id = nextID; nextID += 1
                    channel.enqueue(MusicChannel.Segment(id: id, node: node, pcm: pcm))
                    cursor = node; cursorIsMarker = false; stopped = false
                    trace?(String(format: "%@: onda %d (muestra %d, %.1f s) · control %d", project.name, node, smp, pcm.seconds, control))
                    continue outer
                }
                if n.wave == 0 {
                    guard let b = branch(n) else { node = -1; continue }
                    node = b; continue
                }
                if busy { cursor = node; cursorIsMarker = true; break outer }
                if n.wave == -3 {
                    cursor = node
                    if n.event != 0 { event(n.event) }
                    if startAt != nil || pendingGoto != nil { continue outer }   // el evento pidió ir a otro sitio
                    if cursor == nil { break outer }                             // el evento vació la cola
                    guard let b = branch(n) else { node = -1; continue }
                    node = b; continue
                }
                // −1: fin, o sigue su rama
                if !n.branches.isEmpty, let b = branch(n) { node = b; continue }
                cursor = nil
                if !stopped { stopped = true; trace?("\(project.name): fin (nodo \(node))") }
                break outer
            }
            break
        }
    }

    // El cursor apunta a un nodo −3/−1 que espera a que acabe la onda que suena
    private var cursorIsMarker = false

    /// Sin ventana las pruebas decodifican en el acto (reloj simulado); en la app, las muestras largas (canciones) se
    /// decodifican en otro hilo para no parar el fotograma (~50 ms una canción de 4 min).
    static var synchronousDecode = false
    private static let decodeQueue = DispatchQueue(label: "rockport.music.decode", qos: .userInitiated)
    private let cacheLock = NSLock()
    private var decoding = Set<Int>()

    private enum PCMState { case ready(MusicPCM), pending, failed }

    private func pcm(_ sample: Int) -> PCMState {
        cacheLock.lock()
        if let p = decodeCache[sample] { cacheLock.unlock(); return .ready(p) }
        if decoding.contains(sample) { cacheLock.unlock(); return .pending }
        if failed.contains(sample) { cacheLock.unlock(); return .failed }
        cacheLock.unlock()
        let long = (project.samples[safe: sample]?.ms ?? 0) > 4000
        if long && !MusicTrack.synchronousDecode {
            cacheLock.lock(); decoding.insert(sample); cacheLock.unlock()
            let proj = project
            MusicTrack.decodeQueue.async { [weak self] in
                let p = proj.decode(sample: sample)
                guard let self else { return }
                self.cacheLock.lock(); self.decoding.remove(sample); if let p { self.store(sample, p) } else { self.failed.insert(sample) }; self.cacheLock.unlock()
            }
            return .pending
        }
        guard let p = project.decode(sample: sample) else { return .failed }
        cacheLock.lock(); store(sample, p); cacheLock.unlock()
        return .ready(p)
    }
    private var failed = Set<Int>()

    /// Caché pequeña: las ondas de persecución son cortas y se repiten; las canciones son largas (~30 MB). Con cacheLock.
    private func store(_ sample: Int, _ p: MusicPCM) {
        decodeCache[sample] = p
        cacheOrder.append(sample)
        var bytes = cacheOrder.reduce(0) { $0 + (decodeCache[$1]?.count ?? 0) * 4 }
        while bytes > 96 << 20, cacheOrder.count > 1 {
            let old = cacheOrder.removeFirst(); bytes -= (decodeCache[old]?.count ?? 0) * 4; decodeCache.removeValue(forKey: old)
        }
    }
}
