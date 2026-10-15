// Pantallas de la carrera rápida con los paquetes del juego: Track_Select, Track_Options y Car_Select.
// Hashes de objetos y textos: los de uiQRTrackSelect.cpp, uiQRTrackOptions.cpp, feUIWidgetMenu.cpp, feWidget.cpp,
// uiQRCarSelect.cpp y Slider.cpp [D]. Lo que la decomp no resuelve lleva [I].
import Foundation
import simd

// MARK: - Track_Select (UIQRTrackSelect)

final class QRTrackSelect: QRScreen {
    private var tracks: [QRTrack] = []
    private var index = 0
    private var map: FEObj?
    // Zoom y paneo del mapa: AnimateCubic de 1 s hacia la caja de la prueba (UITrackMapStreamer [D])
    private var from = SIMD4<Float>(0, 0, 1, 1), to = SIMD4<Float>(0, 0, 1, 1), t: Float = 1

    init?(flow: QuickRaceFlow) {
        super.init(flow: flow, package: "Track_Select")
        map = pkg.find("TRACK_MAP")
        label(0xB71B576D, QuickRaceData.trackSelectTitle(flow.mode))       // __TITLE_GROUP__
        // Online: fuera (botones de amigos, correo, EA Online)
        show(0x7C430E80, false)
        rebuild(keep: flow.settings.eventByMode[flow.mode.rawValue])
    }

    private func rebuild(keep: String?) {
        guard let sys = RaceSystem.shared else { return }
        tracks = QuickRaceData.tracks(db: sys.db, mode: flow.mode, region: flow.settings.region, save: Career.shared.save)
        index = tracks.firstIndex { $0.event.id == keep || $0.event.eventId == keep } ?? 0
        refresh(animate: false)
    }

    private var current: QRTrack? { tracks.isEmpty ? nil : tracks[index] }

