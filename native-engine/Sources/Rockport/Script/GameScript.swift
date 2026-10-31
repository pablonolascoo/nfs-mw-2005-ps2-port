// Guiones de juego del disco (doc 26 §6–7): actividades con grafo de estados (GActivity / GState / GHandler [D: nombres de
// la decomp]) cuyos manejadores de mensajes son Lua 5.0 compilado [V: scripts.json]. Aquí se ejecutan los originales:
//   · dueño   = colección de la actividad («16_2_1_d_day_intro») y sus plantillas («drive_to_target»)
//   · estado  = prerace / racing / postrace / done (carreras) · initial / activate_gps / driving / at_target / done (ir a…)
//   · mensaje = stateenter, stateexit, triggerenter, notifytimer, notifyengineblown, notifycellcallstarted…
// Cada manejador recibe (self, msg, state): self = la actividad (sus campos y sus colecciones hijas por nombre corto),
// msg = datos del mensaje y state = tabla persistente de la actividad.
// Las carreras en sí las lleva RaceSession (nativo); el guion solo añade lo propio de cada prueba (llamadas de Mia, motor
// saboteado, policía de guion…). Las funciones del juego que aún no tienen equivalente avisan una vez y devuelven nil.
import Foundation
import simd

/// scripts.json + gameplay.json (colecciones con su padre, valores e hijas).
final class ScriptLibrary {
    struct Handler { let name: String; let owner: String; let state: String; let message: String; let proto: LuaProto }
    struct Collection { let name: String; let parent: String?; let values: [String: Any] }

    private(set) var handlers: [Handler] = []
    private(set) var collections: [String: Collection] = [:]
    private var childrenOf: [String: [String]] = [:]
    static private(set) var shared: ScriptLibrary?

    static func load(_ data: GameData) -> ScriptLibrary? {
        if let s = shared { return s }
        guard let sd = try? Data(contentsOf: data.url("scripts.json")),
              let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any], let hs = sj["handlers"] as? [[String: Any]],
              let gd = try? Data(contentsOf: data.url("gameplay.json")),
              let gj = try? JSONSerialization.jsonObject(with: gd) as? [String: Any], let cs = gj["collections"] as? [[String: Any]] else {
            fputs("Guiones: faltan scripts.json o gameplay.json (reconvierte los datos)\n", stderr); return nil
        }
        let lib = ScriptLibrary()
        var bad = 0
        for h in hs {
            guard let name = h["name"] as? String, let owner = h["owner"] as? String, let state = h["state"] as? String,
                  let msg = h["message"] as? String, let b64 = h["lua"] as? String, let bytes = Data(base64Encoded: b64) else { bad += 1; continue }
            do { lib.handlers.append(Handler(name: name, owner: owner, state: state, message: msg, proto: try Lua50.load(bytes))) }
            catch { bad += 1; fputs("Guiones: \(name): \(error)\n", stderr) }
        }
        for c in cs {
            guard let n = c["name"] as? String else { continue }
            lib.collections[n] = Collection(name: n, parent: c["parent"] as? String, values: c["values"] as? [String: Any] ?? [:])
            if let slash = n.lastIndex(of: "/") { lib.childrenOf[String(n[..<slash]), default: []].append(n) }
        }
        print("Guiones: \(lib.handlers.count) manejadores Lua · \(lib.collections.count) colecciones\(bad > 0 ? " · \(bad) con error" : "")")
        shared = lib
        return lib
    }

    func hasHandlers(owner: String) -> Bool { handlers.contains { $0.owner == owner } }
    func children(_ n: String) -> [String] { childrenOf[n] ?? [] }
    /// Cadena de plantillas: «race_bin_16/drive_to_safe_house» → «drive_to_target» → «world_activity»…
    func templates(_ n: String) -> [String] {
        var out: [String] = [], cur = collections[n]?.parent
        while let p = cur, !out.contains(p), out.count < 8 { out.append(p); cur = collections[p]?.parent }
        return out
    }
    /// Valores con los de las plantillas debajo (la instancia manda).
    func values(_ n: String) -> [String: Any] {
        var v: [String: Any] = [:]
        for t in templates(n).reversed() { v.merge(collections[t]?.values ?? [:]) { $1 } }
        v.merge(collections[n]?.values ?? [:]) { $1 }
        return v
    }
    static func vec3(_ a: Any?) -> float3? {
        guard let l = a as? [Any], l.count >= 3 else { return nil }
        let f = l.compactMap { ($0 as? NSNumber)?.floatValue }
        return f.count >= 3 ? float3(f[0], f[1], f[2]) : nil
    }
}

