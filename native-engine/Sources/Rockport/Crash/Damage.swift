// Daños de los coches como el juego [D: Physics/Behaviors/DamageVehicle.cpp OnImpact, DamageCopCar.cpp, World/DamageZones.h,
// World/CarRender.cpp SetPlayerDamage/SetCarGlassDamageState, World/VehiclePartDamage.cpp]:
//   · Zona del golpe por el brazo (punto de contacto en el espacio del coche) y la normal, con umbrales 0,5 (zona) y 0,8
//     (dirección) sobre la caja del cuerpo.
//   · ratio = fuerza / (FORCE × 1000); nivel de golpe = min(6, ratio × VisualScale); nivel de daño visual = min(2, …).
//   · Puntos de vida: ratio × HitPointScale / HIT_POINTS se suma si pasa de HP_THRESHOLD / HIT_POINTS; > 1 = destruido.
//   · Coches de carreras (sin VehiclePartDamageBehaviour): capa DAMAGE0_<ZONA> visible con daño > 0; cristal WINDOW_DAMAGE0
//     con daño > 1. Policía: paneles DAMAGE1_<PIEZA> en lugar de DAMAGE0_<PIEZA> por zona (tabla mSlotZoneMapList).
//   · «Fuerza» = impulso del choque en N·s [I: Moment::React no está decompilado; con esta unidad un policía aguanta
//     2–4 embestidas fuertes, como en el juego].
import Foundation
import simd

enum DamageZone: Int, CaseIterable {
    case front = 0, rear, left, right, lfront, rfront, lrear, rrear, top, bottom
    static let count = 10
    var attribute: String { ["DZ_FRONT", "DZ_REAR", "DZ_LEFT", "DZ_RIGHT", "DZ_LFRONT", "DZ_RFRONT", "DZ_LREAR", "DZ_RREAR", "DZ_TOP", "DZ_BOTTOM"][rawValue] }

    /// DamageVehicle::OnImpact [D]: arm y normal en el espacio del coche (x derecha, y arriba, z adelante), dim = medias medidas.
    static func of(arm: V3, normal n: V3, dim: V3) -> DamageZone {
        let kDir: Float = 0.8, kZone: Float = 0.5
        if arm.z > dim.z * kZone {
            if arm.x > dim.x * kZone && -kDir > n.x { return .rfront }
            if arm.x < -dim.x * kZone && kDir < n.x { return .lfront }
            return .front
        } else if arm.z < -dim.z * kZone {
            if arm.x > dim.x * kZone && -kDir > n.x { return .rrear }
            if arm.x < -dim.x * kZone && kDir < n.x { return .lrear }
            return .rear
        } else if arm.y > dim.y * kZone && n.y < -kDir {
            return .top
        } else if arm.y < -dim.y * kZone && kDir < n.y {
            return .bottom
        }
        return arm.x > 0 ? .right : .left
    }
}

/// Piezas que cambian con el daño en los coches de policía (CARSLOTID_DAMAGE_*) y sus zonas [D: VehiclePartDamage.cpp
/// mSlotZoneMapList]. Nombre = ranura del GLB sin el prefijo DAMAGE0_/DAMAGE1_.
enum DamageParts {
    static let slots = ["BODY", "COP_LIGHTS", "COP_SPOILER", "HOOD", "BUSHGUARD", "FRONT_BUMPER", "REAR_BUMPER", "TRUNK",
                        "LEFT_DOOR", "RIGHT_DOOR", "LEFT_REAR_DOOR", "RIGHT_REAR_DOOR", "LEFT_HEADLIGHT", "RIGHT_HEADLIGHT",
                        "LEFT_BRAKELIGHT", "RIGHT_BRAKELIGHT", "FRONT_WINDOW", "FRONT_LEFT_WINDOW", "FRONT_RIGHT_WINDOW",
                        "REAR_LEFT_WINDOW", "REAR_RIGHT_WINDOW", "REAR_WINDOW"]
    static func index(_ slot: String) -> Int? { slots.firstIndex(of: slot) }
    private static let lights = ["LEFT_BRAKELIGHT", "RIGHT_BRAKELIGHT", "LEFT_HEADLIGHT", "RIGHT_HEADLIGHT"]
    private static let windows = ["FRONT_WINDOW", "REAR_LEFT_WINDOW", "FRONT_LEFT_WINDOW", "FRONT_RIGHT_WINDOW", "REAR_RIGHT_WINDOW"]
    /// Ranuras de cada zona [D: mSlotZoneMapList, 120 entradas].
    static let zoneSlots: [DamageZone: [String]] = [
        .front: ["FRONT_BUMPER", "BUSHGUARD", "BODY", "HOOD", "COP_LIGHTS"] + lights + windows,
        .rear: ["TRUNK", "REAR_BUMPER", "BODY"] + lights + windows,
        .left: ["LEFT_DOOR", "LEFT_REAR_DOOR", "FRONT_LEFT_WINDOW", "REAR_LEFT_WINDOW", "COP_LIGHTS", "BODY"] + lights + windows,
        .right: ["RIGHT_DOOR", "RIGHT_REAR_DOOR", "BODY", "COP_LIGHTS"] + lights + windows,
        .lfront: ["HOOD", "BODY"] + lights + ["FRONT_LEFT_WINDOW"] + windows,
        .lrear: ["TRUNK", "BODY"] + lights + windows,
        .rfront: ["HOOD", "BODY"] + lights + windows,
        .rrear: ["TRUNK", "BODY"] + lights + windows,
        .top: ["BUSHGUARD", "COP_LIGHTS", "HOOD", "BODY", "TRUNK", "RIGHT_DOOR", "RIGHT_REAR_DOOR", "LEFT_DOOR", "LEFT_REAR_DOOR"] + lights + windows,
    ]
    /// Capa de golpes de los coches de carreras (DAMAGE0_<ZONA>) [D: SetPlayerDamage].
    static let overlayZones: [(slot: String, zone: DamageZone)] = [("FRONT", .front), ("REAR", .rear), ("FRONTLEFT", .lfront),
                                                                     ("FRONTRIGHT", .rfront), ("REARLEFT", .lrear), ("REARRIGHT", .rrear)]
}

