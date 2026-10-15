// HUD del juego con los paquetes originales HUD_SingleRace.fng (zona libre y carreras) y HUD_Drag.fng (aceleración), con la
// lógica de FEngHud y de cada elemento de Frontend/HUD/*.cpp [D]:
//   - Al crear el HUD TODOS los objetos del paquete quedan invisibles (FEngSetAllObjectsInPackageVisibility) y cada elemento
//     registra sus objetos (RegisterGroup/Image/String); solo esos se encienden y apagan con la máscara de rasgos
//     (DetermineHudFeatures → SetHudFeatures → HudElement::Toggle). Lo que ningún elemento registra no se ve nunca.
//   - Cada fotograma se actualizan los elementos visibles con los datos del juego (HudInput) y de la prueba (RaceState).
// Elementos: Tachometer, Speedometer, NitrousGauge, SpeedBreakerMeter, HeatMeter, Minimap (radar), PursuitBoard, CostToState,
// MilestoneBoard, RadarDetector, GenericMessage, Countdown, RaceInformation, LeaderBoard, TimeExtension, WrongWIndi,
// Infractions, MenuZoneTrigger; en HUD_Drag además DragTachometer, ShiftUpdater y EngineTempGauge.
import Foundation
import simd

/// Un icono del radar (coche de policía, rival…): posición y dirección en el plano del mundo del motor (x, y).
struct HudBlip {
    var pos: SIMD2<Float>
    var dir: SIMD2<Float> = SIMD2(1, 0)
    var inPursuit = false
    var heli = false
}

/// Valores que el juego entrega al HUD cada fotograma (interfaces ITachometer, ISpeedometer, INos, IHeatMeter, IPursuitBoard,
/// IMinimap… [D: IFengHud.h]).
struct HudInput {
    var speed: Float = 0             // m/s
    var rpm: Float = 0, redline: Float = 7000, maxRpm: Float = 8000
    var gear = 1                     // 0 = R, 1 = N, 2… = 1.ª…
    var shifting = false
    /// ShiftPotential [D]: 0 nada, 1 normal, 2 buena, 3 perfecta, 4 pasado de vueltas.
    var shiftPotential = 0
    var nos: Float = 1               // 0…1
    var nosEngaged = false
    var speedBreaker: Float = 1      // 0…1 (SpeedBreakerMeter::SetPursuitLevel)
    var heat: Float = 1              // calor del coche (o de la persecución si la hay)
    var inPursuit = false
    var cooldown = false
    /// −1…1: positivo hacia BUSTED, negativo hacia EVADE; ≤ −1 = enfriamiento (PursuitBoard::SetTimeUntilBusted) [D].
    var timeUntilBusted: Float = 0
    var cooldownRemaining: Float = 60, cooldownRequired: Float = 60
    var timeUntilHidden: Float = 0
    var timeUntilBackup: Float = 0
    var pursuitSeconds: Float = 0
    var copsEngaged = 0, copsDestroyed = 0, copsDamaged = 0
    var heliInvolved = false
    var costToState = 0
    var infractions = 0
    var kmh = true                   // castellano: km/h (LanguageHasChanged pone SpeedoUnits = 1 si no es inglés) [D]
    // Radar
    var playerPos: SIMD2<Float>?
    var playerDir = SIMD2<Float>(1, 0)
    var cops: [HudBlip] = []
    /// Detector de radares (RadarDetector): alcance 0…1 (0 = nada) y dirección en radianes respecto al coche.
    var radarRange: Float = 0, radarDirection: Float = 0
    /// Contadores de arrestos y evasiones (los cambios disparan los mensajes del juego).
    var bustedCount = 0, evadedCount = 0
}

final class FEHud {
    enum Kind { case standard, drag }

    /// Estado de la prueba en curso (lo rellena RaceHUD); nil = zona libre.
    struct RaceState {
        var setup: RaceHUDSetup
        var countdown = -1
        var position = 1, racerCount = 1
        var lap = 1, laps = 1
        var raceTime: Double = 0
        var lapTime: Double?
        var bestLap: Double?
        var racers: [RaceHUDRacer] = []
        var nextCheckpoint: SIMD3<Float>?
        var route: [SIMD3<Float>] = []
        var blips: [SIMD3<Float>] = []
        var speedtrapTotal: Float = 0, speedtrapPassed = 0, checkpointCount = 0
        var shiftQuality = 0
        var engineTemp: Float = 0
        var wrongWay = false
        var percentComplete: Float = 0
        init(setup: RaceHUDSetup) {
            self.setup = setup; laps = setup.laps; racers = setup.racers
            racerCount = max(1, setup.racers.count); checkpointCount = setup.checkpointCount
        }
    }
    var race: RaceState? {
        didSet { if (oldValue == nil) != (race == nil) || oldValue?.setup.kind != race?.setup.kind { raceChanged = true } }
    }
    private var raceChanged = false
    private var pendingMessages: [RaceHUDMessage] = []
    func queueMessage(_ m: RaceHUDMessage) { pendingMessages.append(m) }

    let pkg: FEPackageRT
    let kind: Kind
    private let assets: FEAssets

    private final class Element {
        let name: String
        let mask: UInt64
        var objects: [FEObj] = []
        init(_ n: String, _ m: UInt64) { name = n; mask = m }
    }
    private var elements: [Element] = []
    private var features: UInt64 = 0
    private func on(_ mask: UInt64) -> Bool { features & mask != 0 }

    // MARK: Objetos

    private func f(_ s: String) -> FEObj? { pkg.find(s) }
    private func h(_ x: UInt32) -> FEObj? { pkg.find(x) }

    // Tachometer / Speedometer / Nitrous / SpeedBreaker / Heat
    private var needle, redline, shiftLight, gearString, tachLines: FEObj?
    private var digits: [FEObj?] = []
    private var speedUnits: FEObj?
    private var nosIcon, nosBar: FEObj?
    private var sbIcon, sbBar, sbGroup, sbBarSmall: FEObj?
    private var sbBarWidth: Float = 0
    private var heatMult, heatIcon, heatBar, heatBar2: FEObj?
    private var lastNos: Float = -1
    private var lastSpeedBreaker: Float = -1
    private var maxRpmTexture: Float = 8000
    // PursuitBoard
    private var pbGroup, pmGroup, piGroup, psGroup, pcGroup: FEObj?
    private var pursuitTimer, backupTimer, copsNumbers, copsTakenOut, copsDamaged, summaryTotal: FEObj?
    private var bustedBars: [FEObj?] = []
    private var barWidths: [Float] = []
    private var coolBar, backupBacking, hidingBacking: FEObj?
    private var coolWidth: Float = 216
    private var lastCopsEngaged = 0, lastCopsDamaged = 0
    // CostToState / Reputation
    private var ctsGroup, ctsValue, ctsTitle: FEObj?
    private var ctsOn = false, ctsFrames = 0, ctsValueShown = 0
    // Milestones
    private var milestoneInfo, milestoneIcons: FEObj?
    // RadarDetector
    private var rdGroup, rdLightsL, rdLightsR, rdArrow, rdIcon, rdBacking, rdBackingMirror: FEObj?
    private var rdLed: Float = 0.3, rdCycle: Float = -1
    // GenericMessage
    private var gmGroup, gmIcon, gmWrapper: FEObj?
    private var gmPriority = 0, gmScript: UInt32 = 0, gmFrames = 0, gmOneFrame = false
    // Countdown
    private var cdGroup, cdText, cdShadow: FEObj?
    private var cdShown = -1
    // RaceInformation / LeaderBoard / WrongWay / Infractions
    private var riLapTime, riComplete, riPosGroup, riToll, riTollTop, riTollBot, riPos, riCount, riPercent: FEObj?
    private var lbGroup: FEObj?
    private var lbText: [FEObj?] = [], lbNum: [FEObj?] = [], lbIcon: [FEObj?] = [], lbBack: [FEObj?] = []
    private var lbFrames = 90, lbShowTimes = false
    private var wrongWayImage: FEObj?
    private var wrongWayTimer: Float = -1, wrongWayShown = false
    private var infGenericIcon, infTotal: FEObj?
    private var infGroups: [FEObj?] = []
    // Minimap
    private var mmPieces: [FEObj?] = []
    private var mmPieceUVs: [(SIMD2<Float>, SIMD2<Float>)] = []
    private var mmLayout, mmNorth, mmPlayer, mmPlayer2, mmHeli, mmHeliLOS, mmCheckpoint, mmGPS: FEObj?
    private var mmCops: [FEObj?] = [], mmRacers: [FEObj?] = []
    private var mmDefaultPos = SIMD3<Float>(0, 0, 0)
    private var mmCentre = SIMD2<Float>(0, 0)
    private var mmTarget = SIMD2<Float>(0, 0)
    private var mmRotation: Float = 0
    private var mmFlash = -1
    private var mmMap = ""
    /// Radar que gira con el coche (ExploringMiniMapMode/RacingMiniMapMode = 1, el modo por defecto [I]).
    var minimapRotates = true
    // Drag
    private var dragNeedle, dragGear, engineBar, engineIcon, shiftMsgGroup, shiftMsg, shiftMsgShadow, overheatGroup: FEObj?
    // Estado previo
    private var lastBusted = -1, lastEvaded = -1
    private var lastCost = 0