/// Lo que el guion le pide al juego. Cada actividad lo rellena con lo que tenga sentido en su contexto.
struct ScriptActions {
    var log: (String) -> Void = { print($0) }
    var forceAIControl: (Int, Bool) -> Void = { _, _ in }
    var sabotageEngine: (Float) -> Void = { _ in }
    var spawnCop: (float3, Float, String) -> Void = { _, _, _ in }
    var setCopsEnabled: (Bool) -> Void = { _ in }
    var bailPursuit: () -> Void = {}
    var noNewPursuits: () -> Void = {}
    var fade: (Bool) -> Void = { _ in }
    var message: (String) -> Void = { _ in }
    var cellCall: (Int) -> Void = { _ in }
    var sms: (Int) -> Void = { _ in }
    var call911: () -> Void = {}
    var introRace: () -> Void = {}
    var nukeSmack: (float3, Float) -> Void = { _, _ in }
    var jumpToCarLot: () -> Void = {}
    var safeHouseIntro: (float3?) -> Void = { _ in }
    var showGPS: (Bool) -> Void = { _ in }
    var navigateTo: (float3?) -> Void = { _ in }
    var skipCareerIntro: () -> Bool = { false }
    var activityFinished: () -> Void = {}
    /// Cambio de estado pedido por el guion (la carrera decide qué significa «postrace»).
    var stateChanged: (String) -> Void = { _ in }
}

final class ScriptActivity {
    let name: String
    let lib: ScriptLibrary
    let vm = LuaVM()
    private(set) var state = ""
    var actions: ScriptActions
    private let owners: [String]
    private let selfTable = LuaTable()
    private let stateTable = LuaTable()
    private let player = LuaTable(), rival = LuaTable()
    private var objects: [String: LuaTable] = [:]
    private var timers: [String: Double] = [:]
    private struct Trigger { let obj: LuaTable; let pos: float3; let radius: Float; var inside: Bool }
    private var triggers: [Trigger] = []
    private var pendingState: String?
    private var warned = Set<String>()
    private var dispatching = 0
    /// Mensajes enviados (pruebas).
    private(set) var history: [String] = []

    /// owners: la actividad y, si no la lleva el motor, sus plantillas (para «ir a…» corren también los genéricos).
    init(name: String, lib: ScriptLibrary, actions: ScriptActions, withTemplates: Bool) {
        self.name = name; self.lib = lib; self.actions = actions
        owners = (withTemplates ? lib.templates(name).reversed() : []) + [name]
        setupGlobals()
        buildSelf()
        // Define las funciones de los manejadores de esta actividad (cada chunk asigna una global con su nombre)
        for h in lib.handlers where owners.contains(h.owner) {
            do { try vm.run(h.proto) } catch { actions.log("Guion \(h.name): \(error)") }
        }
    }

    // MARK: Objetos del guion

    /// Tabla de una colección (marcador, disparador, actividad): misma tabla siempre, así Sender == self.x funciona.
    func object(_ collection: String) -> LuaTable {
        if let o = objects[collection] { return o }
        let t = LuaTable()
        t["Name"] = .str(collection.split(separator: "/").last.map(String.init) ?? collection)
        t["CollectionName"] = .str(collection)
        objects[collection] = t
        return t
    }

    private func luaValue(_ v: Any) -> LuaValue {
        switch v {
        case let b as Bool: return .bool(b)
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .num(n.doubleValue)
        case let s as String: return lib.collections[s] != nil ? .table(object(s)) : .str(s)
        default: return .nil
        }
    }

