// HUD del juego con el paquete original HUD_SingleRace.fng y la lógica de sus elementos [D: Frontend/HUD/*.cpp]:
//   Tachometer (aguja, marcha, luz de cambio), Speedometer (tres dígitos), NitrousGauge, HeatMeter, PursuitBoard (barra
//   EVADE/BUSTED, enfriamiento, policías, tiempo) y SpeedBreakerMeter. Cada elemento registra sus objetos y se muestra u
//   oculta con la máscara de rasgos (DetermineHudFeatures) como FEngHud::SetHudFeatures.
// Los datos salen del coche (Car) y de la policía (PoliceManager): la misma API que usaba el HUD propio (HUDPursuit.swift).
import Foundation
import simd

/// Valores que el juego entrega al HUD cada fotograma.
struct HudInput {
    var speed: Float = 0             // m/s
    var rpm: Float = 0, redline: Float = 7000, maxRpm: Float = 8000
    var gear = 1                     // 0 = R, 1 = N, 2… = 1.ª…
    var shifting = false
    var nos: Float = 1               // 0…1
    var nosEngaged = false
    var heat: Float = 1
    var inPursuit = false
    var cooldown = false
    /// −1…1: positivo hacia BUSTED, negativo hacia EVADE; ≤ −1 = enfriamiento (PursuitBoard::SetTimeUntilBusted) [D].
    var timeUntilBusted: Float = 0
    var cooldownRemaining: Float = 60, cooldownRequired: Float = 60
    var pursuitSeconds: Float = 0
    var copsEngaged = 0, copsDestroyed = 0, copsDamaged = 0
    var costToState = 0
    var kmh = true                   // castellano: km/h (LanguageHasChanged pone SpeedoUnits = 1 si no es inglés) [D]
}

final class FEHud {
    let pkg: FEPackageRT
    private final class Element {
        let mask: UInt64
        var objects: [FEObj] = []
        init(_ m: UInt64) { mask = m }
    }
    private var elements: [String: Element] = [:]
    private var features: UInt64 = 0
    private var needleWidth: Float = 32
    private var maxRpmTexture: Float = 8000
    private var lastNos: Float = -1
    private var barWidths: [Float] = []
    private var coolWidth: Float = 216

    // Objetos
    private let needle, redline, shiftLight, gearString, tachLines, tachBack: FEObj?
    private let digits: [FEObj?]
    private let speedUnits: FEObj?
    private let nosIcon, nosBar: FEObj?
    private let heatMult, heatIcon, heatBar, heatBar2: FEObj?
    private let pbGroup, pmGroup, piGroup, psGroup, pcGroup, backupGroup: FEObj?
    private let pursuitTimer, copsNumbers, copsTakenOut, copsDamaged, summaryTotal: FEObj?
    private let bustedBars: [FEObj?]
    private let coolBar, backupBacking, hidingBacking: FEObj?
    private let ctsString: FEObj?