/// Estado de daños de un coche (DamageVehicle + DamageZone::Info).
struct DamageState {
    var zones = [Int](repeating: 0, count: DamageZone.count)   // 0…2 (visual)
    var total: Float = 0                                        // mDamageTotal (1 = destruido)
    var shock: Float = 0                                        // mShockTimer 0…1
    var destroyed: Bool { total >= 1 }
    /// Ranuras rotas (bits de DamageParts.slots) para la policía.
    var brokenSlots: UInt32 = 0
    var anyVisual: Bool { zones.contains { $0 > 0 } }

    /// Resultado de un golpe: zona, nivel nuevo, si pasa a destruido.
    struct Hit { var zone: DamageZone; var impactLevel: Int; var newDamage: Bool; var destroyedNow: Bool; var ratio: Float }

    /// DamageVehicle::OnImpact [D]. `force` = fuerza del choque (N·s, ver arriba) ya doblada si es contra otro objeto.
    mutating func impact(specs: DamageSpecs, arm: V3, normal: V3, dim: V3, force: Float, canDamageVisuals: Bool = true) -> Hit? {
        let strength = specs.force * 1000
        guard strength > 0 else { return nil }
        let zone = DamageZone.of(arm: arm, normal: normal, dim: dim)
        let ratio = force / strength
        let vs = specs.visual[zone.rawValue], hs = specs.hitPoint[zone.rawValue]
        let impactLevel = min(6, Int(ratio * vs))
        let newLevel = min(2, Int(ratio * vs))
        var destroyedNow = false
        if specs.hitPoints > 0 && total < 1 {
            let pts = ratio * hs / specs.hitPoints
            if pts > specs.hpThreshold / specs.hitPoints {
                total += pts
                if total > 1 { destroyedNow = true }
            }
        }
        var newDamage = false
        if newLevel > 0 && canDamageVisuals && newLevel > zones[zone.rawValue] {
            zones[zone.rawValue] = newLevel
            newDamage = true
            for s in DamageParts.zoneSlots[zone] ?? [] { if let i = DamageParts.index(s) { brokenSlots |= 1 << UInt32(i) } }
        }
        // SetShockForce [D]: impulso / masa / SHOCK_FORCE → aturdido (la IA no conduce) hasta SHOCK_TIME
        return Hit(zone: zone, impactLevel: impactLevel, newDamage: newDamage, destroyedNow: destroyedNow, ratio: ratio)
    }

    /// DamageVehicle::Destroy [D]: todas las zonas al máximo.
    mutating func destroy() {
        if total < 1 { total = 1 }
        for i in zones.indices { zones[i] = max(zones[i], 2) }
        for z in DamageParts.zoneSlots.keys { for s in DamageParts.zoneSlots[z] ?? [] { if let i = DamageParts.index(s) { brokenSlots |= 1 << UInt32(i) } } }
    }

    mutating func shock(impulse: Float, mass: Float, specs: DamageSpecs) {
        guard specs.shockForce > 0, specs.shockTime > 0 else { return }
        let scale = impulse / max(mass, 1) / specs.shockForce
        if scale > 0.2 { shock = min(max(shock, scale), 1) }
    }

    mutating func update(dt: Float, specs: DamageSpecs?) {
        guard let s = specs, s.shockTime > 0 else { shock = 0; return }
        shock = max(0, shock - dt / s.shockTime)
    }
}
