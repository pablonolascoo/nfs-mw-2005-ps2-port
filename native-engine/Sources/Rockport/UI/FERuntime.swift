// FEng en tiempo de ejecución: objetos de un paquete con sus datos animables, scripts (pistas de fotogramas clave),
// eventos y respuestas a mensajes. Copia del comportamiento de FEPackage / FEngine / FEKeyInterp* de la decomp [D]:
//   - El bloque de datos de cada objeto son palabras de 32 bits (color b,g,r,a en enteros; pivote, posición, rotación,
//     tamaño, esquinas UV… en float). Cada pista escribe `size` bytes a partir de la palabra `offset`.
//   - Fotograma clave 0 = valor base (absoluto); el resto son deltas: valor = base + lerp(anterior, siguiente) [D: FEInterpLinear].
//   - Tiempo en «ticks» = milisegundos (FEFramesToTicks: 16 por fotograma de 60 Hz) [D].
//   - Al acabar un script: si encadena (chainTo) salta al siguiente; si no, una vez / bucle / ida y vuelta (flags & 3) [D: UpdateObject].
//   - Mensajes: eventos de los scripts y respuestas MR_SetScript, MR_PostMessageToFEng, MR_PostMessageToGame… [D: ProcessResponses].
import Foundation
import simd

final class FEObj {
    let def: FEJObject
    let index: Int                 // orden en el archivo
    var data: [Float]
    var flags: UInt32
    /// Recurso: hash de textura (imágenes) o de fuente (textos). FEngSetTextureHash lo cambia.
    var handle: UInt32
    var multiTex: [UInt32]
    var label: UInt32?
    /// Texto puesto por código (FEPrintf); tiene prioridad sobre la etiqueta.
    var text: String?
    var script: FEJScript?
    var time = 0
    var children: [FEObj] = []
    weak var parent: FEObj?
    /// Palabras puestas por código (FEngSetColor, FEngSetSize…): las pistas del script no las pisan. En el juego esos
    /// setters cambian el valor base de la pista (SetTrackValue) [D]; aquí se bloquea la palabra hasta el siguiente SetScript.
    var locked = Set<Int>()
    var type: Int { def.type }
    var guid: UInt32 { def.guid }
    var nameHash: UInt32 { def.nameHash }

    init(_ d: FEJObject, index: Int, handle: UInt32) {
        def = d; self.index = index; data = d.data; flags = d.flags; self.handle = handle
        multiTex = d.multi?.tex ?? []
        label = d.string?.label
    }

    // Campos del bloque de datos [D: FEObjData, FEImageData, FEMultiImageData]
    var color: SIMD4<Float> { SIMD4(data[2], data[1], data[0], data[3]) }       // r, g, b, a (0…255)
    func setColor(_ argb: UInt32) {
        locked.formUnion(0...3)
        data[0] = Float(argb & 0xff); data[1] = Float((argb >> 8) & 0xff); data[2] = Float((argb >> 16) & 0xff); data[3] = Float(argb >> 24)
    }
    var pivot: SIMD3<Float> { SIMD3(data[4], data[5], data[6]) }
    var pos: SIMD3<Float> { get { SIMD3(data[7], data[8], data[9]) } set { locked.formUnion(7...9); data[7] = newValue.x; data[8] = newValue.y; data[9] = newValue.z } }
    var rot: simd_quatf { simd_quatf(ix: data[10], iy: data[11], iz: data[12], r: data[13]) }
    var size: SIMD3<Float> { get { SIMD3(data[14], data[15], data[16]) } set { locked.formUnion(14...16); data[14] = newValue.x; data[15] = newValue.y; data[16] = newValue.z } }
    var uvTL: SIMD2<Float> { data.count > 18 ? SIMD2(data[17], data[18]) : SIMD2(0, 0) }
    var uvBR: SIMD2<Float> { data.count > 20 ? SIMD2(data[19], data[20]) : SIMD2(1, 1) }
    /// Multi-imagen: UV de la máscara (textura 1) y su rotación (PivotRot) [D: FEMultiImageData].
    var maskTL: SIMD2<Float> { data.count > 22 ? SIMD2(data[21], data[22]) : SIMD2(0, 0) }
    var maskBR: SIMD2<Float> { data.count > 28 ? SIMD2(data[27], data[28]) : SIMD2(1, 1) }
    var pivotRot: SIMD3<Float> {
        get { data.count > 35 ? SIMD3(data[33], data[34], data[35]) : .zero }
        set { if data.count > 35 { locked.formUnion(33...35); data[33] = newValue.x; data[34] = newValue.y; data[35] = newValue.z } }
    }
    var invisible: Bool { flags & 1 != 0 }

