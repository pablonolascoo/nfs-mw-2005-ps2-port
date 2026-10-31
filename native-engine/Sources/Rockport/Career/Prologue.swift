// Prólogo de la historia («D-Day», bin 16) como en el juego (doc 18 §9, doc 26 §7):
//
//   · Carrera nueva = bin 16, coche M3GTRCAREERSTART, sin dinero [D: CareerSettings::Default, StartNewCareer].
//   · Pruebas en el orden de GRaceDatabase::sDDayRaces [V: SLUS 0x4E4A60]: 16.1.0 → 16.2.2 → 16.2.3 → 16.1.1 → 16.2.1.
//     La siguiente es la primera aún no completada (GetNextDDayRace [G: pseudocódigo de Ghidra]).
//     Cada una con su guion Lua del disco (Script/GameScript.swift): llamada de Mia y fundido en 16.1.0, policía y 911
//     en 16.2.3, motor saboteado y persecución en 16.2.1. Sus películas (rac01, cro06_coh06a, raz08, pin11, bus12) las pone
//     Movies/ con IntroMovie / OutroMovie [V].
//   · 16.2.1 termina con el motor reventado → arresto (STORYFMV_BUS12) → Game.JumpToCarLot: el BMW se pierde y hay que
//     comprar coche en el concesionario con el dinero del D-Day (3 × 10 000 $) [V: CashValue].
//   · Entonces arranca la actividad del bin 16 «race_bin_16/drive_to_safe_house» (EntryActivity [V]) con sus guiones
//     originales: SMS 15 de Mia, GPS al garaje, SMS 121 si tardas 120 s y, al llegar, DoSafeHouseIntro → bin 15.
//   · Lo que aún no hay: la escena NIS EndingNis03 (Rog y Razor, tras 16.1.1) [pendiente: reproductor de NIS].
import Foundation
import simd

final class Prologue {
    static let shared = Prologue()
    /// GRaceDatabase::sDDayRaces [V]
    static let order = ["16.1.0", "16.2.2", "16.2.3", "16.1.1", "16.2.1"]
    static let startCar = "M3GTRCAREERSTART"

    private var career: Career { Career.shared }
    private var engine: Engine? { career.engine }
    private(set) var active = false
    private(set) var waitingForCar = false
    private(set) var drive: ScriptActivity?
    private var hooked = false
    /// Lo siguiente se hace en el próximo fotograma (fuera del cierre de la prueba anterior).
    private var pending: (() -> Void)?
    var log: (String) -> Void = { print($0) }
    /// Pruebas: se avisa al terminar cada paso.
    var onStep: ((String) -> Void)?

    /// ¿Partida en el D-Day? (IsDDay: bin > 15 [D])
    var isDDay: Bool { career.save.currentBin > 15 }

    /// Siguiente prueba del D-Day: la primera de sDDayRaces sin completar (GetNextDDayRace [G]).
    func nextRaceID() -> String? {
        guard let db = career.db else { return nil }
        return Prologue.order.first { id in
            guard let e = db.event(id) else { return false }
            return !career.save.racesWon.contains(e.id)
        }
    }

    private func hook() {
        guard !hooked, let engine else { return }
        hooked = true
        engine.frameHooks.append { [weak self] dt in self?.frame(dt: dt) }
    }

    /// Empieza o reanuda el D-Day (Career.newGame / Career.start con bin 16).
    func run() {
        hook()
        active = true
        if career.save.prologueCarLost == true { afterCarLot(); return }
        guard let id = nextRaceID(), let db = career.db, let e = db.event(id) else { afterCarLot(); return }
        start(e)
    }

    private func start(_ e: RaceEvent) {
        guard let sys = career.system, let engine else { return }
        // El D-Day se corre siempre con el BMW de la historia (PlayerCarType [V])
        if career.save.currentCar != Prologue.startCar { career.modifySave { $0.currentCar = Prologue.startCar } }
        if engine.car == nil { Config.playerPreset = Prologue.startCar; engine.loadCar() }
        log("Prólogo: \(e.eventId) (\(e.id))")
        onStep?("race:\(e.eventId)")
        sys.start(e, context: .career) { [weak self] o in
            guard let self else { return }
            if o.abandoned { self.log("Prólogo: \(e.eventId) abandonada; se retoma al continuar"); return }
            if !o.playerWon {
                // Perder una prueba normal del D-Day: se repite (el juego ofrece reiniciar) [I]
                self.log("Prólogo: \(e.eventId) perdida, se repite")
                self.pending = { self.start(e) }
                return
            }
            if e.eventId == "16.1.1" { self.log("Prólogo: escena NIS EndingNis03 (Rog y Razor) aún sin reproductor; se salta") }
            if e.eventId == "16.2.1" { return }   // el guion ya llamó a Game.JumpToCarLot
            self.pending = { self.run() }
        }
    }