    /// RefreshHeader [D].
    private func refresh(animate: Bool = true) {
        let rn = QRSettings.regionNames[max(0, min(3, flow.settings.region))]
        label(0x78008599, rn); label(0x4510987F, rn)
        text(0x6F25A248, "\(tracks.isEmpty ? 0 : index + 1)")
        text(0xB2037BDC, "\(tracks.count)")
        label(0xB5154998, QuickRaceData.modeName(flow.mode))
        obj(0x08007B4C)?.handle = QuickRaceData.modeIcon(flow.mode)
        guard let tr = current else {
            text(0x5E7B09C9, ""); text(0x0DFB7A2E, ""); text(0xB5154999, "--")
            text(0xB515499C, str(0x472AA00A, "--:--.--"))
            show(0x6B67D70B, false); show(0xE08434FC, false); pkg.setVisible(map, false)
            return
        }
        let e = tr.event
        show(0x6B67D70B, tr.locked); show(0xE08434FC, !tr.locked)
        if tr.locked {
            let rival = str(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", tr.bin)), "Rival \(tr.bin)")
            let fmt = str(0xBD563BE5, "Desbloquea esta pista^al derrotar a %s,^miembro %d de la Blacklist.")
            text(0x68215623, fmt.replacingOccurrences(of: "%s", with: rival).replacingOccurrences(of: "%d", with: "\(tr.bin)"))
        }
        let name = QuickRaceData.trackName(e, assets: ui.assets)
        text(0x5E7B09C9, name); text(0x0DFB7A2E, name)
        show(0xBBF970CD, false)
        let km = !(ui.assets.language == "english")
        let len = e.length
        text(0xB5154999, String(format: "%.1f %@", len * (km ? 0.001 : 0.000621371), str(km ? 0x8569A26A : 0x867DCFD9, km ? "km" : "mi")))
        // Mejor tiempo (GRaceSaveInfo): el de la partida guardada si lo hay
        if let best = Career.shared.save.bestTimes[e.id] { text(0xB515499C, FEHud.timeString(best)) }
        else { text(0xB515499C, str(0x472AA00A, "--:--.--")) }
        if e.kind == .circuit || e.kind == .knockout { label(0x28462C64, 0xC5B5A177) }    // «Vuelta rápida:»
        else { label(0x28462C64, 0x5D40B809) }                                          // «Mejor tiempo:»
        // Mapa: TRACK_MAP_<id> (UITrackMapStreamer::CalcMapTextureHash) con zoom a la caja de la prueba
        if let m = map {
            m.handle = QuickRaceData.mapTexture(e)
            pkg.setVisible(m, ui.assets.hasTexture(m.handle))
            from = currentUV; to = bounds(e); t = animate ? 0 : 1
            if !animate { from = to }
            applyUV()
        }
    }

    /// CalcBoundsForRace [D]: caja de la prueba en coordenadas del mapa con 0,125 de margen, cuadrada (UpdateMap).
    private func bounds(_ e: RaceEvent) -> SIMD4<Float> {
        guard let c = ui.assets.minimaps?.calibration else { return SIMD4(0, 0, 1, 1) }
        var pts: [RaceMarker] = e.checkpoints
        if let s = e.start { pts.append(s) }
        if let f = e.finish { pts.append(f) }
        pts += e.speedtraps.map { RaceMarker(name: nil, pos: [$0.p.x, $0.p.y, $0.p.z], yaw: 0, dims: nil, timeBonus: nil, radius: nil, width: nil) }
        guard !pts.isEmpty else { return SIMD4(0, 0, 1, 1) }
        // Misma conversión que el radar (Minimap::ConvertPos): el mapa de pista es el mismo plano de la ciudad [I]
        let mp = pts.map { SIMD2(($0.p.x - c.upperLeft[0]) / c.widthMetres, (c.upperLeft[1] - $0.p.y) / c.widthMetres + 1) }
        let lo = mp.reduce(SIMD2<Float>(1e9, 1e9)) { simd_min($0, $1) } - 0.125
        let hi = mp.reduce(SIMD2<Float>(-1e9, -1e9)) { simd_max($0, $1) } + 0.125
        let ctr = (lo + hi) / 2, half = max(hi.x - lo.x, hi.y - lo.y) / 2
        return SIMD4(ctr.x - half, ctr.y - half, ctr.x + half, ctr.y + half)
    }

    private var currentUV: SIMD4<Float> {
        guard let m = map, m.data.count > 20 else { return SIMD4(0, 0, 1, 1) }
        return SIMD4(m.data[17], m.data[18], m.data[19], m.data[20])
    }

    private func applyUV() {
        guard let m = map, m.data.count > 20 else { return }
        let s = t * t * (3 - 2 * t)
        let v = from + (to - from) * s
        m.locked.formUnion(17...20)
        m.data[17] = v.x; m.data[18] = v.y; m.data[19] = v.z; m.data[20] = v.w
    }

    override func update(dt: Float) {
        if t < 1 { t = min(1, t + dt); applyUV() }
    }

    override func handle(_ m: MenuButtons) {
        if m.left || m.right, !tracks.isEmpty {
            index = (index + (m.right ? 1 : -1) + tracks.count) % tracks.count
            refresh()
        } else if m.up || m.down {
            // ScrollRegions (L1/R1 en el juego) [D]
            let r = flow.settings.region
            flow.settings.region = m.down ? (r == 3 ? 0 : r + 1) : (r == 0 ? 3 : r - 1)
            rebuild(keep: current?.event.id)
        } else if m.accept || m.start, let tr = current, !tr.locked {
            flow.settings.eventByMode[flow.mode.rawValue] = tr.event.id
            pkg.post(0x2E76EDFB)
            flow.leave { [weak flow] in flow?.afterTrackSelect() }
        } else if m.back {
            flow.leave { [weak flow] in flow?.showModeSelect() }
        }
    }
}

// MARK: - Track_Options (UIQRTrackOptions + UIWidgetMenu)

final class QRTrackOptions: QRScreen {
    /// Una fila FEToggleWidget: título, valor y qué hacer con ◀ ▶.
    struct Row { let title: UInt32?; let titleText: String?; let value: () -> String; let change: (Int) -> Void; var enabled = true }
    private var rows: [Row] = []
    private var cur = 0
    private var startY: Float = 0, rowH: Float = 24
    private var event: RaceEvent?

