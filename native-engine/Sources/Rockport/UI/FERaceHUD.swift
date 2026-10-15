// Implementación de RaceHUD (RaceHUD.swift) y de las pantallas que salen del HUD, con los paquetes originales:
//   - HUD de la prueba: HUD_SingleRace / HUD_Drag (FEHud.swift).
//   - Resultados: PostRace_Results.fng (PostRaceResultsScreen::SetupResults [D]).
//   - Lista Negra: InGameReputationOverview.fng (uiRepSheetMain [D]) con retrato RIVAL_%02d_IG y firma RIVAL_%02d_IG_GRAF
//     (GLOBAL\RIVALS.BIN), nombre BLACKLIST_RIVAL_%02d_AKA y requisitos (carreras, hitos, recompensa).
//   - Coche ganado: Showcase.fng con la firma del rival [I: el juego enseña el coche del rival en la vitrina].
//   - Fin de persecución: ARRESTADO (mensaje del HUD + BUSTED_OVERLAY.fng, la cámara de la policía [D: FeBustedOverlay]) y
//     EVADIDO (PostRace_MilestoneRewards.fng: «Duración de la persecución», recompensa y total [D: PostRaceMilestonesScreen]).
import Foundation
import simd

extension FEUI: RaceHUD {
    func beginRace(_ setup: RaceHUDSetup) {
        hud?.race = FEHud.RaceState(setup: setup)
        dragHud?.race = hud?.race
    }
    func endRace() { hud?.race = nil; dragHud?.race = nil }
    func showCountdown(_ value: Int) { hud?.race?.countdown = value }
    func setPosition(_ position: Int, of total: Int) { hud?.race?.position = position; hud?.race?.racerCount = total }
    func setLap(_ lap: Int, of total: Int) {
        if let r = hud?.race, lap > r.lap, lap == total, total > 1 { hud?.queueMessage(.finalLap) }
        hud?.race?.lap = lap; hud?.race?.laps = total
    }
    func setTimer(raceTime: Double, lapTime: Double?, bestLap: Double?) { hud?.race?.raceTime = raceTime; hud?.race?.lapTime = lapTime; hud?.race?.bestLap = bestLap }
    func setProgress(_ percent: Float) { hud?.race?.percentComplete = percent }
    func setRacers(_ racers: [RaceHUDRacer]) { hud?.race?.racers = racers; if !racers.isEmpty { hud?.race?.racerCount = racers.count } }
    func setNextCheckpoint(_ world: SIMD3<Float>?) { hud?.race?.nextCheckpoint = world }
    func setRoute(_ points: [SIMD3<Float>]) { hud?.race?.route = points }
    func setRacerBlips(_ positions: [SIMD3<Float>]) { hud?.race?.blips = positions }
    func setSpeedtrap(totalMps: Float, passed: Int, of total: Int) {
        hud?.race?.speedtrapTotal = totalMps; hud?.race?.speedtrapPassed = passed; hud?.race?.checkpointCount = total
    }
    func setDrag(shiftQuality: Int, engineTemp: Float) { hud?.race?.shiftQuality = shiftQuality; hud?.race?.engineTemp = engineTemp }
    func showMessage(_ message: RaceHUDMessage) { hud?.queueMessage(message) }

    // MARK: Resultados (PostRace_Results)