    // MARK: Tras el arresto

    /// Game.JumpToCarLot [V: guion de 16.2.1, estado «done»]: el BMW se queda en el depósito y se va al concesionario.
    func jumpToCarLot() {
        log("Prólogo: arrestado. El BMW se pierde; al concesionario con \(career.save.cash) $")
        career.modifySave { s in
            s.cars.removeAll { $0 == Prologue.startCar }
            s.prologueCarLost = true
        }
        if let engine, let lot = carLot(near: engine.car?.position ?? .zero), let car = engine.car {
            // Delante de la puerta del concesionario, mirando hacia ella [I: el juego salta al menú del concesionario]
            let door = float3(lot.door[0], lot.door[1], lot.door[2]), out = float3(lot.out[0], lot.out[1], 0)
            let p = door + simd_normalize(out + 1e-6) * 18
            car.place(p + float3(0, 0, 1.5), yaw: atan2(-out.y, -out.x), collision: engine.collision, probe: 20)
            engine.chasePos = p + simd_normalize(out + 1e-6) * 8 + float3(0, 0, 3)
        }
        onStep?("carlot")
        afterCarLot()
    }

    private func carLot(near p: float3) -> GarageInfo? {
        engine?.garages?.world?.infos.filter { $0.zoneType == "carlot" && $0.door.count >= 3 && $0.out.count >= 2 }
            .min { simd_distance(p, float3($0.door[0], $0.door[1], $0.door[2])) < simd_distance(p, float3($1.door[0], $1.door[1], $1.door[2])) }
    }

    /// Sin coche: hay que comprarlo; con coche: ir al garaje (actividad del bin 16).
    private func afterCarLot() {
        if career.save.cars.isEmpty {
            waitingForCar = true
            engine?.raceHUD?.showMessage(.custom(StoryText.buyCar))
            return
        }
        waitingForCar = false
        startDriveToSafehouse()
    }

    private func frame(dt: Float) {
        guard active else { return }
        if let p = pending, career.system?.session == nil { pending = nil; p() }
        if waitingForCar, !career.save.cars.isEmpty { afterCarLot() }
        if let d = drive { d.update(dt: dt, playerPos: engine?.car?.position) }
    }

    // MARK: race_bin_16/drive_to_safe_house (guiones originales, con sus plantillas)

    func startDriveToSafehouse() {
        guard drive == nil, let engine, let lib = ScriptLibrary.load(engine.data) else { return }
        StoryText.assets = engine.ui?.assets
        var a = ScriptActions()
        a.log = { [weak self] s in self?.log(s) }
        a.setCopsEnabled = { on in AIConfig.police = on }
        a.sms = { [weak self] id in self?.engine?.raceHUD?.showMessage(.custom(StoryText.sms(id))); self?.log("  guion: SMS \(id)") }
        a.showGPS = { [weak self] on in if !on { self?.engine?.raceHUD?.setNextCheckpoint(nil) } }
        a.navigateTo = { [weak self] p in self?.gpsTarget = p; self?.engine?.raceHUD?.setNextCheckpoint(p); self?.log("  guion: GPS al garaje \(p.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "—")") }
        a.skipCareerIntro = { false }
        a.safeHouseIntro = { [weak self] _ in self?.finish() }
        a.activityFinished = { [weak self] in self?.log("  guion: actividad terminada") }
        let act = ScriptActivity(name: "race_bin_16/drive_to_safe_house", lib: lib, actions: a, withTemplates: true)
        drive = act
        log("Prólogo: al garaje (race_bin_16/drive_to_safe_house)")
        onStep?("drive")
        act.enter("initial")
    }
    private(set) var gpsTarget: float3?

    /// DoSafeHouseIntro [V]: llegada al refugio → película del refugio y del primer rival, y empieza la Lista Negra (bin 15).
    private func finish() {
        guard active else { return }
        active = false
        drive = nil
        engine?.raceHUD?.setNextCheckpoint(nil)
        log("Prólogo completado: refugio. Lista Negra, bin 15")
        career.modifySave { s in s.currentBin = 15; s.prologueCarLost = nil }
        if career.persist { Movies.shared.careerNewGame() }   // STORYFMV_SAF25 + BLACKLIST_15
        onStep?("done")
        career.enterAfterPrologue()
    }
}