    init?(flow: QuickRaceFlow) {
        super.init(flow: flow, package: "Track_Options")
        if let id = flow.settings.eventByMode[flow.mode.rawValue] { event = RaceSystem.shared?.db.event(id) }
        // Cabecera: «opciones» del tipo de prueba (UIQRTrackOptions::Setup [D]); los textos del título van con texto propio
        // (bandera 2), así que se escriben con FEPrintf [V: Track_Options.fng]
        text(0xB71B576D, str(QuickRaceData.optionsTitle(flow.mode), "opciones"))
        // «Por defecto» (○ en el juego, DefaultRaceSettings): ○ vuelve atrás en este port
        show(0xD9A22505, false); show(0x28B8FD2F, false)
        show(0x7C430E80, false)
        buildRows()
        layout()
        select(0)
    }

    private func onOff(_ b: Bool) -> String { str(b ? 0x417B2604 : 0x70DFE5C2, b ? "Sí" : "No") }

    /// SetupCircuit / SetupSprint / … [D] y las filas de la extensión (pantalla partida: rivales, tráfico; policía siempre).
    private func buildRows() {
        let s = flow
        let k = flow.mode
        let reversible = event.flatMap { e in RaceSystem.shared.flatMap { QuickRaceData.reversed(e, db: $0.db) } } != nil
        if reversible {
            rows.append(Row(title: 0xA88FFEB4, titleText: nil, value: { [unowned self] in self.str(s.settings.reverse ? 0xA1CD823E : 0xDE6EFF34, s.settings.reverse ? "Hacia atrás" : "Adelante") },
                            change: { _ in s.settings.reverse.toggle() }))
        }
        if k == .circuit {
            rows.append(Row(title: 0x48494E83, titleText: nil, value: { "\(s.settings.laps)" },
                            change: { d in s.settings.laps = (s.settings.laps - 1 + d + 8) % 8 + 1 }))
        }
        if k != .drag {
            rows.append(Row(title: 0xEB9DFC09, titleText: nil, value: { [unowned self] in
                self.str([0x8CDC3937, 0x73C615A3, 0xA2CCA838, 0x61D1C5A5][s.settings.traffic], ["Ninguno", "Mínimo", "Moderado", "Máximo"][s.settings.traffic]) },
                            change: { d in s.settings.traffic = (s.settings.traffic + d + 4) % 4 }))
        }
        if k != .tollbooth {
            // NumOpponents [D]: 1…(4 − jugadores); en pantalla partida (extensión) 0…(4 − jugadores)
            let maxOpp = max(0, min(event?.opponents.count ?? 3, 4 - s.players))
            let minOpp = s.split ? 0 : 1
            s.settings.opponents = max(minOpp, min(maxOpp, s.settings.opponents))
            if maxOpp >= minOpp {
                rows.append(Row(title: 0x3384A679, titleText: nil, value: { "\(s.settings.opponents)" }, change: { d in
                    var o = s.settings.opponents + d
                    if o < minOpp { o = maxOpp } else if o > maxOpp { o = minOpp }
                    s.settings.opponents = o
                }))
                rows.append(Row(title: 0x4D156786, titleText: nil, value: { [unowned self] in
                    self.str([0x61973E01, 0x3747F6D0, 0x6198E2EE][s.settings.skill], ["Fácil", "Medio", "Difícil"][s.settings.skill]) },
                                change: { d in s.settings.skill = (s.settings.skill + d + 3) % 3 }))
                rows.append(Row(title: 0x8B8E913A, titleText: nil, value: { [unowned self] in self.onOff(s.settings.catchUp) }, change: { _ in s.settings.catchUp.toggle() }))
            }
        }
        // Extensión del port: policía en la carrera rápida (el juego la desactiva siempre)
        rows.append(Row(title: nil, titleText: es ? "Policía" : "Police", value: { [unowned self] in self.onOff(s.settings.police) }, change: { _ in s.settings.police.toggle() }))
    }

    /// UIWidgetMenu::SetInitialPositions / Reposition [D]: filas desde la esquina de TITLEMASTER, una por altura de título.
    private func layout() {
        let tm = obj(0xA753C46C), dm = obj(0xC128B184)
        pkg.setVisible(tm, false); pkg.setVisible(dm, false)
        if let tm { startY = abs(tm).y - tm.size.y / 2; rowH = tm.size.y }
        for i in 1...9 {
            let on = i <= rows.count
            for n in ["OPTION_NAME_\(i)", "OPTION_DATA_\(i)", "LEFT_ARROW_\(i)", "RIGHT_ARROW_\(i)"] {
                guard let o = pkg.find(n) else { continue }
                pkg.setVisible(o, on)
                if on { setAbsY(o, startY + Float(i - 1) * rowH + rowH / 2) }
            }
        }
        draw()
    }