    init?(assets: FEAssets, kind: Kind = .standard) {
        guard let p = FEPackageRT(name: kind == .drag ? "HUD_Drag" : "HUD_SingleRace", assets: assets) else { return nil }
        pkg = p; self.kind = kind; self.assets = assets
        // FEngHud::FEngHud: todo invisible; cada elemento registra lo suyo [D]
        for o in p.all { o.flags |= 1 }
        registerAll()
        // Fuera de línea: sin los datos del modo online [D]
        for x: UInt32 in [0xC18C12FD, 0xC18C12FE] { p.setVisible(p.find(x), false) }
        setTachTextures(maxRpm: 8000, redline: 7000)
        apply(0xFFFF_FFFF_FFFF_FFFF); apply(0)
        features = 0
    }

    // MARK: Registro (HudElement::Register*) [D]

    @discardableResult
    private func element(_ name: String, _ mask: UInt64, groups: [UInt32] = [], objects: [UInt32] = []) -> Element {
        let e = Element(name, mask)
        func addGroup(_ g: FEObj) { for c in g.children { if c.type == 5 { addGroup(c) } else { e.objects.append(c) } } }
        for gh in groups { if let g = pkg.find(gh), g.type == 5 { addGroup(g) } }
        for oh in objects { if let o = pkg.find(oh) { e.objects.append(o) } }
        elements.append(e)
        return e
    }