    init?(assets: FEAssets) {
        guard let p = FEPackageRT(name: "HUD_SingleRace", assets: assets) else { return nil }
        pkg = p
        func f(_ s: String) -> FEObj? { p.find(s) }
        func h(_ x: UInt32) -> FEObj? { p.find(x) }
        needle = f("3rdPersonNeedle"); redline = f("RPM_REDLINE"); shiftLight = f("Shift_light"); gearString = f("3rdPersonGear")
        tachLines = f("TAC_Lines_7500"); tachBack = h(0x05d19f25)
        digits = [f("SPEED_DIGIT_1"), f("SPEED_DIGIT_2"), f("SPEED_DIGIT_3")]
        speedUnits = f("3rdPersonSpeedUnits")
        nosIcon = h(0x27DDF583); nosBar = h(0xEDFB6D37)
        heatMult = h(0x7F91DA62); heatIcon = h(0x6F85ED55); heatBar = h(0x862824C9); heatBar2 = h(0x4B2CBE1B)
        pbGroup = h(0xde89e070); pmGroup = h(0x7b422ba3); piGroup = h(0xe0b1430b); psGroup = h(0x8674e6d4); pcGroup = h(0x84a226ec); backupGroup = h(0x6a144066)
        pursuitTimer = h(0xfc39cb0a); copsNumbers = h(0x814918ca); copsTakenOut = h(0xa16f9f1e); copsDamaged = h(0x5fa70d4c); summaryTotal = h(0x875e92eb)
        bustedBars = [h(0xe0e0169b), h(0x8eeebd33), h(0x47a4e2a9), h(0x8e3653a6), h(0x30f39a6f)]
        coolBar = h(0xcf817638); backupBacking = h(0x8c20a763); hidingBacking = h(0x5c2a4f20)
        ctsString = nil
        needleWidth = needle?.size.x ?? 32
        barWidths = bustedBars.map { $0?.size.x ?? 0 }
        coolWidth = coolBar?.size.x ?? 216
        registerAll()
        // Texturas del HUD de serie (pack HUDS_CUSTOM_00: TACH_FILL_00, TACH_NEEDLE_00, n000_LINES_00…) [V nombres; I asignación]
        setTachTextures(maxRpm: 8000, redline: 7000)
        // Como FEngHud: todo encendido y luego apagado; los rasgos se ponen en update [D]
        apply(0xFFFFFFFF_FFFFFFFF); apply(0)
        // Partida sin conexión: fuera los datos del modo online (OnlineHUDSupport, FEObj_OnlineDATA01/02) [D]
        for h: UInt32 in [0xC18C12FD, 0xC18C12FE] { p.setVisible(p.find(h), false) }
        // Paneles de esconderse, refuerzos y enfriamiento: ocultos hasta que el juego los pida [I]
        for o in [hidingBacking, backupBacking, pcGroup] { p.setScript(o, FEH.hide) }
    }

    // MARK: Registro (HudElement::Register*)

    private func register(_ name: String, _ mask: UInt64, groups: [UInt32] = [], objects: [UInt32] = []) {
        let e = Element(mask)
        func addGroup(_ g: FEObj) { for c in g.children { if c.type == 5 { addGroup(c) } else { e.objects.append(c) } } }
        for gh in groups { if let g = pkg.find(gh), g.type == 5 { addGroup(g) } }
        for oh in objects { if let o = pkg.find(oh) { e.objects.append(o) } }
        elements[name] = e
    }

