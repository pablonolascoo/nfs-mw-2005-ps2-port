// Iconos del radar según el momento de la partida (Minimap::UpdateGameplayIcons + GManager::GatherVisibleIcons [D][G]).
// El juego dibuja cada GIcon activo y visible (banderas 1 y 2), del más cercano al más lejano, en los elementos de
// HUD_SingleRace de su tipo [V: nombres del ejecutable]: SAFEHOUSEINDICATOR_n (4), CAR_LOT_n (4), SHOP_n (8),
// MMICON_SPRINT/CIRCUIT/DRAG/KNOCKOUT/TOLLBOOTH/SPEEDTRAP_n (8 cada uno), MINIMAP_ICON_EVENT_RIVAL (1),
// SPEED_TRAP_CAM_n (8), PURSUIT_BREAKER_n (8) y HIDING_SPOT_n (8).
// Qué está activo en cada momento lo deciden los guiones y el avance; aquí, con los datos del disco:
//   · garajes (refugio, concesionario, taller): desde que se llega a su bin (BinIndex de la zona [V]: 16, 15, 12, 8)
//   · pruebas: los marcadores del mundo de la carrera profesional (los del bin actual y los ya superados)
//   · rival: cuando se le puede retar · radares de la zona libre del bin: hasta superarlos
//   · trampas para la policía: en persecución, las que siguen en pie · escondites: durante el enfriamiento [I]
// Fuera de la carrera profesional y en las pruebas no hay iconos de mundo (solo los de la prueba).
import Foundation
import simd

enum HudIconKind: CaseIterable {
    case safehouse, carLot, shop, sprint, circuit, drag, knockout, tollbooth, speedtrapRace, rival, speedCam, pursuitBreaker, hidingSpot
    /// Prefijo del elemento en HUD_SingleRace y cuántos hay [V].
    var element: (prefix: String, count: Int) {
        switch self {
        case .safehouse: ("SAFEHOUSEINDICATOR_", 4)
        case .carLot: ("CAR_LOT_", 4)
        case .shop: ("SHOP_", 8)
        case .sprint: ("MMICON_SPRINT_", 8)
        case .circuit: ("MMICON_CIRCUIT_", 8)
        case .drag: ("MMICON_DRAG_", 8)
        case .knockout: ("MMICON_KNOCKOUT_", 8)
        case .tollbooth: ("MMICON_TOLLBOOTH_", 8)
        case .speedtrapRace: ("MMICON_SPEEDTRAP_", 8)
        case .rival: ("MINIMAP_ICON_EVENT_RIVAL", 1)
        case .speedCam: ("SPEED_TRAP_CAM_", 8)
        case .pursuitBreaker: ("PURSUIT_BREAKER_", 8)
        case .hidingSpot: ("HIDING_SPOT_", 8)
        }
    }
    static func race(_ k: RaceEvent.Kind) -> HudIconKind? {
        switch k {
        case .sprint: .sprint; case .circuit: .circuit; case .drag: .drag; case .knockout: .knockout
        case .tollbooth: .tollbooth; case .speedtrap: .speedtrapRace; case .challenge: nil
        }
    }
}

struct HudIcon { let kind: HudIconKind; let pos: SIMD2<Float> }

enum MapIcons {
    static func gather(_ e: Engine) -> [HudIcon] {
        var out: [HudIcon] = []
        let career = Career.shared
        guard career.active, RaceSystem.shared?.session == nil else { return out }
        let bin = career.save.currentBin
        let p2 = { (p: float3) in SIMD2(p.x, p.y) }
        let pol = e.ai?.police
        // Garajes: desde su bin. En el D-Day solo lo que pide el guion (concesionario tras el arresto, refugio al ir al garaje)
        let pro = Prologue.shared
        for z in e.data.zones where z.position.count >= 2 {
            let kind: HudIconKind
            switch z.zoneType { case "safehouse": kind = .safehouse; case "carlot": kind = .carLot; case "customshop": kind = .shop; default: continue }
            let zb = z.binIndex ?? 15
            let on: Bool
            if bin > 15 { on = (kind == .carLot && pro.waitingForCar && zb == 15) || (kind == .safehouse && pro.drive != nil && zb == 16) }
            else { on = bin <= zb }
            if on { out.append(HudIcon(kind: kind, pos: SIMD2(z.position[0], z.position[1]))) }
        }
        guard bin <= 15, pol?.inPursuit != true else {
            appendPursuit(e, &out)
            return out
        }
        // Pruebas del mundo y rival
        for ev in RaceSystem.shared?.worldEvents ?? [] {
            guard let g = ev.engage, let k = HudIconKind.race(ev.kind) else { continue }
            out.append(HudIcon(kind: k, pos: p2(g.p)))
        }
        if career.canChallengeRival(), let r = career.nextBossRace(), let p = r.engage?.p ?? r.start?.p { out.append(HudIcon(kind: .rival, pos: p2(p))) }
        // Radares de la zona libre del bin aún sin superar
        if let b = career.bin(), let db = career.db {
            for id in b.milestones where !career.save.milestonesDone.contains(id) {
                if let m = db.milestone(id), m.type == "speedtrap", let p = m.pos, p.count >= 2 { out.append(HudIcon(kind: .speedCam, pos: SIMD2(p[0], p[1]))) }
            }
        }
        return out
    }

    private static func appendPursuit(_ e: Engine, _ out: inout [HudIcon]) {
        guard let pol = e.ai?.police, pol.inPursuit else { return }
        for b in e.ai?.crash?.breakers.list ?? [] where !b.triggered { out.append(HudIcon(kind: .pursuitBreaker, pos: SIMD2(b.pos.x, b.pos.y))) }
        if pol.state == .cooldown {
            for z in e.ai?.tables.zones ?? [] where z.type == "hidden" && !z.points.isEmpty {
                let c = z.points.reduce(float2(0, 0), +) / Float(z.points.count)
                out.append(HudIcon(kind: .hidingSpot, pos: c))
            }
        }
    }
}