    private func registerAll() {
        let H = feHash
        // Comunes (FEngHud::FEngHud): Speedometer, RaceInformation, LeaderBoard, NitrousGauge, RaceOverMessage, GenericMessage,
        // TurboMeter, WrongWIndi, Countdown
        element("speedo", 0x8000000, groups: [H("SpeedometerGroup")])
        digits = [f("SPEED_DIGIT_1"), f("SPEED_DIGIT_2"), f("SPEED_DIGIT_3")]
        speedUnits = f("3rdPersonSpeedUnits")
        element("raceinfo", 0x4000000, groups: [H("RaceInformationGroup")])
        riLapTime = f("CurrentLapTime"); riComplete = f("Complete_Text"); riPosGroup = f("POSITION_GROUP")
        riToll = f("Milestone_TollBooth"); riTollTop = h(0x1CDDD8D0); riTollBot = h(0x18A7ACD2)
        riPos = h(0x9C183BF8); riCount = h(0x3BBD6268); riPercent = h(0x9CB5C95D)
        element("leaderboard", 0x18, groups: [H("LeaderBoardGroup")])
        lbGroup = f("LeaderBoardGroup")
        for i in 1...4 { lbText.append(f("LBData_\(i)")); lbNum.append(f("LeaderText_\(i)")); lbIcon.append(f("OL_ICON_\(i + 1)")); lbBack.append(f("LBBacking_\(i)")) }
        element("nos", 0x80000800, groups: [0x87C38E97], objects: [0xEDFB6D37])
        nosIcon = h(0x27DDF583); nosBar = h(0xEDFB6D37)
        element("raceover", 0x4)
        element("message", 0x01000000, groups: [0x32a7a521], objects: [0x6dd754ec, 0xcaec9d04])
        gmGroup = h(0x32a7a521); gmIcon = h(0x6dd754ec); gmWrapper = h(0xe0ba07ec)
        element("turbo", 0x80020000, groups: [H("TURBO_GROUP")])
        element("wrongway", 0x20, objects: [H("WRONGWAYIMAGE")])
        wrongWayImage = f("WRONGWAYIMAGE")
        element("countdown", 0x400, groups: [H("321_GO_GROUP")])
        cdGroup = f("321_GO_GROUP"); cdText = f("321_GO"); cdShadow = f("321_GO_SHADOW")

        if kind == .drag {
            element("enginetemp", 0x40, groups: [H("Engine_Heat_Meter_Group")], objects: [H("ENGINE_METER")])
            engineBar = f("ENGINE_METER"); engineIcon = f("ENGINE_HEAT_ICON_GROUP")
            // DragTachometer: RPM_fill, Drag_Turbo_Backing, Drag_Turbo_Lines, 3rdPersonSpeedUnits, SPEED_BACKING, grupo RPM…
            element("dragtach", 0x2, groups: [H("RPM")], objects: ["RPM_fill", "Drag_Turbo_Backing", "Drag_Turbo_Lines", "3rdPersonSpeedUnits",
                                                                  "SPEED_BACKING", "TAC_Lines_7500", "RPM_Redline", "3rdPersonNeedle", "3rdPersonGear"].map(H))
            dragNeedle = f("3rdPersonNeedle"); dragGear = f("3rdPersonGear"); tachLines = f("TAC_Lines_7500"); redline = f("RPM_Redline")
            element("shift", 0x20000000, groups: [H("ENGINE_HEAT_SHIFTLIGHT_GROUP"), H("SHIFT_GROUP")], objects: [H("Shift_light")])
            shiftLight = f("Shift_light"); overheatGroup = f("ENGINE_HEAT_SHIFTLIGHT_GROUP")
            shiftMsgGroup = f("SHIFT_GROUP"); shiftMsg = f("ShiftMessage"); shiftMsgShadow = f("ShiftMessage_Shadow")
        } else {
            element("timeext", 0x2000000)
            element("tach", 0x2, groups: [H("GaugeCluster"), 0x045E9562])
            needle = f("3rdPersonNeedle"); redline = f("RPM_REDLINE"); shiftLight = f("Shift_light"); gearString = f("3rdPersonGear")
            tachLines = f("TAC_Lines_7500")
            // Solo en el HUD normal: Reputation (carrera), HeatMeter, CostToState, PursuitBoard, MilestoneBoard, BustedMeter,
            // MenuZoneTrigger, Infractions, RadarDetector; y el Minimap
            element("rep", 0x1000, groups: [0xEA903012])
            h(0xEA903012).map { pkg.setScript($0, FEH.hide) }
            element("heat", 0x40004000, groups: [0xC46A80A9], objects: [0x862824C9, 0x4B2CBE1B])
            heatMult = h(0x7F91DA62); heatIcon = h(0x6F85ED55); heatBar = h(0x862824C9); heatBar2 = h(0x4B2CBE1B)
            element("cts", 0x1000, groups: [H("CTS_GROUP")])
            ctsGroup = f("CTS_GROUP"); ctsValue = h(0x3FF5F33C); ctsTitle = h(0x64247241)
            pkg.setScript(ctsGroup, FEH.hide)
            element("pursuit", 0x100000, groups: [0xde89e070, 0x7b422ba3, 0xe0b1430b, 0x8674e6d4, 0x84a226ec, 0x6a144066], objects: [0x3c165f39, 0xbee44775])
            pbGroup = h(0xde89e070); pmGroup = h(0x7b422ba3); piGroup = h(0xe0b1430b); psGroup = h(0x8674e6d4); pcGroup = h(0x84a226ec)
            pursuitTimer = h(0xfc39cb0a); backupTimer = h(0xbee44775); copsNumbers = h(0x814918ca); copsTakenOut = h(0xa16f9f1e)
            copsDamaged = h(0x5fa70d4c); summaryTotal = h(0x875e92eb)
            bustedBars = [h(0xe0e0169b), h(0x8eeebd33), h(0x47a4e2a9), h(0x8e3653a6), h(0x30f39a6f)]
            barWidths = bustedBars.map { $0?.size.x ?? 0 }
            coolBar = h(0xcf817638); backupBacking = h(0x8c20a763); hidingBacking = h(0x5c2a4f20)
            coolWidth = coolBar?.size.x ?? 216
            element("milestone", 0x400000000, groups: [H("MILESTONE_INFO_GROUP"), H("MILESTONE_ICON_GROUP")])
            milestoneInfo = f("MILESTONE_INFO_GROUP"); milestoneIcons = f("MILESTONE_ICON_GROUP")
            element("busted", 0x800000)
            element("zone", 0x400000, groups: [H("Engage_Mechanic"), 0xDA8141D4], objects: [H("EventIcon")])
            var inf: [UInt32] = []
            for i in 1...4 { inf.append(H("INFRACTION_GROUP_\(i)")) }
            element("infractions", 0x200000000, groups: [H("INFRACTIONS_HEADER_GROUP")] + inf, objects: [H("GENERIC_ICONS"), H("TOTAL_INFRACTIONS_TEXT")])
            infGenericIcon = f("GENERIC_ICONS"); infTotal = f("TOTAL_INFRACTIONS_TEXT"); infGroups = inf.map { h($0) }
            element("radardetector", 0x200000, groups: [0x062743f5], objects: [0x839e7d77, 0x9ee06631])
            rdGroup = h(0x062743f5); rdLightsL = h(0x69aa01e7); rdLightsR = h(0x9f59065a); rdArrow = f("Radar_DirectionArrow")
            rdIcon = f("Radar_Icon"); rdBacking = h(0x839e7d77); rdBackingMirror = h(0x9ee06631)
            // Minimap (FeMinimap.cpp): 4 trozos TRACK_MAP1…4, rejilla TRACK_MAP, norte, coche, iconos de policía y rivales
            var mm: [UInt32] = []
            for i in 1...4 { mm.append(H("TRACK_MAP\(i)")) }
            mm += ["TRACK_MAP", "MINIMAP_NORTH_INDICATOR", "PLAYERCARINDICATOR", "PLAYERCARINDICATOR2", "TRACKMAPTARGETRING", "MAP_COLOR_TINT"].map(H)
            mm.append(H("HELICOPTER_LINE_OF_SIGHT"))
            for i in 0..<8 { mm += [H("MMICON_COPCAR_\(i)"), H("MMICON_AIRACER_\(i)")] }
            mm += [H("MMICON_CHECKPOINT"), 0xE8741681]
            element("minimap", 0x40010000, groups: [H("HELICOPTER_ICON_GROUP")], objects: mm)
            for i in 1...4 { let o = f("TRACK_MAP\(i)"); mmPieces.append(o); mmPieceUVs.append((o?.maskTL ?? .zero, o?.maskBR ?? .zero)) }
            mmLayout = f("TRACK_MAP"); mmNorth = f("MINIMAP_NORTH_INDICATOR"); mmPlayer = f("PLAYERCARINDICATOR"); mmPlayer2 = f("PLAYERCARINDICATOR2")
            mmHeli = f("HELICOPTER_ICON_GROUP"); mmHeliLOS = f("HELICOPTER_LINE_OF_SIGHT"); mmCheckpoint = f("MMICON_CHECKPOINT"); mmGPS = h(0xE8741681)
            for i in 0..<8 { mmCops.append(f("MMICON_COPCAR_\(i)")); mmRacers.append(f("MMICON_AIRACER_\(i)")) }
            if let l = mmLayout { mmDefaultPos = l.pos; mmCentre = SIMD2(l.pos.x, l.pos.y) }
        }
        // Comunes al HUD normal y al de aceleración (PHT_STANDARD / PHT_DRAG): SpeedBreakerMeter y GetAwayMeter
        element("speedbreaker", 0x40000, groups: [H("Speedbreaker_Meter_Group"), 0x82D60021], objects: [H("Speedbreaker_Meter_Multi_Image")])
        sbIcon = f("SPEEDBREAKER_METER_ICON_GROUP"); sbBar = f("Speedbreaker_Meter_Multi_Image"); sbGroup = h(0x82D60021); sbBarSmall = h(0x1FDAF669)
        sbBarWidth = sbBarSmall?.size.x ?? 0
        element("getaway", 0x200, groups: [H("GetawayDistanceMeter")])
    }

    /// SetHudFeatures: cada elemento cuyo bit cambia enciende o apaga sus objetos (HudElement::Toggle) [D].
    private func apply(_ f: UInt64) {
        let x = features ^ f
        for e in elements where x & e.mask != 0 || (e.name == "leaderboard" && x & 0x18 != 0) {
            let onoff = f & e.mask != 0
            for o in e.objects { pkg.setVisible(o, onoff) }
        }
        features = f
    }

    // MARK: Pantalla panorámica (FEngHud::SetWideScreenMode) [D]

    private var wsOffset: Float = 0
    private var mmPivotX: Float = 0

    /// Con la opción panorámica el juego manda FEObj_WIDESCREENMODE (0x62ED04EC) al HUD: el grupo del radar (0x1603009e) va
    /// 120 unidades a la izquierda y el del cuentarrevoluciones (0x5d0101f1) 120 a la derecha [V: scripts 0x1edc08 de los dos
    /// paquetes], y Minimap::AdjustForWidescreen mueve el mapa, su centro y el coche. Ese desplazamiento está pensado para
    /// 16:9 (media anchura visible 426,7 unidades); en pantallas más estrechas (16:10) se reduce en proporción para que el
    /// HUD no se salga [I].
    func setWidescreen(visibleHalfWidth hw: Float) {
        let off = max(0, min(120, (hw - 320) * 120 / (320 * 4 / 3 - 320)))
        let d = off - wsOffset
        guard abs(d) > 0.01 else { return }
        wsOffset = off
        if let g = h(0x1603009e) { g.pos.x -= d }
        if let g = h(0x5d0101f1) { g.pos.x += d }
        guard kind == .standard else { return }
        mmCentre.x -= d
        mmPivotX = -off
        for p in mmPieces { if let p { p.pos.x -= d } }
        if let pl = mmPlayer { pl.pos.x -= d; pl.pos.y = mmCentre.y }
    }

    // MARK: Texturas del cuentarrevoluciones