    private func registerAll() {
        let H = feHash
        register("tach", 0x2, groups: [H("GaugeCluster"), 0x045E9562])
        register("speedo", 0x8000000, groups: [H("SpeedometerGroup")])
        register("nos", 0x80000800, groups: [0x87C38E97], objects: [0xEDFB6D37])
        register("heat", 0x40004000, groups: [0xC46A80A9], objects: [0x862824C9, 0x4B2CBE1B])
        register("pursuit", 0x100000, groups: [0xde89e070, 0x7b422ba3, 0xe0b1430b, 0x8674e6d4, 0x84a226ec, 0x6a144066], objects: [0x3c165f39, 0xbee44775])
        register("speedbreaker", 0x40000, groups: [H("Speedbreaker_Meter_Group"), 0x82D60021], objects: [H("Speedbreaker_Meter_Multi_Image")])
        register("cts", 0x1000, groups: [H("CTS_GROUP"), 0xEA903012])
        register("countdown", 0x400, groups: [H("321_GO_GROUP")])
        register("enginetemp", 0x40, groups: [H("Engine_Heat_Meter_Group")], objects: [H("ENGINE_METER")])
        register("message", 0x01000000, groups: [0x32a7a521], objects: [0x6dd754ec, 0xcaec9d04])
        register("getaway", 0x200, groups: [H("GetawayDistanceMeter")])
        register("infractions", 0x200000000, groups: [H("INFRACTIONS_HEADER_GROUP")], objects: [H("GENERIC_ICONS"), H("TOTAL_INFRACTIONS_TEXT")])
        register("leaderboard", 0x18, groups: [H("LeaderBoardGroup")])
        register("zone", 0x400000, groups: [H("Engage_Mechanic"), 0xDA8141D4], objects: [H("EventIcon")])
        register("milestone", 0x400000000, groups: [H("MILESTONE_INFO_GROUP"), H("MILESTONE_ICON_GROUP")])
        var mm: [UInt32] = [H("TRACK_MAP"), H("MINIMAP_NORTH_INDICATOR"), H("PLAYERCARINDICATOR"), H("PLAYERCARINDICATOR2"), H("TRACKMAPTARGETRING"),
                            H("MAP_COLOR_TINT"), H("HELICOPTER_LINE_OF_SIGHT")]
        for i in 0..<8 { mm += [H("TRACK_MAP\(i + 1)"), H("MMICON_COPCAR_\(i)"), H("MMICON_AIRACER_\(i)")] }
        register("minimap", 0x40010000, groups: [H("HELICOPTER_ICON_GROUP")], objects: mm)
        register("raceinfo", 0x4000000, groups: [H("RaceInformationGroup")])
        register("radar", 0x200000, groups: [0x062743f5], objects: [0x839e7d77, 0x9ee06631])
        register("shift", 0x20000000, groups: [H("ENGINE_HEAT_SHIFTLIGHT_GROUP"), H("SHIFT_GROUP")], objects: [H("Shift_light")])
        register("turbo", 0x80020000, groups: [H("TURBO_GROUP")])
        register("wrongway", 0x20, objects: [H("WRONGWAYIMAGE")])
    }

    private func apply(_ f: UInt64) {
        let x = features ^ f
        features = f
        for e in elements.values where x & e.mask != 0 || f == 0 || f == .max {
            let on = f & e.mask != 0
            for o in e.objects { pkg.setVisible(o, on) }
        }
    }

    // MARK: Texturas del cuentarrevoluciones

    /// ChooseMaxRpmTextureNumber / ChooseLoadableTextures [D: FEPkg_Hud.cpp]: líneas 7000–10000 y giro de la zona roja.
    func setTachTextures(maxRpm: Float, redline redlineRpm: Float) {
        maxRpmTexture = maxRpm < 7000 ? 7000 : maxRpm < 8000 ? 8000 : maxRpm < 9000 ? 9000 : 10000
        tachLines?.handle = feHash("\(Int(maxRpmTexture))_LINES_00")
        tachBack?.handle = feHash("TACH_FILL_00")
        needle?.handle = feHash("TACH_NEEDLE_00")
        pkg.find(0x6d5ece44)?.handle = feHash("TURBO_NEEDLE_00")
        pkg.find(0xc62ad685)?.handle = feHash("TURBO_LINES_00")
        // Giro de la zona roja (no arrastre) por tramos de la decomp
        let rot: Float
        switch (maxRpmTexture, redlineRpm) {
        case (7000, let r): rot = r >= 6500 ? 164.5 : r >= 6000 ? 149.5 : r >= 5500 ? 131.5 : 113.5
        case (8000, let r): rot = r >= 7500 ? 165 : r >= 7000 ? 152 : r >= 6500 ? 138 : r >= 6000 ? 123 : 110
        case (9000, let r): rot = r >= 8500 ? 166 : r >= 8000 ? 154 : r >= 7500 ? 140.5 : r >= 7000 ? 128 : 115
        default: rot = redlineRpm >= 9500 ? 167 : redlineRpm >= 9000 ? 156 : redlineRpm >= 8500 ? 143 : 131
        }
        if var pr = redline?.pivotRot { pr.z = rot; redline?.pivotRot = pr }
    }

    // MARK: Fotograma