    func findScript(_ id: UInt32) -> FEJScript? { def.scripts.first { $0.id == id } }
    func isScript(_ id: UInt32) -> Bool { script?.id == id }

    /// Rotación en Z en grados (FEngSetRotationZ) [D].
    func setRotationZ(_ deg: Float) {
        let q = simd_quatf(angle: deg * .pi / 180, axis: SIMD3(0, 0, 1))
        locked.formUnion(10...13)
        data[10] = q.imag.x; data[11] = q.imag.y; data[12] = q.imag.z; data[13] = q.real
    }
}

/// Mensaje en cola: destino 0 = todos los paquetes (lista de destinos), 0xFFFFFFFF = juego, 0xFFFFFFFB = sonido,
/// 0xFFFFFFFC = el paquete de origen, otro valor = objeto por GUID [D: FEngine::ProcessMessageQueue].
struct FEMessage { let id: UInt32; weak var from: FEObj?; let target: UInt32 }

final class FEPackageRT {
    let def: FEJPackage
    let name: String
    let assets: FEAssets
    var roots: [FEObj] = []
    var all: [FEObj] = []
    private var byGuid: [UInt32: FEObj] = [:]
    private var queue: [FEMessage] = []
    /// Mensajes para el código del juego (MR_PostMessageToGame, eventos con destino 0xFFFFFFFF).
    var onGameMessage: ((UInt32, FEObj?) -> Void)?
    var currentButton: FEObj?
    var visible = true
    var age = 0

    init?(name: String, assets: FEAssets) {
        guard let d = assets.package(name) else { return nil }
        def = d; self.name = d.name; self.assets = assets
        for (i, o) in d.objects.enumerated() {
            let res = o.resIndex >= 0 && o.resIndex < d.resources.count ? d.resources[o.resIndex] : nil
            let handle = res.flatMap { UInt32($0.hash, radix: 16) } ?? 0
            let obj = FEObj(o, index: i, handle: handle)
            all.append(obj); byGuid[o.guid] = obj
        }
        for o in all {
            if let p = o.def.parent, let g = byGuid[p] { o.parent = g; g.children.append(o) } else { roots.append(o) }
            // Script INIT a tiempo 0 [D: ReadObjectChunk]
            o.script = o.findScript(FEH.initScript) ?? o.def.scripts.first
            o.time = 0
            evaluate(o)
        }
    }

    // MARK: Búsquedas (FEngFindObject por hash del nombre)

    func find(_ hash: UInt32) -> FEObj? { all.first { $0.nameHash == hash } }
    func find(_ name: String) -> FEObj? { find(feHash(name)) }
    func findAll(_ hash: UInt32) -> [FEObj] { all.filter { $0.nameHash == hash } }
    func object(guid: UInt32) -> FEObj? { byGuid[guid] }

    // MARK: Control desde el código (FEngInterfaceFEObjects.cpp [D])

    func setScript(_ o: FEObj?, _ id: UInt32, restart: Bool = true) {
        guard let o, let s = o.findScript(id) else { return }
        if o.script?.id != id || restart { o.time = 0 }
        o.script = s
        o.locked.removeAll()
        evaluate(o)
    }
    func setVisible(_ o: FEObj?, _ on: Bool) {
        guard let o else { return }
        if on { if o.flags & 8 == 0 { o.flags &= ~1 } } else { o.flags |= 1 }
        if o.type == 5 { for c in o.children { setVisible(c, on) } }
    }
    func printf(_ o: FEObj?, _ s: String) { o?.text = s }
    func setLabel(_ o: FEObj?, _ h: UInt32) { o?.label = h; o?.text = nil }

    func setCurrentButton(_ b: FEObj?, messages: Bool = true) {
        if messages {
            if let c = currentButton { post(FEH.unhighlight, from: nil, target: c.guid) }
            if let b { post(FEH.highlight, from: nil, target: b.guid) }
        }
        currentButton = b
    }

    // MARK: Mensajes

    func post(_ id: UInt32, from: FEObj? = nil, target: UInt32 = 0) { queue.append(FEMessage(id: id, from: from, target: target)) }