    /// ChooseMaxRpmTextureNumber / ChooseLoadableTextures + HUD de serie (HUDS_CUSTOM_00) [D: FEPkg_Hud.cpp].
    func setTachTextures(maxRpm: Float, redline redlineRpm: Float) {
        maxRpmTexture = maxRpm < 7000 ? 7000 : maxRpm < 8000 ? 8000 : maxRpm < 9000 ? 9000 : 10000
        let isDrag = kind == .drag
        let lines = isDrag ? "DRAG_RPM_\(Int(maxRpmTexture))_LINES" : "\(Int(maxRpmTexture))_LINES_00"
        h(0x309878bc)?.handle = feHash(lines)
        if !isDrag {
            // LoadedCustomHudTexturesCallback: fondo, aguja de rpm, velocímetro y aguja del turbo del HUD 00 [D]. En el disco PS2
            // esas texturas se llaman TACH_FILL_00 / TACH_NEEDLE_00 / TURBO_* (no CUSTOMHUD_*) [V: HUDS_CUSTOM_00.BIN]
            h(0x05d19f25)?.handle = feHash("TACH_FILL_00")
            h(0xf0250dac)?.handle = feHash("TACH_NEEDLE_00")
            h(0x6d5ece44)?.handle = feHash("TURBO_NEEDLE_00")
            h(0xc62ad685)?.handle = feHash("TURBO_LINES_00")
        }
        let r = redlineRpm
        let rot: Float
        switch maxRpmTexture {
        case 7000: rot = r >= 6500 ? (isDrag ? 39.25 : 164.5) : r >= 6000 ? (isDrag ? 32.25 : 149.5) : r >= 5500 ? (isDrag ? 26 : 131.5) : (isDrag ? 19.25 : 113.5)
        case 8000: rot = r >= 7500 ? (isDrag ? 40 : 165) : r >= 7000 ? (isDrag ? 34 : 152) : r >= 6500 ? (isDrag ? 28.25 : 138) : r >= 6000 ? (isDrag ? 22.5 : 123) : (isDrag ? 17.25 : 110)
        case 9000: rot = r >= 8500 ? (isDrag ? 42 : 166) : r >= 8000 ? (isDrag ? 37 : 154) : r >= 7500 ? (isDrag ? 32.25 : 140.5) : r >= 7000 ? (isDrag ? 27 : 127) : (isDrag ? 22 : 115)
        default: rot = r >= 9500 ? (isDrag ? 41.5 : 167) : r >= 9000 ? (isDrag ? 37 : 156) : r >= 8500 ? (isDrag ? 31.5 : 145) : r >= 8000 ? (isDrag ? 27 : 134) : (isDrag ? 22.75 : 123)
        }
        if let o = h(0xcdfce1b0) ?? redline, var pr = Optional(o.pivotRot) { pr.z = rot; o.pivotRot = pr }
    }

    // MARK: Rasgos (FEngHud::DetermineHudFeatures) [D]

    private func determineFeatures(visible: Bool) -> UInt64 {
        guard visible else { return 0 }
        var f: UInt64 = 0
        let racing = race != nil && race?.setup.kind != .pursuit
        let isDrag = race?.setup.kind == .drag
        // Minimapa: circuito 2000 (Rockport) y el modo del radar no está apagado; en aceleración no hay radar
        if kind == .standard && (race == nil || race?.setup.showMinimap == true) { f |= 0x10000 | 0x4000 }
        // GaugesOn / PositionOn (por defecto encendidos [I: valores de fábrica de FEPlayerSettings])
        f |= 0x8000000
        f |= 0x2 | 0x800 | 0x40000
        if isDrag { f |= 0x40 }
        if racing { f |= 0x8 | 0x4000000 } else { f |= 0x100000 | 0x400000000 }
        f |= 0x10                                   // SplitTimeType != 4
        if race?.setup.kind == .tollbooth { f |= 0x2000000 }
        f |= 0x1000                                 // ScoreOn y modo carrera profesional
        if racing { f |= 0x20 }
        f |= 0x1000000 | 0x10000000 | 0x100000000 | 0x80000 | 0x400 | 0x20000000 | 0x400000 | 0x200000000 | 0x800000 | 0x200000
        return f
    }

    // MARK: Fotograma

    func update(ms: Int, input i: HudInput, visible: Bool) {
        if raceChanged { raceChanged = false; resetRaceElements() }
        let f = determineFeatures(visible: visible)
        if f != features { apply(f) }
        events(i)
        if f != 0 {
            if on(0x8000000) { speedometer(i) }
            if kind == .drag { if on(0x2) { dragTachometer(i) }; if on(0x20000000) { shiftUpdater(i) }; if on(0x40) { engineTemp() } }
            else if on(0x2) { tachometer(i) }
            if kind == .standard && on(0x10000) { minimap(i) }
            if on(0x4000000) { raceInformation() }
            if on(0x18) { leaderboard() }
            if kind == .standard {
                if on(0x100000) { pursuitBoard(i) }
                if on(0x400000000) { milestoneBoard(i) }
                if on(0x1000) { costToState(i) }
                if on(0x4000) { heatMeter(i) }
                if on(0x200000) { radarDetector(i, dt: Float(ms) / 1000) }
                if on(0x200000000) { infractionsUpdate() }
            }
            if on(0x800) { nitrous(i) }
            if on(0x40000) { speedBreaker(i) }
            if on(0x1000000) { genericMessage() }
            if on(0x400) { countdown() }
            if on(0x20) { wrongWay(dt: Float(ms) / 1000) }
        }
        pkg.visible = visible
        pkg.update(ms: ms)
    }

    /// Mensajes por cambios de estado: arresto (PursuitBoard::SetTimeUntilBusted(1) → «ARRESTADO») y mensajes de la carrera.
    private func events(_ i: HudInput) {
        if lastBusted >= 0, i.bustedCount > lastBusted {
            requestMessage(assets.string(0x532b5186) ?? "BUSTED", script: 0x9d73bc15, priority: 1)
        }
        lastBusted = i.bustedCount; lastEvaded = i.evadedCount
        while !pendingMessages.isEmpty { raceMessage(pendingMessages.removeFirst()) }
    }

    private func resetRaceElements() {
        cdShown = -1
        lbFrames = 90; lbShowTimes = false
        wrongWayTimer = -1; wrongWayShown = false
        if let g = cdGroup { pkg.setScript(g, FEH.hide) }
    }

    // MARK: Elementos de conducción

    private func tachometer(_ i: HudInput) {
        // CalcAngleForRPM: 66°…294° según rpm / máximo de la textura [D]
        let factor = max(0, min(1, i.rpm / maxRpmTexture))
        needle?.setRotationZ(factor * (294 - 66) + 66)
        if let g = gearString {
            pkg.printf(g, gearLetter(i.gear))
            g.setColor(i.shifting ? 0x8800_0000 : 0xFF00_0000)
        }
        let potential = i.shiftPotential > 0 ? i.shiftPotential : (i.rpm >= i.redline - 150 && i.gear >= 2 ? 2 : 0)
        let want: UInt32 = potential > 1 ? 0x02DDC8F0 : FEH.initScript
        ensure(shiftLight, want)
    }

    private func gearLetter(_ g: Int) -> String { ["R", "N", "1", "2", "3", "4", "5", "6", "7", "8"][opt: g] ?? "N" }

    private func speedometer(_ i: HudInput) {
        let v = abs(i.speed) * (i.kmh ? 3.6 : 2.23694)
        if let u = speedUnits { pkg.setLabel(u, i.kmh ? 0x8569a25f : 0x8569ab44) }
        let d3 = Int(v * 0.01), d2 = Int((v - Float(d3) * 100) * 0.1), d1 = Int(v - Float(d3) * 100 - Float(d2) * 10)
        pkg.printf(digits[opt: 2] ?? nil, "\(d3)"); pkg.printf(digits[opt: 1] ?? nil, "\(d2)"); pkg.printf(digits[opt: 0] ?? nil, "\(d1)")
        pkg.setVisible(digits[opt: 2] ?? nil, d3 > 0)
        pkg.setVisible(digits[opt: 1] ?? nil, d3 > 0 || d2 > 0)
        pkg.setVisible(digits[opt: 0] ?? nil, true)
    }

