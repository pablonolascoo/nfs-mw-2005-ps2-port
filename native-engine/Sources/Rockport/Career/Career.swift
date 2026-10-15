// Carrera profesional: la Lista Negra del 15 al 1 (GRaceBin, GRaceDatabase [D: Gameplay/GRaceDatabase.h]).
//
// Reglas (datos de cada race_bin_NN en races.json [V]):
//  - En cada bin se corren sus WorldRaces (marcadores del mundo) y se cumplen sus hitos de persecución (milestones).
//  - Se puede retar al rival cuando: pruebas ganadas del bin ≥ RequiredRacesWon, hitos ≥ RequiredChallenges y
//    recompensa total ≥ RequiredBounty (GetRequiredRaceWins / GetRequiredChallenges / GetRequiredBounty [D]).
//  - El rival se vence ganando todas sus BossRaces en orden. Premio: su coche (pink slip, PresetRide del jefe) y los
//    marcadores de recompensa del bin (cash_bonus…). El bin pasa al siguiente (15 → 14 …).
//  - Al cambiar de bin se activan las vallas de la historia de ese bin (Barriers: BARRIER_LOCKED_10…15) y se quitan las
//    demás: así se abren los distritos (EnableBinBarriers / DisableBinBarriers [D]).
//  - Recompensa (bounty): la de cada persecución evadida (coste para el estado) y la de cada hito [I: reparto exacto sin decomp].
import Foundation
import simd

final class Career {
    static let shared = Career()
    private(set) weak var engine: Engine?
    private(set) var save = CareerSave()
    var saveURL = CareerSave.defaultURL
    /// Las pruebas sin ventana no guardan en la partida del usuario.
    var persist = true
    var log: (String) -> Void = { print($0) }
    private(set) var active = false
    private var wasInPursuit = false
    private var pursuitBase: AIStats?
    private var lastTrap: String?

    func attach(_ e: Engine) { engine = e }
    var system: RaceSystem? { engine.flatMap { RaceSystem.attach($0) } }
    var db: RaceDatabase? { system?.db }

    // MARK: Menú

    /// «Carrera profesional → Continuar»: carga la partida (o empieza una) y entra en la zona libre con el bin actual.
    func start() {
        save = (persist ? CareerSave.load(saveURL) : nil) ?? CareerSave()
        enter()
    }

    /// «Carrera profesional → Empezar de nuevo».
    func newGame() {
        save = CareerSave()
        if persist { save.save(saveURL) }
        enter()
    }

    private func enter() {
        guard let engine, let sys = system else { return }
        active = true
        if engine.car == nil { Config.playerPreset = save.currentCar; engine.loadCar() }
        if engine.mode != .drive { engine.toggleMode() }
        applyBin()
        log("Carrera profesional: bin \(save.currentBin) · \(save.cash) $ · recompensa \(save.bounty) · \(save.racesWon.count) pruebas ganadas")
        _ = sys
    }

    /// Vallas del bin y marcadores del mundo; nivel de calor del bin (Base/MaxOpenWorldHeat [V]).
    func applyBin() {
        guard let sys = system, let db else { return }
        let bin = db.bin(save.currentBin)
        sys.world.setBinBarriers(bin?.barriers ?? [])
        if let b = bin, let ai = engine?.ai {
            AIConfig.maxOpenWorldHeat = max(1, b.heat.max)
            ai.police.heat = max(ai.police.heat, max(1, b.heat.base))
            AIConfig.careerBucket = max(0, 15 - b.binIndex)
        }
        // Marcadores del mundo: las pruebas de este bin y de los ya superados (se pueden repetir)
        var ev: [RaceEvent] = []
        for b in db.bins where b.binIndex >= save.currentBin && b.binIndex <= 15 {
            ev += b.worldRaces.compactMap { db.event($0) }
        }
        sys.setWorldEvents(ev)
    }

    // MARK: Estado de la Lista Negra

    func bin(_ i: Int? = nil) -> RaceBin? { db?.bin(i ?? save.currentBin) }

    func racesWon(in b: RaceBin) -> Int { b.worldRaces.filter { save.racesWon.contains($0) }.count }
    func milestonesDone(in b: RaceBin) -> Int { b.milestones.filter { save.milestonesDone.contains($0) }.count }