    /// Procesa la cola (los mensajes que generen las respuestas se procesan en la misma llamada, con límite).
    func processMessages() {
        var guardCount = 0
        while !queue.isEmpty && guardCount < 512 {
            let m = queue.removeFirst()
            guardCount += 1
            switch m.target {
            case 0, 0xFFFFFFFC, 0xFFFFFFFE, 0xFFFFFFFD:
                if let r = def.responses.first(where: { $0.msg == m.id }) { run(r, obj: nil) }
                if m.target == 0 || m.target == 0xFFFFFFFC, let t = def.targets.first(where: { $0.msg == m.id }) {
                    for g in t.guids { if let o = byGuid[g], let r = o.def.responses.first(where: { $0.msg == m.id }) { run(r, obj: o) } }
                }
            case 0xFFFFFFFF: onGameMessage?(m.id, m.from)
            case 0xFFFFFFFB, 0xFFFFFFFA: break          // sonido / entradas
            default:
                if let o = byGuid[m.target], let r = o.def.responses.first(where: { $0.msg == m.id }) { run(r, obj: o) }
            }
        }
    }

    private func run(_ list: FEJResponse, obj: FEObj?) {
        var i = 0
        let rs = list.responses
        /// Salto de condición: busca el Else/EndIf que cierra el If de la posición i [D: FindConditionBranchTarget].
        func branch(_ from: Int) -> Int {
            var depth = 0, j = from + 1
            while j < rs.count {
                let id = rs[j].id
                if id == 768 || id == 769 { depth += 1 }
                else if id == 1280 && depth == 0 { return j }
                else if id == 1281 { if depth == 0 { return j }; depth -= 1 }
                j += 1
            }
            return rs.count
        }
        while i < rs.count {
            let r = rs[i]
            switch r.id {
            case 0: if let o = obj { setScript(o, r.param) }                          // MR_SetScript
            case 1:                                                                   // MR_PostMessageToFEng
                post(r.param, from: obj, target: r.target)
            case 2: onGameMessage?(r.param, obj)                                      // MR_PostMessageToGame
            case 256: setCurrentButton(r.param != 0 ? byGuid[r.param] : nil)          // MR_SetActiveButton
            case 768: if obj?.script?.id != r.param { i = branch(i) }                 // MR_IfScriptEquals
            case 769: if obj?.script?.id == r.param { i = branch(i) }                 // MR_IfScriptNotEquals
            case 1280: i = branch(i)                                                  // MR_Else
            default: break                                                            // sonido, paquetes (los lleva FEScreens)
            }
            i += 1
        }
    }

    // MARK: Tiempo

    /// Avanza `ms` milisegundos todos los scripts [D: FEPackage::UpdateObject].
    func update(ms: Int) {
        age += ms
        for o in all { step(o, ms) }
        processMessages()
    }

    /// ¿Algún objeto está reproduciendo un script con duración que aún no ha terminado? (para «fin de salida»)
    var animating: Bool { all.contains { o in guard let s = o.script, s.length > 0, s.flags & 3 == 0 else { return false }; return o.time <= s.length } }

    private func step(_ o: FEObj, _ dt: Int) {
        guard var s = o.script else { return }
        let prev = o.time
        let len = s.length
        o.time = prev + dt
        if o.time >= len {
            if let c = s.chainTo, let next = o.findScript(c) {
                issueEvents(o, s, from: prev, to: len)
                let over = o.time - len
                evaluate(o, at: len)
                s = next; o.script = next; o.time = over
                issueEvents(o, next, from: 0, to: over)
            } else {
                switch s.flags & 3 {
                case 1:   // bucle
                    if len > 0 {
                        issueEvents(o, s, from: prev, to: len)
                        o.time %= len
                        issueEvents(o, s, from: 0, to: o.time)
                    } else { o.time = 0 }
                case 2:   // ida y vuelta
                    if len > 0 { o.time %= (2 * len) } else { o.time = 0 }
                default:  // una vez: se queda en Length+1
                    if prev <= len { issueEvents(o, s, from: prev, to: len) }
                    o.time = len + 1
                }
            }
        } else {
            issueEvents(o, s, from: prev, to: o.time)
        }
        evaluate(o)
    }