    private func nitrous(_ i: HudInput) {
        // NitrousGauge::Update / SetNos [D]
        let minAngle: Float = kind == .drag ? -48 : 175
        if var pr = nosBar?.pivotRot { pr.z = i.nos * -minAngle + minAngle; nosBar?.pivotRot = pr }
        if lastNos >= 0 {
            let want: UInt32 = i.nos <= 0 ? FEH.initScript : (i.nos < lastNos ? 0x77031C70 : 0x03826A28)
            if i.nos != lastNos || i.nos <= 0 { ensure(nosIcon, want) }
        }
        lastNos = i.nos
    }

    private func speedBreaker(_ i: HudInput) {
        // SpeedBreakerMeter::Update: solo cuando cambia el nivel [D]
        guard i.speedBreaker != lastSpeedBreaker else { return }
        lastSpeedBreaker = i.speedBreaker
        let minAngle: Float = kind == .drag ? -48 : 175
        if var pr = sbBar?.pivotRot { pr.z = i.speedBreaker * -minAngle + minAngle; sbBar?.pivotRot = pr }
        if let g = sbGroup, g.isScript(0x5b0d9106), let b = sbBarSmall {
            setSizeXKeepLeft(b, sbBarWidth * i.speedBreaker)
            ensure(b, i.speedBreaker <= 0.3 ? 0x26ded57 : 0x620e4851)
        }
        if let o = sbIcon { pkg.setScript(o, i.speedBreaker > 0 ? 0x77031c70 : FEH.initScript) }
    }

    private func heatMeter(_ i: HudInput) {
        // HeatMeter::Update [D]. La segunda barra: la decomp no está resuelta («UNSOLVED»); cada barra cubre media vuelta del
        // arco, así que la segunda solo avanza en la segunda mitad del nivel [I]
        let heat = i.heat
        let ip = Int(heat), dp = heat - Float(ip)
        let d1 = min(dp, 0.5), d2 = dp > 0.5 ? dp - 0.5 : 0
        if var pr = heatBar?.pivotRot { pr.z = d1 * 2 * -175 + 175; heatBar?.pivotRot = pr }
        if var pr = heatBar2?.pivotRot { pr.z = d2 * 2 * -175 + 175; heatBar2?.pivotRot = pr }
        if heat >= 1 {
            ensure(heatMult, dp < 0.5 ? 0x41E1FEDC : FEH.initScript)
            printDeep(heatMult, "x\(ip)")
            pkg.setVisible(heatMult, true)
        } else { pkg.setVisible(heatMult, false) }
        ensure(heatIcon, heat > 0 ? (dp > 0.75 ? 0xDA600155 : 0x77031C70) : FEH.initScript)
    }

    // MARK: Persecución

    private func pursuitBoard(_ i: HudInput) {
        // PursuitBoard::Update [D]
        if i.inPursuit {
            ensure(pbGroup, FEH.appear)
            pkg.printf(pursuitTimer, FEHud.timeString(Double(i.pursuitSeconds)))
            pkg.printf(summaryTotal, FEHud.money(i.costToState))
            ensure(psGroup, FEH.appear)
            let tub = max(-1, min(0.99, i.timeUntilBusted))
            if tub <= -1 {
                if !(pcGroup?.isScript(0x13f51124) ?? true) { pkg.setScript(pmGroup, 0x92975065) }
                setSizeXKeepLeft(coolBar, coolWidth * (1 - i.cooldownRemaining / max(1, i.cooldownRequired)))
                if i.timeUntilHidden > 0 { ensure(hidingBacking, FEH.appear) }
                else if hidingBacking?.isScript(FEH.appear) == true { pkg.setScript(hidingBacking, FEH.leave) }
            } else {
                if pcGroup?.isScript(0x13f51124) == true { pkg.setScript(pcGroup, 0x92975065) }
                else if pmGroup?.isScript(FEH.hide) == true || pmGroup?.isScript(FEH.leave) == true { pkg.setScript(pmGroup, FEH.appear) }
                if hidingBacking?.isScript(FEH.appear) == true { pkg.setScript(hidingBacking, FEH.leave) }
                let report = i.copsEngaged - (i.heliInvolved ? 1 : 0)
                pkg.printf(copsNumbers, "\(report)")
                pkg.printf(copsTakenOut, "\(i.copsDestroyed)")
                pkg.printf(copsDamaged, "\(i.copsDamaged)")
                // SetNumCopsInPursuit / SetNumCopsDamaged: destellos de los iconos [D]
                if i.copsEngaged != lastCopsEngaged {
                    if i.copsEngaged > lastCopsEngaged { pkg.setScript(h(0x3787231c), 0x4f90cf9b) }
                    else { pkg.setScript(h(0x3787231c), 0xfb12d252); pkg.setScript(h(0x3b9919a8), 0x579dbc92) }
                    lastCopsEngaged = i.copsEngaged
                }
                if i.copsDamaged > lastCopsDamaged { pkg.setScript(copsDamaged, 0x4f90cf9b) }
                lastCopsDamaged = i.copsDamaged
                if i.timeUntilBackup > 0 {
                    ensure(backupBacking, i.timeUntilBackup > 10 ? FEH.appear : 0x26ded57)
                    pkg.printf(backupTimer, FEHud.timeString(Double(i.timeUntilBackup)))
                } else { ensure(backupBacking, FEH.leave) }
                let w = barWidths
                guard w.count == 5 else { return }
                setSizeXKeepRight(bustedBars[0], (tub > 0.5 ? (tub - 0.5) * 2 : 0) * w[0])
                ensure(bustedBars[0], tub > 0.5 ? 0x26ded57 : FEH.initScript)
                setSizeXKeepRight(bustedBars[1], (tub > 0.5 ? 0.9 : tub > 0.1 ? tub * 2 - 0.1 : 0) * w[1])
                ensure(bustedBars[2], tub < 0.1 && tub > -0.1 ? 0x3826a28 : FEH.show)
                setSizeXKeepLeft(bustedBars[3], (tub < -0.5 ? 1 : tub < -0.1 ? -tub * 2 - 0.1 : 0) * w[3])
                setSizeXKeepLeft(bustedBars[4], (tub < -0.5 ? -(tub + 0.5) * 2 : 0) * w[4])
                ensure(bustedBars[4], tub < -0.5 ? 0x26ded57 : FEH.initScript)
            }
        } else {
            lastCopsEngaged = 0; lastCopsDamaged = 0
            if pbGroup?.isScript(FEH.appear) == true { pkg.setScript(pbGroup, FEH.leave) }
            if !(pmGroup?.isScript(FEH.leave) ?? true) && !(pmGroup?.isScript(FEH.hide) ?? true) { pkg.setScript(pmGroup, FEH.leave) }
            if pcGroup?.isScript(FEH.appear) == true || pcGroup?.isScript(0x13f51124) == true { pkg.setScript(pcGroup, FEH.leave) }
            if piGroup?.isScript(FEH.appear) == true { pkg.setScript(piGroup, FEH.leave) }
        }
    }

    private func costToState(_ i: HudInput) {
        // CostToState: aparece 120 fotogramas cada vez que sube el coste de la persecución [D]
        if i.inPursuit && i.costToState > lastCost { ctsFrames = 120; ctsValueShown = i.costToState }
        if !i.inPursuit && i.costToState == 0 { ctsValueShown = 0 }
        lastCost = i.costToState
        guard ctsValue != nil else { return }
        if ctsFrames >= 1 {
            ctsFrames -= 1
            if let t = ctsTitle { pkg.setLabel(t, 0x3DD874C5) }
            pkg.printf(ctsValue, FEHud.money(ctsValueShown))
            if !ctsOn { ctsOn = true; pkg.setScript(ctsGroup, FEH.appear) }
        } else if ctsOn { ctsOn = false; pkg.setScript(ctsGroup, FEH.leave) }
    }