    private func abs(_ o: FEObj) -> SIMD2<Float> {
        var p = SIMD2(o.pos.x, o.pos.y), q = o.parent
        while let g = q { p += SIMD2(g.pos.x, g.pos.y); q = g.parent }
        return p
    }
    private func setAbsY(_ o: FEObj, _ y: Float) {
        let parentY = o.parent.map { abs($0).y } ?? 0
        o.pos = SIMD3(o.pos.x, y - parentY, o.pos.z)
    }

    private func draw() {
        for (i, r) in rows.enumerated() {
            let n = i + 1
            if let t = pkg.find("OPTION_NAME_\(n)") { if let h = r.title { pkg.setLabel(t, h) } else { pkg.printf(t, r.titleText ?? "") } }
            pkg.printf(pkg.find("OPTION_DATA_\(n)"), r.value())
        }
    }

    /// SetFocus / UnsetFocus [D]: HIGHLIGHT en la fila elegida; el cursor va a POS<n>.
    private func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        cur = (i + rows.count) % rows.count
        for (k, _) in rows.enumerated() {
            let script = feHash(k == cur ? "HIGHLIGHT" : "UNHIGHLIGHT")
            for n in ["OPTION_NAME_\(k + 1)", "OPTION_DATA_\(k + 1)", "LEFT_ARROW_\(k + 1)", "RIGHT_ARROW_\(k + 1)"] { pkg.setScript(pkg.find(n), script) }
        }
        if let c = obj(0x06745352) { pkg.setScript(c, feHash("POS\(cur + 1)")) }
    }

    override func handle(_ m: MenuButtons) {
        if m.up { select(cur - 1) }
        else if m.down { select(cur + 1) }
        else if m.left || m.right, cur < rows.count {
            rows[cur].change(m.right ? 1 : -1)
            draw()
        } else if m.accept || m.start {
            QuickRaceData.saveSettings(flow.settings)
            flow.leave { [weak flow] in flow?.afterOptions() }
        } else if m.back {
            flow.leave { [weak flow] in flow?.showTrackSelect() }
        }
    }
}

// MARK: - Car_Select (UIQRCarSelect)

final class QRCarSelect: QRScreen {
    let player: Int
    private var all: [QRCar] = []
    private var lists: [QRCar.List] = [.stock, .career, .bonus]
    private var listIndex = 0
    private var index = 0
    private var orbit: Float = 0

    override var owner: PlayerDevice? { flow.split && player < flow.joined.count ? flow.joined[player] : nil }