    /// ¿Se puede retar al rival del bin actual? (GRaceBin: GetRequired* [D]).
    func canChallengeRival() -> Bool {
        guard let b = bin() else { return false }
        return racesWon(in: b) >= b.requiredRacesWon && milestonesDone(in: b) >= b.requiredChallenges && save.bounty >= b.requiredBounty
    }

    /// Próxima carrera del rival (BossRaces en orden, saltando las ganadas). La persecución épica del bin 1 es un desafío.
    func nextBossRace() -> RaceEvent? {
        guard let b = bin(), let db else { return nil }
        return b.bossRaces.lazy.filter { !self.save.bossRacesWon.contains($0) }.compactMap { db.event($0) }.first
    }

    /// Ficha de la Lista Negra para RaceHUD.showBlacklist.
    func rivals() -> [BlacklistRival] {
        guard let db else { return [] }
        return (1...15).compactMap { i -> BlacklistRival? in
            guard let b = db.bin(i) else { return nil }
            let preset = b.bossPreset.flatMap { p in CarPresets.all(engine!.data).first { $0.name == p } }
            return BlacklistRival(rank: i, name: b.bossName, carName: preset?.car ?? "", racesWon: racesWon(in: b), racesRequired: b.requiredRacesWon,
                                  milestonesDone: milestonesDone(in: b), milestonesRequired: b.requiredChallenges, bounty: save.bounty,
                                  bountyRequired: b.requiredBounty, defeated: save.rivalsDefeated.contains(i),
                                  unlocked: i == save.currentBin && canChallengeRival())
        }
    }

    /// Pantalla de la Lista Negra; aceptar sobre el rival actual (si se puede retar) empieza su carrera.
    func showBlacklist() {
        guard let hud = system?.hud else { return }
        hud.showBlacklist(rivals(), selected: save.currentBin) { [weak self] rank in
            guard let self, let rank, rank == self.save.currentBin else { return }
            self.challengeRival()
        }
    }

    @discardableResult
    func challengeRival() -> Bool {
        guard canChallengeRival(), let e = nextBossRace(), let sys = system else { return false }
        log("Lista Negra: carrera contra \(bin()?.bossName ?? "?") — \(e.eventId) \(e.kind.rawValue)")
        return sys.start(e, context: .career) != nil
    }

    // MARK: Resultados

    /// Lo llama RaceSystem al terminar una prueba de la carrera profesional.
    func record(_ o: RaceOutcome) {
        guard !o.abandoned else { return }
        let e = o.event
        if o.playerWon {
            save.cash += o.cash
            save.bounty += o.bounty
            if let t = o.playerTime { save.bestTimes[e.id] = min(save.bestTimes[e.id] ?? .greatestFiniteMagnitude, t) }
            if !save.racesWon.contains(e.id) { save.racesWon.append(e.id) }
            if e.challengeSeries && !save.challengesDone.contains(e.id) { save.challengesDone.append(e.id) }
            if let b = bin(), b.bossRaces.contains(e.id), !save.bossRacesWon.contains(e.id) {
                save.bossRacesWon.append(e.id)
                if nextBossRace() == nil { defeatRival(b) }
            }
        }
        log(String(format: "Carrera profesional: %@ %@ · %d $ · recompensa %d · bin %d (%@)", e.eventId, o.playerWon ? "ganada" : "perdida",
                   save.cash, save.bounty, save.currentBin, progressText()))
        if persist { save.save(saveURL) }
        applyBin()
    }

    /// Rival vencido: pink slip (su coche), recompensas del bin y siguiente bin.
    private func defeatRival(_ b: RaceBin) {
        save.rivalsDefeated.append(b.binIndex)
        var carName = ""
        if let p = b.bossPreset, !p.isEmpty {
            if !save.cars.contains(p) { save.cars.append(p) }
            carName = p
        }
        for r in b.rewards where r.type == "cash_bonus" { save.cash += Int(r.cash) }
        log("Lista Negra: ¡\(b.bossName) (nº \(b.binIndex)) vencido! Coche ganado: \(carName.isEmpty ? "—" : carName)")
        system?.hud?.showCarWon(carName: carName, rivalName: b.bossName) {}
        save.bossRacesWon = []
        save.currentBin = max(0, b.binIndex - 1)
        if save.currentBin == 0 { log("Lista Negra completada") }
    }