    private func milestoneBoard(_ i: HudInput) {
        // Sin hitos en la zona libre (mNumMilestones = 0): el panel se va [D: MilestoneBoard::Update]
        if milestoneInfo?.isScript(FEH.appear) == true { pkg.setScript(milestoneInfo, FEH.leave) }
        if milestoneIcons?.isScript(FEH.appear) == true { pkg.setScript(milestoneIcons, FEH.leave) }
    }

    private func radarDetector(_ i: HudInput, dt: Float) {
        // RadarDetector::Update sin retrovisor [D]
        if rdBackingMirror?.isScript(FEH.hide) == false { pkg.setScript(rdBackingMirror, FEH.hide) }
        let pursuing = i.inPursuit && !i.cooldown
        if !pursuing {
            ensure(rdBacking, FEH.appear); ensure(rdGroup, FEH.appear)
        } else {
            if rdBacking?.isScript(FEH.initScript) == true { pkg.setScript(rdBacking, FEH.hide) }
            else if rdBacking?.isScript(FEH.leave) == false && rdBacking?.isScript(FEH.hide) == false { pkg.setScript(rdBacking, FEH.leave) }
            if rdGroup?.isScript(FEH.initScript) == true { pkg.setScript(rdGroup, FEH.hide) }
            else if rdGroup?.isScript(FEH.leave) == false && rdBacking?.isScript(FEH.hide) == false { pkg.setScript(rdGroup, FEH.leave) }
        }
        if i.radarRange > 0 && !pursuing {
            if rdCycle < 0 { rdCycle = 0 }
            rdLed = min(1, rdLed + 0.1)
            rdCycle += dt
            if rdCycle > max(0.1, i.radarRange) * 1.5 { rdCycle = 0; rdLed = 0.3 }
            setMultiBR(rdLightsL, SIMD2(rdLed, 1)); setMultiBR(rdLightsR, SIMD2(rdLed, 1))
            rdArrow?.setRotationZ(i.radarDirection * 180 / .pi)
            for o in [rdArrow, rdIcon, rdLightsL, rdLightsR] { ensure(o, FEH.initScript) }
        } else {
            rdCycle = -1
            setMultiBR(rdLightsL, SIMD2(0, 1)); setMultiBR(rdLightsR, SIMD2(0, 1))
            ensure(rdArrow, FEH.hide); ensure(rdIcon, FEH.initScript)
        }
    }

    private func infractionsUpdate() {
        let showing = infGroups.contains { $0 != nil && !($0!.isScript(FEH.hide)) }
        if !showing, let g = infGenericIcon, g.isScript(FEH.appear) || g.isScript(0x3826a28) { pkg.setScript(g, FEH.leave) }
    }

    /// Infractions::RequestInfraction: texto de la infracción y total [D].
    func requestInfraction(_ text: String, total: Int) {
        for g in infGroups { if let g, g.isScript(FEH.hide) { pkg.setScript(g, FEH.appear); printDeep(g, text); break } }
        pkg.setScript(infGenericIcon, FEH.appear)
        pkg.printf(infTotal, "\(total)")
    }

    // MARK: Mensajes (GenericMessage) [D]

    /// RequestGenericMessage: texto en el centro con la animación `script` del grupo 0x32a7a521.
    @discardableResult
    func requestMessage(_ text: String, script: UInt32 = 0x8AB83EDB, iconTexture: UInt32 = 0, iconScript: UInt32 = 0, priority: Int = 3, oneFrame: Bool = false) -> Bool {
        if priority < gmPriority { return false }
        if let w = gmWrapper, !w.isScript(FEH.initScript) { pkg.setScript(w, FEH.initScript) }
        gmPriority = priority; gmScript = script; gmFrames = 0; gmOneFrame = oneFrame
        if script != 0 {
            if oneFrame { ensure(gmGroup, script) } else { pkg.setScript(gmGroup, script) }
        }
        printDeep(gmGroup, text)
        if iconScript != 0 && iconTexture != 0 {
            if oneFrame { ensure(gmIcon, iconScript) } else { pkg.setScript(gmIcon, iconScript) }
            gmIcon?.handle = iconTexture
        } else { ensure(gmIcon, FEH.hide) }
        return true
    }
    var messageShowing: Bool { gmPriority > 0 }

    private func genericMessage() {
        guard gmPriority > 0 else { return }
        if !(gmGroup?.isRunning(gmScript) ?? false) || (gmOneFrame && gmFrames != 0) {
            ensure(gmGroup, FEH.hide)
            gmPriority = 0
            ensure(gmIcon, FEH.hide)
        }
        gmFrames += 1
    }

    private func raceMessage(_ m: RaceHUDMessage) {
        let s = assets.string
        switch m {
        case .checkpoint: requestMessage(s(0x2b7bdde4) ?? "", priority: 3)
        case .finalLap: requestMessage(s(0x55efd60c) ?? s(0x7a6f9f0a) ?? "", priority: 3)
        case .knockedOut(let name): requestMessage("\(name)\n\(s(0x5d82dba2) ?? "")", priority: 3)
        case .speedtrap(let mps):
            let v = mps * (assets.language == "english" ? 2.23694 : 3.6)
            requestMessage("\(FEHud.money(Int(v.rounded()))) \(s(assets.language == "english" ? 0x8569ab44 : 0x8569a25f) ?? "")", priority: 3)
        case .tollbooth(let t):
            // TimeExtension: «Tiempo extra» + tiempo con el icono del reloj [D]
            requestMessage("\(s(0x1c074e14) ?? "")\n+\(FEHud.timeString(t))", iconTexture: feHash("TIMER_ICON"), iconScript: 0x609f6b15, priority: 3)
        case .wrongWay(let on): race?.wrongWay = on
        case .text(let hash): requestMessage(s(hash) ?? "", priority: 3)
        case .custom(let t): requestMessage(t, priority: 3)
        }
    }

    // MARK: Carrera

    private func countdown() {
        // Countdown::Update: 3 (0x3c3c2f7), 2 (0xe479), 1 (0xce01), ¡YA! (0x535 + texto 0x61223ab5) y se oculta [D]
        guard let race else { if cdShown != -1 { cdShown = -1; ensure(cdGroup, FEH.hide) }; return }
        let v = race.countdown
        guard v != cdShown else { return }
        cdShown = v
        switch v {
        case 3, 2, 1:
            pkg.setScript(cdGroup, v == 3 ? 0x3c3c2f7 : v == 2 ? 0xe479 : 0xce01)
            pkg.printf(cdText, "\(v)"); pkg.printf(cdShadow, "\(v)")
        case 0:
            pkg.setScript(cdGroup, 0x535)
            pkg.setLabel(cdText, 0x61223ab5); pkg.setLabel(cdShadow, 0x61223ab5)
        default: ensure(cdGroup, FEH.hide)
        }
    }

    private func raceInformation() {
        guard let r = race else { return }
        // RaceInformation::Update [D]
        if r.setup.kind == .tollbooth {
            ensure(riPosGroup, FEH.hide); ensure(riToll, FEH.appear)
            pkg.printf(riTollTop, "\(r.speedtrapPassed)"); pkg.printf(riTollBot, "\(r.checkpointCount)")
        } else {
            ensure(riPosGroup, FEH.initScript); ensure(riToll, FEH.hide)
            pkg.printf(riPos, "\(r.position)"); pkg.printf(riCount, "\(r.racerCount)")
        }
        switch r.setup.kind {
        case .sprint, .speedtrap, .tollbooth:
            pkg.setLabel(riComplete, 0x59BB1918)
            pkg.printf(riPercent, "\(Int(r.percentComplete)) %")
        default:
            pkg.setLabel(riComplete, 0xBF9C)
            pkg.printf(riPercent, "\(r.lap)/\(r.laps)")
        }
        pkg.printf(riLapTime, FEHud.timeString(r.lapTime ?? r.raceTime))
    }