    init?(flow: QuickRaceFlow, player: Int) {
        self.player = player
        super.init(flow: flow, package: "Car_Select")
        guard let e = flow.engine else { return nil }
        all = QuickRaceData.cars(data: e.data, assets: ui.assets, save: Career.shared.save)
        lists = lists.filter { l in all.contains { $0.list == l } }
        // Elegido antes por este jugador (o el de la historia)
        let want = player < flow.chosen.count ? flow.chosen[player] : (player < flow.settings.cars.count ? flow.settings.cars[player] : "M3GTRCAREERSTART")
        if let c = all.first(where: { $0.id == want }), let li = lists.firstIndex(of: c.list) {
            listIndex = li; index = cars.firstIndex { $0.id == want } ?? 0
        }
        if ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_QR"] != nil {
            print("Car_Select J\(player + 1): \(all.count) coches · listas \(lists) · elegido \(want) → lista \(listIndex) índice \(index)")
            for c in all { print("  \(c.list) \(c.id) «\(c.name)» \(c.locked ? "bloqueado" : "") at=\(c.unlockedAt ?? -1) bin=\(Career.shared.save.currentBin)") }
        }
        // Carrera rápida: sin dinero, sin calor, sin multas ni depósito (UIQRCarSelect + QRCarSelectBustedManager [D])
        for h: UInt32 in [0x19398802, 0x1930B057, 0x20D113DC, 0x20C83C31, 0x39DC21F9, 0xE998FE99, 0x64F3A49C, 0x8CBE830C,
                          0x72E7EA88, 0x9D974DF3, 0x322B18F9, 0x7044A5A4, 0xBDE6E3BA, 0xFBEAE195, 0x97315444, 0x4ED1E692] { show(h, false) }
        show(0x7C430E80, false)
        // Sombras de los rótulos de las barras: el APPEAR genérico de la interfaz las pone blancas; vuelven a su INIT (negras)
        for h: UInt32 in [0x97F09EEE, 0x246005C0, 0xBC4DA0CF] { for o in pkg.findAll(h) { pkg.setScript(o, FEH.initScript) } }
        // Sin vitrina, sin vender ni cargar coches (Showcase, Sell Car, Load Cars: Mis coches)
        for h: UInt32 in [0x0E9ED0A2, 0x18A4384F, 0xD42F677B, 0x5F34A28C] { show(h, false) }
        // Jugador N (pantalla partida): FEObj_PLAYER_TEXT_GROUP [D]
        if flow.split {
            let g = obj(0xE3FE27FE)
            pkg.setVisible(g, true)
            if player < 2 { label(0xE3FE27FE, player == 0 ? 0x7B070984 : 0x7B070985) }
            else { for o in pkg.findAll(0x42EF4C2E) { pkg.printf(o, (es ? "Jugador " : "Player ") + "\(player + 1)") } }
        } else { show(0xE3FE27FE, false) }
        refresh()
    }

    private var cars: [QRCar] { all.filter { $0.list == lists[listIndex] } }
    private var current: QRCar? { cars.isEmpty ? nil : cars[min(index, cars.count - 1)] }

    /// RefreshHeader [D].
    private func refresh() {
        let l = lists[listIndex]
        let (lang, tex): (UInt32, UInt32) = switch l {
        case .stock: (0xD9D6B954, 0x3A541F7F)
        case .career: (0xEE053562, 0xF0BDDECD)
        case .bonus: (0xD8A058F7, 0xBE5AD8A2)
        }
        label(0xAA9834BC, lang)
        obj(0xE3B271B8)?.handle = tex
        text(0x6F25A248, "\(cars.isEmpty ? 0 : index + 1)")
        text(0xB2037BDC, "\(cars.count)")
        guard let c = current else { show(0x4ED1E692, true); return }
        show(0x4ED1E692, false)
        pkg.setScript(obj(0xD0F7C7CC), c.locked ? 0x1CA7C0 : FEH.hide)
        if c.locked, let t = c.bonusText { text(0x2D25B2C4, str(t, "")) }
        else if c.locked, let bin = c.unlockBin {
            let rival = str(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", bin)), "Rival \(bin)")
            let fmt = str(0x4EF2A115, "Desbloquea este coche derrotando a %s, nº %d de la Blacklist.")
            text(0x2D25B2C4, fmt.replacingOccurrences(of: "%s", with: rival).replacingOccurrences(of: "%d", with: "\(bin)"))
        }
        obj(0x3E01AD1D)?.handle = feHash("GENERIC_LOGO_128")
        obj(0xB05DD708)?.handle = c.logo
        // Nombre del coche (en el juego aparece al cargar el modelo: FADE_IN_TEXT)
        // (el paquete trae un segundo CARNAME con «Debug:»: solo el primero)
        for (k, o) in pkg.findAll(0xD6D32016).enumerated() { pkg.setVisible(o, k == 0); if k == 0 { pkg.printf(o, c.name) } }
        pkg.post(0x9C0A27EB)
        // Barras de aceleración, punta y manejo (TwoStageSlider, ancho 160 [D])
        for (k, n) in ["ACCELERATION", "TOPSPEED", "HANDLING"].enumerated() { slider(n, c.stats[k]) }
        if let e = flow.engine { QRCarPreview.shared.show(c.id, engine: e) }
    }

    /// cSlider::Draw [D]: la barra (LED_main, una celda cada 32 unidades: FEngSetBottomRightU) crece desde el borde izquierdo
    /// de BASE_<n> hasta 160 × valor. En Car_Select el editor ya deja la barra a la altura de la base [V], así que solo se
    /// cambian el ancho, el U y la posición en X; el marcador (HANDLE) va al final de la barra [I].
    private func slider(_ name: String, _ v: Float) {
        guard let base = pkg.find("BASE_\(name)") else { return }
        let left = base.pos.x - Swift.abs(base.size.x) / 2
        let w = 160 * max(0.02, min(1, v))
        for n in ["FILLBAR_\(name)", "PREVIEWBAR_\(name)"] {
            guard let b = pkg.find(n) else { continue }
            b.size = SIMD3(w, b.size.y, b.size.z)
            b.pos = SIMD3(left + w / 2, base.pos.y, b.pos.z)
            if b.data.count > 20 { b.locked.formUnion([19]); b.data[19] = w / 32 }
        }
        if let hd = pkg.find("HANDLE_\(name)") { hd.pos = SIMD3(left + w, base.pos.y, hd.pos.z) }
    }

    override func update(dt: Float) {
        // Vitrina: el coche en la calle del refugio con la cámara girando despacio [diseño propio: el juego lo pone en el garaje]
        orbit += dt * 0.35
        QRCarPreview.shared.camera(engine: flow.engine, angle: orbit)
    }

    override func handle(_ m: MenuButtons) {
        if m.left || m.right, !cars.isEmpty {
            index = (index + (m.right ? 1 : -1) + cars.count) % cars.count
            refresh()
        } else if m.up || m.down, lists.count > 1 {
            listIndex = (listIndex + (m.down ? 1 : -1) + lists.count) % lists.count
            index = 0
            refresh()
        } else if m.accept || m.start, let c = current, !c.locked {
            while flow.chosen.count <= player { flow.chosen.append(c.id) }
            flow.chosen[player] = c.id
            let next = player + 1
            if flow.split && next < flow.joined.count { flow.leave { [weak flow] in flow?.showCarSelect(player: next) } }
            else { flow.leave { [weak flow] in flow?.startRace() } }
        } else if m.back {
            let prev = player - 1
            if player > 0 { flow.leave { [weak flow] in flow?.showCarSelect(player: prev) } }
            else if flow.split { flow.leave { [weak flow] in QRCarPreview.shared.restore(flow?.engine); flow?.showJoin() } }
            else { flow.leave { [weak flow] in QRCarPreview.shared.restore(flow?.engine); flow?.showTrackOptions() } }
        }
    }
}