    private func buildSelf() {
        selfTable["Name"] = .str(name)
        for (k, v) in lib.values(name) where k != "Children" { selfTable[k] = luaValue(v) }
        // Colecciones hijas por nombre corto (self.call_from_mia, self.kill_engine…) y disparadores con posición
        for c in lib.children(name) {
            let short = c.split(separator: "/").last.map(String.init) ?? c
            selfTable[short] = .table(object(c))
            guard let col = lib.collections[c], let p = ScriptLibrary.vec3(col.values["Position"]) else { continue }
            switch col.parent {
            case "planetrigger", "boxtrigger":
                // Radio: media anchura del plano o de la caja [I: el plano real tiene orientación; aquí basta con la cercanía]
                let w = (col.values["Width"] as? NSNumber)?.floatValue ?? ScriptLibrary.vec3(col.values["Dimensions"]).map { max($0.x, $0.y) } ?? 30
                triggers.append(Trigger(obj: object(c), pos: p, radius: max(12, w / 2), inside: false))
            default: break
            }
        }
        player["Name"] = .str("player"); rival["Name"] = .str("racer1")
        vm.register("IsPlayer", in: player) { _ in [.bool(true)] }
        vm.register("IsPlayer", in: rival) { _ in [.bool(false)] }
    }

    func position(of obj: LuaValue) -> float3? {
        guard let t = obj.table, let c = t["CollectionName"].string, let col = lib.collections[c] else { return nil }
        return ScriptLibrary.vec3(col.values["Position"])
    }

    // MARK: Funciones del juego

    private func stub(_ scope: String) -> (String) -> LuaValue {
        { [weak self] n in
            .native(LuaNativeBox(n) { _ in
                guard let self else { return [] }
                if self.warned.insert("\(scope)\(n)").inserted { self.actions.log("Guion \(self.name): \(scope)\(n) aún sin equivalente (se ignora)") }
                return []
            })
        }
    }

    private func setupGlobals() {
        let g = vm.globals
        let game = LuaTable(), debug = LuaTable()
        g["Game"] = .table(game); g["Debug"] = .table(debug)
        game.missing = stub("Game.")
        g.missing = { [weak self] n in n.first?.isUppercase == true ? (self?.stub("")(n) ?? .nil) : .nil }
        let num = { (a: [LuaValue], i: Int) -> Double in i < a.count ? a[i].number ?? 0 : 0 }
        let str = { (a: [LuaValue], i: Int) -> String in i < a.count ? a[i].string ?? "" : "" }
        vm.register("Print", in: debug) { [weak self] a in self?.actions.log("Guion: \(a.map { $0.string ?? $0.debug }.joined(separator: " "))"); return [] }
        vm.register("ChangeState") { [weak self] a in self?.pendingState = str(a, 0); return [] }
        vm.register("SetTimer", in: game) { [weak self] a in self?.timers[str(a, 0)] = num(a, 1); return [] }
        vm.register("KillTimer", in: game) { [weak self] a in self?.timers[str(a, 0)] = nil; return [] }
        vm.register("GetPlayerElement", in: game) { [weak self] _ in self.map { [.table($0.player)] } ?? [] }
        vm.register("ForceAIControl", in: game) { [weak self] a in self?.actions.forceAIControl(Int(num(a, 0)), true); return [] }
        vm.register("ClearAIControl", in: game) { [weak self] a in self?.actions.forceAIControl(Int(num(a, 0)), false); return [] }
        vm.register("SabotageEngine", in: game) { [weak self] a in self?.actions.sabotageEngine(Float(num(a, 1))); return [] }
        vm.register("SetCopsEnabled", in: game) { [weak self] a in self?.actions.setCopsEnabled(a.first?.truthy ?? false); return [] }
        vm.register("SpawnCop", in: game) { [weak self] a in
            guard let self, let marker = a.first, let p = self.position(of: marker) else { return [] }
            let yaw = (marker.table?["CollectionName"].string).flatMap { self.lib.collections[$0]?.values["Rotation"] as? NSNumber }?.floatValue ?? 0
            self.actions.spawnCop(p, yaw, str(a, 1)); return []
        }
        vm.register("NoNewPursuitsOrCops", in: game) { [weak self] _ in self?.actions.noNewPursuits(); return [] }
        vm.register("Fade", in: game) { [weak self] _ in self?.actions.fade(true); return [] }
        vm.register("JumpToCarLot", in: game) { [weak self] _ in self?.actions.jumpToCarLot(); return [] }
        vm.register("DoSafeHouseIntro", in: game) { [weak self] a in self?.actions.safeHouseIntro(a.first.flatMap { self?.position(of: $0) }); return [] }
        vm.register("ShowGPS", in: game) { [weak self] a in self?.actions.showGPS(a.first?.truthy ?? false); return [] }
        vm.register("NavigatePlayerTo", in: game) { [weak self] a in self?.actions.navigateTo(a.first.flatMap { self?.position(of: $0) }); return [] }
        vm.register("SkipCareerIntro", in: game) { [weak self] _ in [.bool(self?.actions.skipCareerIntro() ?? false)] }
        vm.register("NotifyActivityFinsihed", in: game) { [weak self] _ in self?.actions.activityFinished(); return [] }   // así, con la errata del juego
        vm.register("ECellCall") { [weak self] a in self?.actions.cellCall(Int(num(a, 0))); return [] }
        vm.register("EAddSMS") { [weak self] a in self?.actions.sms(Int(num(a, 0))); return [] }
        vm.register("E911Call") { [weak self] _ in self?.actions.call911(); return [] }
        vm.register("EDispIntroRace") { [weak self] _ in self?.actions.introRace(); return [] }
        vm.register("EBailPursuit") { [weak self] _ in self?.actions.bailPursuit(); return [] }
        vm.register("EFadeScreenNoLoadingBarOn") { [weak self] _ in self?.actions.fade(true); return [] }
        vm.register("EFadeScreenNoLoadingBarOff") { [weak self] _ in self?.actions.fade(false); return [] }
        vm.register("ENISNukeSmack") { [weak self] a in self?.actions.nukeSmack(float3(Float(num(a, 0)), Float(num(a, 1)), Float(num(a, 2))), Float(num(a, 3))); return [] }
    }