    private func leaderboard() {
        // LeaderBoard::Update con LeaderboardOn [D]; en la zona libre no hay corredores y se vacía
        ensure(lbGroup, FEH.initScript)
        let rs = (race?.racers ?? []).sorted { ($0.position == 0 ? Int.max : $0.position) < ($1.position == 0 ? Int.max : $1.position) }
        let n = race == nil || race?.setup.kind == .pursuit ? 0 : rs.count
        let playerIndex = rs.firstIndex { $0.isPlayer } ?? -1
        lbFrames -= 1
        if lbFrames <= 0 {
            var toggle = false
            for i in 0..<min(n, 4) {
                if lbFrames == 0 { pkg.setScript(lbText[i], FEH.leave) }
                else if let t = lbText[i], t.isScript(FEH.leave), !t.isRunning(FEH.leave) { pkg.setScript(t, FEH.appear); toggle = true }
            }
            if toggle { lbFrames = 90; lbShowTimes.toggle() }
        }
        var clearFrom = n
        if n > 1 {
            for i in 0..<min(n, 4) {
                let r = rs[i]
                if lbShowTimes {
                    if r.knockedOut { pkg.printf(lbText[i], assets.string(0x5d82dba2) ?? "") }
                    else if race?.setup.kind == .speedtrap {
                        // Radares: suma de velocidades de cada corredor [D]
                        let en = assets.language == "english"
                        pkg.printf(lbText[i], "\(FEHud.money(Int((r.speedTrapMps * (en ? 2.23694 : 3.6)).rounded()))) \(assets.string(en ? 0x8569ab44 : 0x8569a25f) ?? "")")
                    } else if i == playerIndex { pkg.printf(lbText[i], "-----") }
                    else {
                        let unit = assets.language == "english" ? 0x2e8496b1 : 0xe2078322 as UInt32
                        let d = assets.language == "english" ? abs(r.gap) * 3.28084 : abs(r.gap)
                        pkg.printf(lbText[i], "\(r.gap >= 0 ? "+" : "-")\(FEHud.money(Int(d))) \(assets.string(unit) ?? "m")")
                    }
                } else {
                    pkg.printf(lbText[i], r.name)
                    pkg.printf(lbNum[i], "\(i + 1)")
                }
                pkg.setVisible(lbText[i], true); pkg.setVisible(lbNum[i], true); pkg.setVisible(lbBack[i], true)
            }
        } else { clearFrom = 0 }
        for i in stride(from: clearFrom, to: 4, by: 1) {
            pkg.setVisible(lbText[i], false); pkg.setVisible(lbNum[i], false); pkg.setVisible(lbIcon[i], false); pkg.setVisible(lbBack[i], false)
        }
        for i in 0...3 { ensure(lbBack[i], i == playerIndex ? 0x249db7b7 : FEH.initScript) }
    }

    private func wrongWay(dt: Float) {
        // WrongWIndi: aparece tras 2 s en sentido contrario y se va 2 s después de corregir [D]
        let ww = race?.wrongWay ?? false
        if ww != wrongWayShown { wrongWayTimer = 0; wrongWayShown = ww }
        if wrongWayTimer >= 0 {
            wrongWayTimer += dt
            if wrongWayTimer >= 2 {
                wrongWayTimer = -1
                ensure(wrongWayImage, ww ? 0x908e787e : FEH.hide)   // panorámico (la pantalla del Mac lo es)
            }
        }
    }

    private func dragTachometer(_ i: HudInput) {
        // DragTachometer::CalcAngleForRPMDrag: −43°…44,5° [D]
        let factor = max(0, min(1, i.rpm / maxRpmTexture))
        dragNeedle?.setRotationZ(factor * (44.5 + 43) - 43)
        if let g = dragGear { pkg.printf(g, gearLetter(i.gear)); g.setColor(i.shifting ? 0x88FF_FFFF : 0xFFFF_FFFF) }
    }

    private func shiftUpdater(_ i: HudInput) {
        let q = race?.shiftQuality ?? 0
        switch q {
        case 1: ensure(shiftLight, feHash("PulseBlue")); pkg.setVisible(shiftLight, true); pkg.setVisible(overheatGroup, false)
        case 2: ensure(shiftLight, feHash("PulseGreen")); pkg.setVisible(shiftLight, true); pkg.setVisible(overheatGroup, false)
        case 3: ensure(shiftLight, feHash("PulseRed")); pkg.setVisible(shiftLight, true); pkg.setVisible(overheatGroup, false)
        default: pkg.setVisible(shiftLight, false); pkg.setVisible(overheatGroup, false)
        }
    }

    private func engineTemp() {
        let t = race?.engineTemp ?? 0
        if var pr = engineBar?.pivotRot { pr.z = t * 26.5 - 26.5; engineBar?.pivotRot = pr }
        ensure(engineBar, t > 0.5 ? feHash("OVERHEAT_PULSE") : FEH.initScript)
        ensure(engineIcon, t > 0.5 ? feHash("OVERHEAT_PULSE") : t > 0.1 ? feHash("ACTIVATE") : FEH.initScript)
    }

    // MARK: Radar (Minimap) [D: FeMinimap.cpp]

    /// Mapa que muestra el radar: en la zona libre MINI_MAP (MINI_MAP_UNLOCK_1/2 según la Lista Negra); en una carrera el de
    /// su evento (MINI_MAP_<id con «_»>) — RaceHUDSetup.minimap.
    var minimapName = "MINI_MAP"

    private func convertPos(_ p: SIMD2<Float>, _ c: FEAssets.MinimapIndex.Calib) -> SIMD2<Float> {
        SIMD2((p.x - c.upperLeft[0]) / c.widthMetres, (c.upperLeft[1] - p.y) / c.widthMetres + 1)
    }