    func progressText() -> String {
        guard let b = bin() else { return "Lista Negra completada" }
        return "pruebas \(racesWon(in: b))/\(b.requiredRacesWon) · hitos \(milestonesDone(in: b))/\(b.requiredChallenges) · recompensa \(save.bounty)/\(b.requiredBounty)" +
            (canChallengeRival() ? " · RIVAL DISPONIBLE" : "")
    }

    // MARK: Persecuciones en la zona libre: hitos y recompensa

    func updateFreeRoam(dt: Float) {
        guard active, let ai = engine?.ai, let pol = ai.police else { return }
        // Radares de la zona libre del bin: pasar por encima del umbral cuenta como desafío [V: OpenWorldSpeedTrap, ThreshholdSpeed]
        if let car = engine?.car, let b = bin(), let db {
            for id in b.milestones where !save.milestonesDone.contains(id) {
                guard let m = db.milestone(id), m.type == "speedtrap", let p = m.pos, p.count >= 3 else { continue }
                let d = simd_distance(float2(car.position.x, car.position.y), float2(p[0], p[1]))
                guard d < (m.radius ?? 20), abs(car.position.z - p[2]) < 12 else { continue }
                let kmh = simd_length(car.velocity) * 3.6
                if lastTrap != id { lastTrap = id; system?.hud?.showMessage(.speedtrap(mps: kmh / 3.6)); log(String(format: "Radar %@: %.0f km/h (objetivo %.0f)", id, kmh, m.goalEasy)) }
                if kmh >= m.goalEasy { save.milestonesDone.append(id); save.bounty += Int(m.bounty); log("Desafío cumplido: \(id) · \(progressText())"); if persist { save.save(saveURL) } }
            }
        }
        if pol.inPursuit && !wasInPursuit { pursuitBase = ai.stats }
        if wasInPursuit && !pol.inPursuit {
            if pol.state == .evaded { pursuitEvaded(police: pol, stats: ai.stats) }
            else if pol.state == .busted || pol.state == .none { log("Persecución terminada sin evasión: no hay recompensa") }
        }
        wasInPursuit = pol.inPursuit
    }

    /// Persecución evadida: la recompensa (coste para el estado) se suma y se comprueban los hitos del bin [I].
    func pursuitEvaded(police: PoliceManager, stats: AIStats) {
        let earned = police.costToState
        save.bounty += earned
        var done: [String] = []
        if let b = bin(), let db {
            for id in b.milestones where !save.milestonesDone.contains(id) {
                guard let m = db.milestone(id), m.type != "speedtrap" else { continue }
                let v = RaceMilestones.value(m.type, police: police, stats: stats, base: pursuitBase, pursuitTime: nil)
                if RaceMilestones.reached(m.type, value: v, goal: m.goalEasy) {
                    save.milestonesDone.append(id); save.bounty += Int(m.bounty); done.append(id)
                    system?.hud?.showMessage(.custom("Hito: \(m.type)"))
                }
            }
        }
        log("Persecución evadida: +\(earned) de recompensa · hitos nuevos: \(done.isEmpty ? "ninguno" : done.joined(separator: ", ")) · \(progressText())")
        if persist { save.save(saveURL) }
    }

    // MARK: Pruebas (--career-test)

    /// Sustituye la partida (pruebas sin ventana).
    func setSave(_ s: CareerSave) { save = s }
    /// Cambios de la partida desde los garajes (Garage/GarageMenus.swift): compra, coche actual, dinero; guarda si toca.
    func modifySave(persistNow: Bool = true, _ f: (inout CareerSave) -> Void) {
        f(&save)
        if persist && persistNow { save.save(saveURL) }
    }
    /// Coche del jugador para el escenario del frontend: el de la partida en curso o el de la partida guardada.
    var currentCarPreset: String? { active ? save.currentCar : (persist ? CareerSave.load(saveURL)?.currentCar : nil) }
    func applyMilestone(_ id: String) {
        guard let m = db?.milestone(id), !save.milestonesDone.contains(id) else { return }
        save.milestonesDone.append(id); save.bounty += Int(m.bounty)
    }
    func addBounty(_ n: Int) { save.bounty += n }
}