    // MARK: Mensajes y estados

    /// Envía un mensaje a los manejadores del estado actual (primero las plantillas, luego la actividad).
    func send(_ message: String, _ fields: [String: LuaValue] = [:]) {
        let msg = LuaTable()
        msg["Name"] = .str(message)
        for (k, v) in fields { msg[k] = v }
        history.append("\(state):\(message)")
        dispatching += 1
        for owner in owners {
            for h in lib.handlers where h.owner == owner && h.state == state && h.message == message {
                vm.budget = 200_000
                do { _ = try vm.call(vm.globals[h.name], [.table(selfTable), .table(msg), .table(stateTable)]) }
                catch { actions.log("Guion \(h.name): \(error)") }
            }
        }
        dispatching -= 1
        if dispatching == 0, let s = pendingState { pendingState = nil; enter(s) }
    }

    /// Cambia de estado: sale del actual y entra en el nuevo (como GActivity::ChangeState [D: nombre]).
    func enter(_ newState: String) {
        if !state.isEmpty { send("stateexit") }
        state = newState
        actions.log("  guion \(name): estado «\(newState)»")
        actions.stateChanged(newState)
        send("stateenter")
    }

    /// Temporizadores y disparadores (cada fotograma).
    func update(dt: Float, playerPos: float3?) {
        for (k, t) in timers {
            let left = t - Double(dt)
            if left <= 0 { timers[k] = nil; send("notifytimer", ["Name": .str(k)]) } else { timers[k] = left }
        }
        guard let p = playerPos else { return }
        for i in triggers.indices {
            let d = simd_distance(float2(p.x, p.y), float2(triggers[i].pos.x, triggers[i].pos.y))
            let inside = d < triggers[i].radius && abs(p.z - triggers[i].pos.z) < 25
            if inside && !triggers[i].inside {
                actions.log("  guion \(name): disparador «\(triggers[i].obj["Name"].string ?? "?")»")
                send("triggerenter", ["Sender": .table(triggers[i].obj), "Element": .table(player)])
            }
            triggers[i].inside = inside
        }
    }

    var activeTimers: [String] { Array(timers.keys) }
}