    private func minimap(_ i: HudInput) {
        guard let pp = i.playerPos, let calib = assets.minimaps?.calibration, let layout = mmLayout else { return }
        let name = race?.setup.minimap ?? minimapName
        if name != mmMap { if assets.loadMinimap(name) { mmMap = name } else if assets.loadMinimap("MINI_MAP") { mmMap = "MINI_MAP" } }
        // SetupMinimap: 4 trozos alrededor del coche; la rejilla se desplaza y gira sobre el coche [D]
        let n = 8
        let mp = convertPos(pp, calib) * Float(n)
        let xs = Int(floor(mp.x)), ys = Int(floor(mp.y))
        var xd = mp.x - Float(xs), yd = mp.y - Float(ys)
        var chops: [Int]
        if xd < 0.5 {
            if yd < 0.5 { chops = [(ys - 1) * n + xs - 1, (ys - 1) * n + xs, ys * n + xs - 1, ys * n + xs] }
            else { chops = [ys * n + xs - 1, ys * n + xs, (ys + 1) * n + xs - 1, (ys + 1) * n + xs]; yd -= 1 }
        } else {
            if yd < 0.5 { chops = [(ys - 1) * n + xs, (ys - 1) * n + xs + 1, ys * n + xs, ys * n + xs + 1]; xd -= 1 }
            else { chops = [ys * n + xs, ys * n + xs + 1, (ys + 1) * n + xs, (ys + 1) * n + xs + 1]; xd -= 1; yd -= 1 }
        }
        if ProcessInfo.processInfo.environment["ROCKPORT_MM_DEBUG"] != nil { print("radar: pos \(pp) dir \(i.playerDir) mapa \(mp / Float(n)) trozos \(chops)") }
        if ProcessInfo.processInfo.environment["ROCKPORT_MM_NORTH"] != nil { minimapRotates = false }
        let zoom: Float = 1   // mSpeedZoomScale: 1 − v/MinimapMaxSpeed con mínimo 1 ⇒ siempre 1 (sin zoom por velocidad) [D]
        for (k, piece) in mmPieces.enumerated() {
            guard let piece else { continue }
            let c = chops[k]
            let valid = c >= 0 && c < n * n && xs >= 0 && ys >= 0 && xs < n && ys < n
            piece.handle = valid ? feHash("\(mmMap)_CHOP\(c)") : 0
            let (tl, br) = mmPieceUVs[k]
            setMaskUV(piece, tl - SIMD2(xd, yd) * zoom, br - SIMD2(xd, yd) * zoom)
        }
        let xDisp = xd * zoom * 128, yDisp = yd * zoom * 128
        layout.pos = SIMD3(mmDefaultPos.x - xDisp, mmDefaultPos.y - yDisp, mmDefaultPos.z)
        layout.locked.formUnion(4...6)
        layout.data[4] = xDisp + mmPivotX; layout.data[5] = yDisp; layout.data[6] = 0
        // Rumbo: ángulo de la dirección del coche (bATan(x, y) del vector [D]; 0° = este del mapa, sentido de las agujas en pantalla)
        mmTarget = convertPos(pp, calib)
        mmRotation = atan2(i.playerDir.y, i.playerDir.x) * 180 / .pi
        // UpdateTrackMapArt: el mapa gira para que el coche mire hacia arriba (la flecha del coche apunta arriba) [D][I: signo]
        let mapRot = 90 - mmRotation
        if minimapRotates {
            mmPlayer?.setRotationZ(0)
            layout.setRotationZ(-mapRot)
            mmNorth?.setRotationZ(-mapRot)
        } else {
            mmPlayer?.setRotationZ(mapRot)
            layout.setRotationZ(0); mmNorth?.setRotationZ(0)
        }
        // Policía (UpdateCopElements): parpadeo azul/rojo de los que persiguen; gris los demás
        mmFlash += 1; if mmFlash > 7 { mmFlash = 0 }
        var ci = 0
        var heli = false
        for c in i.cops {
            if c.heli {
                heli = true
                if let hg = mmHeli { placeIcon(c.pos, c.dir, hg, calib, minimapRotates ? -mapRot : 0) }
                continue
            }
            guard ci < 8, let o = mmCops[ci] else { break }
            placeIcon(c.pos, c.dir, o, calib, minimapRotates ? -mapRot : 0)
            var col: UInt32 = 0xFFCCCCCC
            if c.inPursuit { if mmFlash < 3 { col = 0xFF0000FF } else if mmFlash >= 4 && mmFlash < 7 { col = 0xFFA00000 } }
            o.setColor((col & 0x00FFFFFF) | (UInt32(o.data[3]) << 24))
            ci += 1
        }
        for k in ci..<8 { pkg.setVisible(mmCops[k], false) }
        if !heli { pkg.setVisible(mmHeli, false); pkg.setVisible(mmHeliLOS, false) }
        // Rivales (UpdateAiRacerElements) y punto de control
        var ri = 0
        for b in race?.blips ?? [] where ri < 8 {
            if let o = mmRacers[ri] { placeIcon(SIMD2(b.x, b.y), SIMD2(1, 0), o, calib, minimapRotates ? -mapRot : 0) }
            ri += 1
        }
        for k in ri..<8 { pkg.setVisible(mmRacers[k], false) }
        if let cp = race?.nextCheckpoint, let o = mmCheckpoint {
            placeIcon(SIMD2(cp.x, cp.y), SIMD2(1, 0), o, calib, minimapRotates ? -mapRot : 0); o.setRotationZ(0)
        } else { pkg.setVisible(mmCheckpoint, false) }
        pkg.setVisible(mmGPS, false)
    }

    /// UpdateElementArt: posición en el radar (recortada al borde a 0,06 del mapa), giro y alfa por distancia [D].
    private func placeIcon(_ pos: SIMD2<Float>, _ dir: SIMD2<Float>, _ o: FEObj, _ calib: FEAssets.MinimapIndex.Calib, _ layoutRot: Float) {
        let m = convertPos(pos, calib)
        let ex = (m.x - mmTarget.x), ey = (m.y - mmTarget.y)
        // Mismo giro que la rejilla del mapa (en el sentido de FEngSetRotationZ) para que los iconos caigan sobre las calles
        let a = layoutRot * .pi / 180
        var rx = ex * cos(a) - ey * sin(a), ry = ex * sin(a) + ey * cos(a)
        var dist = (rx * rx + ry * ry).squareRoot()
        var alpha: Float = 1
        if dist > 0.06 {
            let s = 0.06 / dist
            rx *= s; ry *= s
            if dist > 0.125 { alpha = 1 - (dist - 0.125) * 9.523809 }
            if dist > 0.23 { alpha = 0 }
            dist = 0.06
        }
        o.pos = SIMD3(mmCentre.x + rx * 1024, mmCentre.y + ry * 1024, o.pos.z)
        pkg.setVisible(o, true)
        let heading = atan2(dir.y, dir.x) * 180 / .pi
        o.setRotationZ(90 - heading + layoutRot)
        o.data[3] = Float(Int(max(0, alpha) * 255))
        o.locked.formUnion(0...3)
    }

    private func setMaskUV(_ o: FEObj, _ tl: SIMD2<Float>, _ br: SIMD2<Float>) {
        guard o.data.count > 28 else { return }
        o.locked.formUnion([21, 22, 27, 28])
        o.data[21] = tl.x; o.data[22] = tl.y; o.data[27] = br.x; o.data[28] = br.y
    }
    private func setMultiBR(_ o: FEObj?, _ br: SIMD2<Float>) {
        guard let o, o.data.count > 20 else { return }
        o.locked.formUnion([19, 20])
        o.data[19] = br.x; o.data[20] = br.y
    }

    // MARK: Utilidades

    private func ensure(_ o: FEObj?, _ s: UInt32) { if let o, !o.isScript(s) { pkg.setScript(o, s) } }
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
    /// FEPrintf sobre un grupo: escribe en todas sus cadenas (texto y sombra).
    private func printDeep(_ o: FEObj?, _ s: String) {
        guard let o else { return }
        if o.type == 2 { pkg.printf(o, s) }
        for c in o.children { printDeep(c, s) }
    }

    /// Timer::PrintToString(…, 4) en castellano/inglés: «h:mm:ss», « m:ss.cc», «ss.cc» o «0.cc» (cifra inicial sin cero) [D].
    static func timeString(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let total = Int(t * 100)
        let cs = total % 100, s = (total / 100) % 60, m = (total / 6000) % 60, h = total / 360000
        func lead(_ v: Int) -> String { v < 10 ? " \(v)" : "\(v)" }
        if h > 0 { return "\(lead(h)):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        if m > 0 { return "\(lead(m)):\(String(format: "%02d", s)).\(String(format: "%02d", cs))" }
        if s > 0 { return "\(lead(s)).\(String(format: "%02d", cs))" }
        return "0.\(String(format: "%02d", cs))"
    }

    /// «%$d» del juego: miles con coma (bSPrintf con «$»: separador de miles) [I: así sale en las capturas del juego].
    static func money(_ v: Int) -> String {
        let s = String(abs(v))
        var out = ""
        for (k, ch) in s.reversed().enumerated() { if k > 0 && k % 3 == 0 { out.append(",") }; out.append(ch) }
        return (v < 0 ? "-" : "") + String(out.reversed())
    }
}

extension FEObj {
    /// FEngIsScriptRunning: ese script está puesto y no ha llegado al final (los de bucle siempre corren) [D].
    func isRunning(_ id: UInt32) -> Bool {
        guard let s = script, s.id == id else { return false }
        if s.flags & 3 != 0 { return true }
        return time <= s.length
    }
}

extension Array {
    subscript(opt i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