    func showResults(_ results: RaceResults, onContinue: @escaping () -> Void) {
        dismissScreens()
        guard let s = push("PostRace_Results") else { onContinue(); return }
        let p = s.pkg
        // Setup: todas las líneas ocultas y las columnas de la clasificación [D]
        for i in 1...11 { p.setScript(p.find("LINE\(i)_GROUP"), FEH.hide); p.setVisible(p.find("COLUMN2_DATA\(i)"), true) }
        for o in p.findAll(0x586AB4A6) { p.setLabel(o, 0x96B05F47) }                                  // Posición
        for o in p.findAll(0x44AC8987) { p.setLabel(o, 0xCE678AD3) }                                  // Nombre
        for o in p.findAll(0x30EE5E68) { p.setLabel(o, results.kind == .speedtrap ? 0x7540FB04 : 0xB67DA102) }   // Tiempo / Velocidad
        if let t = p.find(0x2D691760) { setLabelDeep(p, t, 0xFF115FFF) }                              // CLASIFICACIÓN
        if let b = p.find(0x5CED1D04) { setLabelDeep(p, b, 0xD0B8AA33) }                              // Estadísticas
        let kmh = assets.language != "english"
        for (k, r) in results.rows.sorted(by: { $0.position < $1.position }).prefix(11).enumerated() {
            p.setScript(p.find("LINE\(k + 1)_GROUP"), FEH.initScript)                                  // StatsPanel::AddStat
            p.printf(p.find("COLUMN1_DATA\(k + 1)"), "\(r.position)")
            p.printf(p.find("COLUMN2_DATA\(k + 1)"), r.name)
            let value: String
            if results.kind == .speedtrap, let v = r.speedTrapMps {
                value = "\(FEHud.money(Int((v * (kmh ? 3.6 : 2.23694)).rounded()))) \(assets.string(kmh ? 0x8569A25F : 0x8569AB44) ?? "")"
            } else if let t = r.totalTime { value = FEHud.timeString(t) }
            else { value = assets.string(r.isPlayer ? 0x5d82dba2 : 0x5d82dba2) ?? "DNF" }
            p.printf(p.find("COLUMN3_DATA\(k + 1)"), value)
        }
        if let g = p.find(0x445A862B) { p.setScript(g, FEH.appear) }
        p.setScript(p.find(0x8A41F5B9), FEH.hide)                                                     // sin nombre de corredor (StatsPanel::Draw)
        // Partida sin conexión: fuera los botones del modo online (tarjeta de jugador, revisar jugador, silenciar, opinión);
        // el juego solo los activa con IsOnlineMode/IsLANMode (NotificationMessage FEHASH_INITCOMPLETE) [D][I: grupos]
        for x: UInt32 in [0xd9cfb4eb, 0x58555d72, 0x86fbe2c6, 0xcd066337, 0x812A09D4] { p.setScript(p.find(x), FEH.hide); p.setVisible(p.find(x), false) }
        enterModal(s, accept: { [weak self] in self?.closeModal(s, then: onContinue) }, back: nil)
    }

    // MARK: Lista Negra (InGameReputationOverview)

    func showBlacklist(_ rivals: [BlacklistRival], selected: Int, onChoice: @escaping (Int?) -> Void) {
        dismissScreens()
        guard !rivals.isEmpty else { onChoice(nil); return }
        // uiRepSheetMain::Setup: carrusel con Hoja de carreras, Hitos, Recompensa y Biografía del rival [D]
        guard let s = iconMenu("InGameReputationOverview", title: nil, options: [
            (0xefc9662e, 0x84e4a54c, {}), (0xd807e9b3, 0x216f1b81, {}), (0x021a4b0c, 0xe451941e, {}), (0xe97e4e83, 0x2d159737, {}),
        ]) else { onChoice(nil); return }
        let p = s.pkg
        // Dentro del juego los iconos van en naranja: SetIdleColor(0xFFFFAE40) / SetFadeColor(0x00FFAE40) [D]
        s.scroller?.idleColor = 0xFFFFAE40; s.scroller?.fadeColor = 0x00FFAE40
        s.scroller?.snap()
        if let t = p.find(0x242657ce) { setLabelDeep(p, t, 0x2e3919e9) }
        var idx = max(0, min(rivals.count - 1, rivals.firstIndex { $0.rank == selected } ?? 0))
        let show: (Int) -> Void = { [weak self] i in self?.blacklistPage(p, rivals[i]) }
        show(idx)
        enterModal(s, accept: { [weak self] in
            // ✕ sobre el rival: retarle si está disponible (PAD_BUTTON4 en el juego) [D]
            let r = rivals[idx]
            self?.closeModal(s) { onChoice(r.unlocked && !r.defeated ? r.rank : nil) }
        }, back: { [weak self] in self?.closeModal(s) { onChoice(nil) } }, upDown: { d in
            // ScrollRival: arriba/abajo cambian de rival con la animación del retrato [D]
            let n = idx + d
            guard n >= 0 && n < rivals.count else { return }
            idx = n
            p.setScript(p.find(0xc1f62308), d > 0 ? 0xaf9d73f2 : 0x9e5e6b5f)
            show(idx)
        })
    }