/// Coche de la vitrina en Car_Select: se monta una vez por modelo y se aparca en el refugio.
final class QRCarPreview {
    static let shared = QRCarPreview()
    private var cache: [String: Car] = [:]
    private var shown: String?
    private var saved: Car?
    private var spot = SIMD3<Float>(1700, 2300, 40), yaw: Float = 0

    func show(_ id: String, engine: Engine) {
        if shown == nil { saved = engine.car }
        if let z = engine.data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 {
            spot = SIMD3(r.position[0], r.position[1], r.position[2]); yaw = (r.rotation ?? 0) * .pi / 180
        }
        if shown == id, engine.car === cache[id] { return }
        guard let car = cache[id] ?? MultiplayerRace.makeCar(engine: engine, id: id) else { return }
        cache[id] = car
        car.place(spot, yaw: yaw, collision: engine.collision)
        engine.car = car
        shown = id
    }

    /// Cámara de la vitrina (después de la de los menús, que gira sobre la ciudad).
    func camera(engine: Engine?, angle: Float) {
        guard let e = engine, let car = e.car, shown != nil else { return }
        let a = car.yaw + 0.9 + angle
        let c = car.position + SIMD3(0, 0, 0.7)
        e.camPos = c + SIMD3(cos(a), sin(a), 0) * 6.2 + SIMD3(0, 0, 1.1)
        let d = simd_normalize(c - e.camPos)
        e.yaw = atan2(d.y, d.x); e.pitch = asin(max(-1, min(1, d.z)))
    }

    /// Vuelve a poner el coche que había (al salir de la selección hacia atrás).
    func restore(_ engine: Engine?) {
        guard let e = engine, shown != nil else { return }
        e.car = saved
        shown = nil; saved = nil
    }

    func clear() { shown = nil; saved = nil; cache.removeAll() }
}