    func update(ms: Int, input i: HudInput, visible: Bool) {
        // Rasgos del modo libre (DetermineHudFeatures sin carrera, sin minimapa) [D]
        var f: UInt64 = 0
        if visible {
            f = 0x2 | 0x8000000 | 0x800 | 0x40000 | 0x4000 | 0x100000 | 0x800000 | 0x20000000   // sin cuenta atrás, mensajes ni hitos (sin datos aún)
            if i.inPursuit { f |= 0x1000 }
        }
        if f != features { apply(f) }
        if visible {
            tachometer(i); speedometer(i); nitrous(i); heatMeter(i); pursuitBoard(i)
        }
        pkg.visible = visible
        pkg.update(ms: ms)
    }

    private func tachometer(_ i: HudInput) {
        // CalcAngleForRPM: 66°…294° según rpm / máximo de la textura [D]
        let factor = max(0, min(1, i.rpm / maxRpmTexture))
        needle?.setRotationZ(factor * (294 - 66) + 66)
        let letters = ["R", "N", "1", "2", "3", "4", "5", "6", "7", "8"]
        if let g = gearString {
            pkg.printf(g, i.gear >= 0 && i.gear < letters.count ? letters[i.gear] : "N")
            g.setColor(i.shifting ? 0x8800_0000 : 0xFF00_0000)
        }
        let wantShift: UInt32 = i.rpm >= i.redline - 150 && i.gear >= 2 ? 0x02DDC8F0 : FEH.initScript
        if let s = shiftLight, !s.isScript(wantShift) { pkg.setScript(s, wantShift) }
    }

    private func speedometer(_ i: HudInput) {
        let v = abs(i.speed) * (i.kmh ? 3.6 : 2.23694)
        if let u = speedUnits { pkg.setLabel(u, i.kmh ? 0x8569a25f : 0x8569ab44) }
        let d3 = Int(v * 0.01), d2 = Int((v - Float(d3) * 100) * 0.1), d1 = Int(v - Float(d3) * 100 - Float(d2) * 10)
        pkg.printf(digits[2], "\(d3)"); pkg.printf(digits[1], "\(d2)"); pkg.printf(digits[0], "\(d1)")
        pkg.setVisible(digits[2], d3 > 0)
        pkg.setVisible(digits[1], d3 > 0 || d2 > 0)
        pkg.setVisible(digits[0], true)
    }

    private func nitrous(_ i: HudInput) {
        // NitrousGauge::Update / SetNos [D]
        if var pr = nosBar?.pivotRot { pr.z = i.nos * -175 + 175; nosBar?.pivotRot = pr }
        let want: UInt32 = i.nos <= 0 ? FEH.initScript : (i.nos < lastNos ? 0x77031C70 : 0x03826A28)
        if lastNos >= 0, let o = nosIcon, !o.isScript(want) { pkg.setScript(o, want) }
        lastNos = i.nos
    }

    private func heatMeter(_ i: HudInput) {
        // HeatMeter::Update [D]
        let heat = i.heat
        let ip = Int(heat), dp = heat - Float(ip)
        let d1 = min(dp, 0.5), d2 = dp > 0.5 ? dp - 0.5 : 0
        if var pr = heatBar?.pivotRot { pr.z = d1 * 2 * -175 + 175; heatBar?.pivotRot = pr }
        if var pr = heatBar2?.pivotRot { pr.z = d2 * 2 * -175 + 175; heatBar2?.pivotRot = pr }
        if heat >= 1 {
            let want: UInt32 = dp < 0.5 ? 0x41E1FEDC : FEH.initScript
            if let o = heatMult, !o.isScript(want) { pkg.setScript(o, want) }
            for s in pkg.all where s.type == 2 && s.parent === heatMult { pkg.printf(s, "x\(ip)") }
            pkg.setVisible(heatMult, true)
        } else { pkg.setVisible(heatMult, false) }
        let wantIcon: UInt32 = heat > 0 ? (dp > 0.75 ? 0xDA600155 : 0x77031C70) : FEH.initScript
        if let o = heatIcon, !o.isScript(wantIcon) { pkg.setScript(o, wantIcon) }
    }