    /// uiRepSheetMain::UpdateInfo + uiRepSheetRivalStreamer [D].
    private func blacklistPage(_ p: FEPackageRT, _ r: BlacklistRival) {
        let money = FEHud.money
        p.printf(p.find(0x15d80973), "\(r.racesWon)")
        p.printf(p.find(0xd802fba8), "\(r.milestonesDone)")
        p.printf(p.find(0x322b18f9), money(r.bounty))
        p.printf(p.find(0xde7ad199), "\(r.racesRequired)")
        p.printf(p.find(0x7242962e), "\(r.milestonesRequired)")
        p.printf(p.find(0x055c6e5f), money(r.bountyRequired))
        p.setScript(p.find(0x4c3b1536), r.racesWon >= r.racesRequired ? 0xe6361f46 : FEH.hide)
        p.setScript(p.find(0x4c3b1537), r.milestonesDone >= r.milestonesRequired ? 0xe6361f46 : FEH.hide)
        p.setScript(p.find(0x4c3b1538), r.bounty >= r.bountyRequired ? 0xe6361f46 : FEH.hide)
        // Título «LISTA NEGRA #n» (0x96ca2471 con %d) y nombre/desafío del rival desde la tabla de textos del juego
        let fmt = assets.string(0x96ca2471) ?? "#%d"
        printDeep(p, p.find(0x242657ce), fmt.replacingOccurrences(of: "%d", with: "\(r.rank)"))
        let aka = assets.string(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", r.rank))) ?? r.name
        let blurb = assets.string(feHash(String(format: "BLACKLIST_RIVAL_%02d_CHALLENGE", r.rank))) ?? ""
        printDeep(p, p.find(0x7ac3d0c9), aka)
        printDeep(p, p.find(0x79cf0442), blurb)
        // Retrato y firma del rival (versión «IG» dentro del juego)
        let img = p.find(0xc1f62308), tag = p.find(0xf5a2a087)
        img?.handle = feHash(String(format: "RIVAL_%02d_IG", r.rank)); p.setVisible(img, true)
        tag?.handle = feHash(String(format: "RIVAL_%02d_IG_GRAF", r.rank)); p.setVisible(tag, true)
        p.post(0xC0942E85); p.post(0x8C9D4547)                                       // RIVALLOADED / GRAFLOADED
        // Sello DERROTADO (DEFEATED_<idioma>) y botón «Desafiar rival» [D]
        let stamp = p.find(0x7FE4020F)
        stamp?.handle = assets.language == "spanish" ? 0x087bb8d4 : 0x087b7d0a
        p.setVisible(stamp, r.defeated)
        p.setVisible(p.find(0x34d4433b), r.defeated)
        if r.defeated { p.setVisible(p.find(0x55f6aa1a), false); p.post(0xb4c144b1) }
        else if r.unlocked { p.post(feHash("RIVAL_CHALLENGE_DEACTIVATED")); p.setVisible(p.find(0x55f6aa1a), true) }
        else {
            // La decomp manda RIVAL_CHALLENGE_ACTIVATED con el rival no disponible, y ese mensaje oculta el panel de
            // requisitos (grupo 0x1E617835: ACTIVATED/ON → HIDE, OFF → SHOW) [D][V]. Así la pantalla quedaba con un hueco
            // vacío justo cuando más falta hacen los requisitos; dejamos el panel a la vista [I: el `if` de UpdateInfo está
            // marcado sin resolver en la decomp].
            p.setVisible(p.find(0x55f6aa1a), false)
        }
        if let panel = p.find(0x1E617835) { p.setScript(panel, 0x1ca7c0) }        // SHOW
        // Recompensa y dinero se turnan en la cabecera: los scripts ON/OFF de 0xB514E2D8 y 0xF91A59F6 se mandan el relevo
        // cada 300 ms (eventos 0x71A545A9 / 0x0339155A) [V]
        let cash = assets.string(0x73b79e0) ?? "", bounty = assets.string(0xce6b99b1) ?? ""
        printDeep(p, p.find(0xb514e2d8), "\(bounty) \(money(r.bounty))")
        printDeep(p, p.find(0xf91a59f6), "\(cash) \(money(blacklistCash))")
    }

    // MARK: Coche ganado (Showcase)

    func showCarWon(carName: String, rivalName: String, onContinue: @escaping () -> Void) {
        let rank = (1...15).first { assets.string(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", $0)))?.lowercased() == rivalName.lowercased() } ?? 1
        showCarWon(carName: carName, rivalName: rivalName, rivalRank: rank, onContinue: onContinue)
    }

    func showCarWon(carName: String, rivalName: String, rivalRank: Int, onContinue: @escaping () -> Void) {
        dismissScreens()
        guard let s = push("Showcase") else { onContinue(); return }
        let p = s.pkg
        // Nombre del coche en grande; la firma del rival (RIVAL_%02d_GRAF) y la marca (CARSELECT_MANUFACTURER_<marca>) [I]
        for o in p.findAll(0xc4324ea7) + p.findAll(0x7c4f7112) { p.printf(o, carName) }
        for o in p.findAll(0x9aefdacb) + p.findAll(0x9f53fd1d) { p.setVisible(o, false) }
        _ = rivalName
        for o in p.all where o.handle == feHash("RIVAL_01_GRAF") { o.handle = feHash(String(format: "RIVAL_%02d_GRAF", max(1, min(15, rivalRank)))) }
        let brand = feHash("CARSELECT_MANUFACTURER_" + (carName.split(separator: " ").first.map(String.init) ?? ""))
        for o in p.all where o.handle == feHash("CARSELECT_MANUFACTURER_Mitsubishi") {
            if assets.hasTexture(brand) { o.handle = brand } else { p.setVisible(o, false) }
        }
        enterModal(s, accept: { [weak self] in self?.closeModal(s, then: onContinue) }, back: nil)
    }

    func dismissScreens() {
        if state == .modal { screens.removeAll(); state = .game; modalAccept = nil; modalBack = nil; modalUpDown = nil }
    }

    // MARK: Modal

    func enterModal(_ s: FEScreen, accept: (() -> Void)?, back: (() -> Void)?, upDown: ((Int) -> Void)? = nil) {
        state = .modal
        modalAccept = accept; modalBack = back ?? accept; modalUpDown = upDown
    }
    func closeModal(_ s: FEScreen, then: @escaping () -> Void) {
        modalAccept = nil; modalBack = nil; modalUpDown = nil
        s.leave { [weak self] in
            self?.screens.removeAll { $0 === s }
            if self?.screens.isEmpty == true { self?.state = .game }
            then()
        }
    }

    private func printDeep(_ p: FEPackageRT, _ o: FEObj?, _ text: String) {
        guard let o else { return }
        if o.type == 2 { p.printf(o, text) }
        for c in o.children { printDeep(p, c, text) }
    }

    // MARK: Fin de persecución

    /// Arresto: «ARRESTADO» lo pone el HUD; encima, la cámara de la policía (BUSTED_OVERLAY) unos segundos.
    /// Evasión: PostRace_MilestoneRewards con la duración y la recompensa; ✕ para seguir.
    func pursuitOutcome(_ i: HudInput) {
        defer { lastOutcome = (i.bustedCount, i.evadedCount) }
        guard let last = lastOutcome, state == .game else { return }
        // El mensaje ARRESTADO sale al instante (HUD); la película del arresto con la cámara de la policía empieza después y
        // con ella el HUD se apaga (DetermineHudFeatures devuelve 0 con un NIS activo [D]) [I: 1 s]
        if i.bustedCount > last.busted { pendingBust = (1000, lastPursuit.seconds) }
        else if i.evadedCount > last.evaded { showEvaded(seconds: lastPursuit.seconds, bounty: lastPursuit.bounty) }
        if i.inPursuit { lastPursuit = (i.pursuitSeconds, i.costToState) }
    }

    /// Cuenta atrás de la película del arresto (ms) y duración de la persecución.
    func tickPendingBust(ms: Int) {
        guard var pb = pendingBust else { return }
        pb.ms -= ms
        if pb.ms <= 0 { pendingBust = nil; showBustedOverlay(seconds: pb.seconds) } else { pendingBust = pb }
    }

    func showBustedOverlay(seconds: Float) {
        guard let s = FEPackageRT(name: "BUSTED_OVERLAY", assets: assets).map({ FEScreen(pkg: $0) }) else { return }
        let p = s.pkg
        p.stretch = true
        for o in p.all where o.findScript(FEH.appear) != nil && o.script?.id == FEH.initScript { p.setScript(o, FEH.appear) }
        // FeBustedOverlay: ficha del sospechoso con la duración de la persecución e infracciones (texto 0x626ac043) [D]
        if let fmt = assets.string(0x626ac043), let t = p.find(0xf1ed545a) {
            var out = fmt
            if let r = out.range(of: "%s") { out.replaceSubrange(r, with: FEHud.timeString(Double(seconds))) }
            out = out.replacingOccurrences(of: "%d", with: "\(max(1, engine.ai?.police.infractions.count ?? 1))")
            p.printf(t, out)
        }
        overlays.append((s, 3000))
    }

    func showEvaded(seconds: Float, bounty: Int) {
        guard let s = push("PostRace_MilestoneRewards") else { return }
        let p = s.pkg
        // StartBountyAnimations(false): icono de la persecución (POS0), «Duración de la persecución», recompensa y total [D]
        let icon = p.find(0x14564FB9)
        icon?.handle = feHash("MILESTONE_PURSUIT_DURATION")
        p.printf(p.find(0xe526d0d2), "\(assets.string(0x4d64888d) ?? "") \(FEHud.timeString(Double(seconds)))")
        p.setVisible(p.find(0xe1045a4f), bounty > 0)
        p.printf(p.find(0xe1045a4f), "\(assets.string(0x29b1b96a) ?? ""): \(FEHud.money(bounty))")
        p.printf(p.find(0x324f7792), "\(assets.string(0x5ccf949a) ?? ""): \(FEHud.money(bounty))")
        p.setScript(icon, FEH.appear)
        // FEMSG_SCREEN_TICK: al acabar APPEAR, el icono grande vuela a su hueco de la tira (POS0 = recompensa) [D]
        let pos0 = feHash("POS0")
        s.tick = { [weak icon, weak p] in
            guard let icon, let p, let sc = icon.script, sc.id == FEH.appear, icon.time > sc.length else { return }
            p.setScript(icon, pos0)
        }
        enterModal(s, accept: { [weak self] in self?.closeModal(s) {} }, back: nil)
    }
}

// MARK: - Escenarios de prueba (--ui-test HUD-chase, Race-circuit, Results, Blacklist…)

extension FEUI {
    func startScenario(_ name: String) {
        hudScenario = name
        let n = name.lowercased()
        let names = ["Razor", "Ronnie", "Bull", "Earl"]
        func racers(_ k: Int) -> [RaceHUDRacer] {
            (0..<k).map { i in RaceHUDRacer(name: i == 1 ? (es ? "Jugador" : "Player") : names[i % names.count], isPlayer: i == 1, gap: Float(60 - i * 45), position: i + 1) }
        }
        switch n {
        case let x where x.hasPrefix("race-"):
            let kind: RaceKind = x.contains("sprint") ? .sprint : x.contains("drag") ? .drag : x.contains("knockout") ? .knockout
                : x.contains("speedtrap") ? .speedtrap : x.contains("tollbooth") ? .tollbooth : .circuit
            var setup = RaceHUDSetup(kind: kind, laps: kind == .circuit || kind == .knockout ? 3 : 1, racers: racers(4))
            setup.eventID = kind == .sprint ? "1.2.1" : kind == .tollbooth ? "1.5.1" : kind == .speedtrap ? "1.4.1" : "1.1.1"
            setup.checkpointCount = kind == .tollbooth ? 6 : kind == .speedtrap ? 5 : 0
            beginRace(setup)
            setPosition(2, of: 4); setLap(2, of: setup.laps); setTimer(raceTime: 83.47, lapTime: 41.2, bestLap: 40.9); setProgress(46)
            setSpeedtrap(totalMps: 92, passed: 2, of: setup.checkpointCount)
            if let c = engine.car {
                let f = c.forward
                setRacerBlips([c.position + f * 60 + SIMD3(4, 0, 0), c.position - f * 40])
                setNextCheckpoint(c.position + f * 180)
            }
            if x.contains("countdown") { showCountdown(x.hasSuffix("go") ? 0 : 3) }
            if x.contains("wrongway") { showMessage(.wrongWay(true)) }
            if x.contains("final") { showMessage(.finalLap) }
            if x.contains("toll") { showMessage(.tollbooth(timeAdded: 12.5)) }
            if kind == .drag { setDrag(shiftQuality: 2, engineTemp: 0.3) }
        case "results":
            showResults(RaceResults(kind: .circuit, playerWon: true, rows: [
                RaceResultRow(position: 1, name: es ? "Jugador" : "Player", isPlayer: true, totalTime: 203.41, bestLap: 66.2),
                RaceResultRow(position: 2, name: "Razor", totalTime: 205.88), RaceResultRow(position: 3, name: "Bull", totalTime: 211.02),
                RaceResultRow(position: 4, name: "Earl", totalTime: nil)]), onContinue: {})
        case "blacklist":
            var rivals: [BlacklistRival] = []
            for r in 1...15 {
                rivals.append(BlacklistRival(rank: r, name: "", racesWon: r == 15 ? 3 : 0, racesRequired: 3, milestonesDone: r == 15 ? 1 : 0,
                                             milestonesRequired: 2, bounty: 12_750, bountyRequired: 10_000, defeated: false, unlocked: false))
            }
            showBlacklist(rivals, selected: 15) { _ in }
        case "carwon":
            showCarWon(carName: "Mitsubishi Lancer Evolution VIII", rivalName: "Kaze", rivalRank: 9) {}
        default: break
        }
    }

    /// Datos de ejemplo del HUD para las capturas.
    func scenarioInput(_ name: String, _ base: HudInput) -> HudInput {
        var i = base
        let n = name.lowercased()
        i.rpm = max(i.rpm, 6100); i.speed = max(i.speed, 41.7); i.gear = max(i.gear, 5); i.nos = 0.7; i.speedBreaker = 1
        let pp = i.playerPos ?? .zero, d = i.playerDir, side = SIMD2(-d.y, d.x)
        func cop(_ fwd: Float, _ lat: Float, _ chasing: Bool) -> HudBlip { HudBlip(pos: pp + d * fwd + side * lat, dir: d, inPursuit: chasing) }
        switch n {
        case "hud-free":
            i.heat = 1.6
            i.cops = [cop(220, 30, false), cop(-150, -60, false)]
            i.radarRange = 0.6; i.radarDirection = 0.4
        case "hud-chase", "hud-busted":
            i.heat = 3.4; i.inPursuit = true; i.pursuitSeconds = 83.4
            i.timeUntilBusted = n == "hud-busted" ? 0.9 : 0.3
            i.copsEngaged = 4; i.copsDestroyed = 2; i.copsDamaged = 3; i.costToState = 12_750; i.timeUntilBackup = 24
            i.cops = [cop(-25, 3, true), cop(-60, -4, true), cop(140, 20, true), cop(-300, 0, true)]
            if n == "hud-busted" { i.speed = 0; i.rpm = 1000; i.gear = 1; i.bustedCount = scenarioFrames > 30 ? 1 : 0 }
        case "hud-cooldown":
            i.heat = 3.7; i.inPursuit = true; i.cooldown = true; i.pursuitSeconds = 131; i.timeUntilBusted = -1
            i.cooldownRequired = 60; i.cooldownRemaining = 22; i.copsEngaged = 3; i.costToState = 18_400
            i.cops = [cop(-420, 60, true), cop(380, -200, true)]
        case "hud-evaded":
            i.heat = 2.9; i.inPursuit = scenarioFrames <= 30; i.pursuitSeconds = 147.3; i.costToState = 21_250
            i.timeUntilBusted = -1; i.cooldown = true; i.cooldownRemaining = 0
            i.evadedCount = scenarioFrames > 30 ? 1 : 0
        default:
            i.heat = 1.3
        }
        scenarioFrames += 1
        return i
    }
}