    private func issueEvents(_ o: FEObj, _ s: FEJScript, from: Int, to: Int) {
        guard !s.events.isEmpty, to >= from else { return }
        let to2 = to == s.length ? to + 1 : to
        for e in s.events where e.t >= from && e.t < to2 {
            switch e.target {
            case 0:
                if e.id == 0x1B3909AA { setCurrentButton(nil) } else { post(e.id, from: o, target: 0) }
            case 0xFFFFFFFF: onGameMessage?(e.id, o)
            case 0xFFFFFFFC, 0xFFFFFFFB, 0xFFFFFFFA: post(e.id, from: o, target: e.target)
            default:
                if e.id == 0x1B3909AA { setCurrentButton(byGuid[e.target]) } else { post(e.id, from: o, target: e.target) }
            }
        }
    }

    func evaluate(_ o: FEObj, at t: Int? = nil) {
        guard let s = o.script else { return }
        let time = t ?? o.time
        if o.locked.isEmpty { for tr in s.tracks { FEInterp.track(tr, time: time, into: &o.data) }; return }
        let saved = o.locked.map { ($0, o.data[$0]) }
        for tr in s.tracks { FEInterp.track(tr, time: time, into: &o.data) }
        for (i, v) in saved { o.data[i] = v }
    }
}

/// Interpolación de pistas [D: FEKeyInterp.cpp, FEKeyInterpLinear.cpp, FEKeyInterpNone.cpp].
enum FEInterp {
    static func track(_ tr: FEJTrack, time: Int, into d: inout [Float]) {
        guard let base = tr.keys.first else { return }
        let n = tr.size / 4
        guard tr.offset >= 0, tr.offset + n <= d.count else { return }
        let deltas = tr.keys.dropFirst()
        func write(_ v: [Float]) { for i in 0..<min(n, v.count) { d[tr.offset + i] = v[i] } }
        if tr.interp == 0 {
            // Sin interpolar: copia el valor del fotograma (absoluto) [D: FEInterpNone]
            let arr = Array(deltas)
            if time < 0 || arr.isEmpty { write(base.v); return }
            let ki = arr.firstIndex(where: { $0.t >= time }) ?? arr.count - 1
            write(ki > 0 && arr[ki].t > time ? arr[ki - 1].v : arr[ki].v)
            return
        }
        guard tr.interp == 1 || tr.interp == 3 else { return }
        guard !deltas.isEmpty else { write(base.v); return }
        var t = time
        if tr.action & 0x7f == 2, t > tr.length { t = tr.length * 2 - t }   // ida y vuelta
        // GetDeltaKeyAt: primer delta con tiempo ≥ t (o el último)
        let arr = Array(deltas)
        var ki = arr.count - 1
        for (i, k) in arr.enumerated() where k.t >= t { ki = i; break }
        let key = arr[ki]
        var frac: Float = 1
        var prev: FEJKey? = nil
        if ki > 0 && t < key.t {
            prev = arr[ki - 1]
            let div = Float(key.t - prev!.t)
            frac = div > 0.00001 ? Float(t - prev!.t) / div : 1
        } else if tr.action & 0x7f == 1, ki == 0, t < key.t, let last = arr.last, arr.count > 1 {
            // bucle: entre el último y el primero
            prev = last
            let div = Float(tr.length - last.t + key.t)
            frac = div > 0.00001 ? Float(t + tr.length - last.t) / div : 1
        }
        var out = [Float](repeating: 0, count: n)
        switch tr.param {
        case 5:   // cuaternión: base · slerp
            let qb = simd_quatf(ix: base.v[0], iy: base.v[1], iz: base.v[2], r: base.v[3])
            let qk = simd_quatf(ix: key.v[0], iy: key.v[1], iz: key.v[2], r: key.v[3])
            var q = qk
            if let p = prev, frac < 1 { q = simd_slerp(simd_quatf(ix: p.v[0], iy: p.v[1], iz: p.v[2], r: p.v[3]), qk, frac) }
            let r = qb * q
            out = [r.imag.x, r.imag.y, r.imag.z, r.real]
        case 1, 6:   // enteros (color): redondeo como FELerpInteger/FELerpColor
            for i in 0..<n {
                let b = base.v[safe: i], k = key.v[safe: i]
                if let p = prev { let a = p.v[safe: i]; out[i] = b + a + Float(Int((k - a) * frac + 0.5)) } else { out[i] = b + k }
            }
        default:
            for i in 0..<n {
                let b = base.v[safe: i], k = key.v[safe: i]
                if let p = prev { let a = p.v[safe: i]; out[i] = b + a + (k - a) * frac } else { out[i] = b + k }
            }
        }
        write(out)
    }
}

extension Array where Element == Float {
    subscript(safe i: Int) -> Float { i < count ? self[i] : 0 }
}