    private func setSizeXKeepLeft(_ o: FEObj?, _ w: Float) {
        guard let o else { return }
        let left = o.pos.x - o.size.x * 0.5
        o.size.x = w; o.pos.x = left + w * 0.5
    }
    private func setSizeXKeepRight(_ o: FEObj?, _ w: Float) {
        guard let o else { return }
        let right = o.pos.x + o.size.x * 0.5
        o.size.x = w; o.pos.x = right - w * 0.5
    }
    private func ensure(_ o: FEObj?, _ s: UInt32) { if let o, !o.isScript(s) { pkg.setScript(o, s) } }

    private func pursuitBoard(_ i: HudInput) {
        // PursuitBoard::Update [D]
        if i.inPursuit {
            ensure(pbGroup, FEH.appear)
            let t = Int(i.pursuitSeconds)
            pkg.printf(pursuitTimer, String(format: "%d:%02d", t / 60, t % 60))
            pkg.printf(summaryTotal, "\(i.costToState)")
            ensure(psGroup, FEH.appear)
            let tub = i.timeUntilBusted
            if tub <= -1 {
                if !(pcGroup?.isScript(0x13f51124) ?? true) { pkg.setScript(pmGroup, 0x92975065); pkg.setScript(pcGroup, 0x13f51124) }
                setSizeXKeepLeft(coolBar, coolWidth * (1 - i.cooldownRemaining / max(1, i.cooldownRequired)))
            } else {
                if !(pcGroup?.isScript(FEH.hide) ?? true) && !(pcGroup?.isScript(FEH.leave) ?? true) { pkg.setScript(pcGroup, FEH.hide) }   // [I] sin enfriamiento: oculto
                if pcGroup?.isScript(0x13f51124) == true { pkg.setScript(pcGroup, 0x92975065) }
                else if pmGroup?.isScript(FEH.hide) == true || pmGroup?.isScript(FEH.leave) == true { pkg.setScript(pmGroup, FEH.appear) }
                pkg.printf(copsNumbers, "\(i.copsEngaged)")
                pkg.printf(copsTakenOut, "\(i.copsDestroyed)")
                pkg.printf(copsDamaged, "\(i.copsDamaged)")
                if !(backupBacking?.isScript(FEH.leave) ?? true) { pkg.setScript(backupBacking, FEH.leave) }
                let w = barWidths
                setSizeXKeepRight(bustedBars[0], (tub > 0.5 ? (tub - 0.5) * 2 : 0) * w[0])
                ensure(bustedBars[0], tub > 0.5 ? 0x26ded57 : FEH.initScript)
                setSizeXKeepRight(bustedBars[1], (tub > 0.5 ? 0.9 : tub > 0.1 ? tub * 2 - 0.1 : 0) * w[1])
                ensure(bustedBars[2], tub < 0.1 && tub > -0.1 ? 0x3826a28 : FEH.show)
                setSizeXKeepLeft(bustedBars[3], (tub < -0.5 ? 1 : tub < -0.1 ? -tub * 2 - 0.1 : 0) * w[3])
                setSizeXKeepLeft(bustedBars[4], (tub < -0.5 ? -(tub + 0.5) * 2 : 0) * w[4])
                ensure(bustedBars[4], tub < -0.5 ? 0x26ded57 : FEH.initScript)
            }
        } else {
            if pbGroup?.isScript(FEH.appear) == true { pkg.setScript(pbGroup, FEH.leave) }
            if !(pmGroup?.isScript(FEH.leave) ?? true) && !(pmGroup?.isScript(FEH.hide) ?? true) { pkg.setScript(pmGroup, FEH.leave) }
            if pcGroup?.isScript(FEH.appear) == true || pcGroup?.isScript(0x13f51124) == true { pkg.setScript(pcGroup, FEH.leave) }
            if piGroup?.isScript(FEH.appear) == true { pkg.setScript(piGroup, FEH.leave) }
        }
    }
}
