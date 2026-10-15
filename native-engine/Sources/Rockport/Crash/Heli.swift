// Helicóptero de la policía (copheli) en las persecuciones de calor alto.
// Fuentes [D]: AI/Common/AIVehicleHelicopter.cpp (combustible HeliFuelTime, línea de visión CanSeeTarget con
// kHeliVisualSphere = 75 m y heliLOSdistance, OnDriving con LeadPositionTime 0,45 s, frenada con Min/Max_Chopper_Accel
// 30/80 y Chopper_Ratio 2, altura mínima por la HeliSheet), AI/Actions/AIActionHeliPursuit.cpp (persecución en línea recta
// por delante del jugador 30–45 m y 6–12 m por encima, búsqueda en círculo alrededor del último punto visto con
// SearchModeRoadblockRadius) y Physics/Behaviors/SimpleChopper.cpp (velocidad deseada → aceleración limitada, MAX_SPEED_MPS,
// cabeceo y alabeo con PITCH_ANG/ROLL_ANG y sus ALIGN_SCALE, guiñada hacia el punto de mira ×8 limitada a 1,3 rad/s).
// Datos [V]: pursuitlevels (cops con COPHELI en calor 4 y 5, HeliFuelTime, TimeBetweenHeliActive, heliLOSdistance),
// physics.json copheli (chopperspecs), cars/COPHELI.glb, effects/heli-sheet.json (51 504 triángulos), sonido
// IG_GLOBAL/FX_HELICOPTER_MB.ABK (golpes de pala: SoundHeli no está portado, ritmo de pala propio [I]).
// Espacio: el juego usa Y arriba; aquí todo en el mundo del motor (Z arriba): «altura» = z.
import Foundation
import simd

/// HeliSheet [D: World/HeliSheet.cpp]: altura mínima de vuelo = plano del triángulo que contiene (x, y).
final class HeliSheet {
    private var tris: [Float] = []                 // 9 por triángulo (x0 y0 z0 x1 y1 z1 x2 y2 z2)
    private var grid: [SIMD2<Int32>: [Int32]] = [:]
    static let cell: Float = 32
    private(set) var count = 0

    init?(root: URL) {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("effects/heli-sheet.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let secs = j["sections"] as? [String: [NSNumber]] else { return nil }
        for (_, v) in secs {
            var i = 0
            while i + 8 < v.count {
                // s16 [x0,x1,x2, y0,y1,y2, z0,z1,z2]; x, y × 0,25 m; z × 0,0625 m [V]
                let x = [v[i], v[i + 1], v[i + 2]].map { $0.floatValue * 0.25 }
                let y = [v[i + 3], v[i + 4], v[i + 5]].map { $0.floatValue * 0.25 }
                let z = [v[i + 6], v[i + 7], v[i + 8]].map { $0.floatValue * 0.0625 }
                let t = Int32(tris.count / 9)
                tris += [x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2]]
                let c0 = SIMD2(Int32((x.min()! / HeliSheet.cell).rounded(.down)), Int32((y.min()! / HeliSheet.cell).rounded(.down)))
                let c1 = SIMD2(Int32((x.max()! / HeliSheet.cell).rounded(.down)), Int32((y.max()! / HeliSheet.cell).rounded(.down)))
                if c0.x <= c1.x && c0.y <= c1.y && c1.x - c0.x < 64 && c1.y - c0.y < 64 {
                    for cy in c0.y...c1.y { for cx in c0.x...c1.x { grid[SIMD2(cx, cy), default: []].append(t) } }
                }
                i += 9
            }
        }
        count = tris.count / 9
    }

    /// GetElevation [D]: nil fuera de la hoja.
    func elevation(x: Float, y: Float) -> Float? {
        guard let l = grid[SIMD2(Int32((x / HeliSheet.cell).rounded(.down)), Int32((y / HeliSheet.cell).rounded(.down)))] else { return nil }
        var best: Float? = nil
        for t in l {
            let b = Int(t) * 9
            let ax = tris[b], ay = tris[b + 1], bx = tris[b + 3], by = tris[b + 4], cx = tris[b + 6], cy = tris[b + 7]
            let den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(den) < 1e-6 { continue }
            let u = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / den
            let v = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / den
            let w = 1 - u - v
            if u < -1e-3 || v < -1e-3 || w < -1e-3 { continue }
            let z = u * tris[b + 2] + v * tris[b + 5] + w * tris[b + 8]
            best = max(best ?? -1e9, z)
        }
        return best
    }
}

final class PoliceHeli {
    enum Mode { case straightLine, search, exit }
    let vehicle: AIVehicle                         // para dibujarlo con AIRenderer (modelo COPHELI)
    var pos: float3
    var vel = float3(0, 0, 0)
    var yaw: Float, pitch: Float = 0, roll: Float = 0
    var yawRate: Float = 0, pitchRate: Float = 0, rollRate: Float = 0
    var fuel: Float
    var mode: Mode = .straightLine
    var seesPlayer = false
    var lastSaw = float3(0, 0, 0)
    private var perpHidden = false
    private var searchDest = float3(0, 0, 0)
    private var searchAngle: Float = 0
    private var prevVel = float3(0, 0, 0)
    private var lastAccel = float3(0, 0, 0)
    private var lastAngVel = float3(0, 0, 0)
    private var losTimer: Float = 0
    private var rng = SplitMix(seed: 0x4E11)
    // chopperspecs [V: physics.json copheli → "default"]
    var maxSpeed: Float = 100, pitchAng: Float = 0.05, rollAng: Float = 0.06, pitchAlign: Float = 6, rollAlign: Float = 4.5
    static let leadPositionTime: Float = 0.45, visualSphere: Float = 75
    static let minAccel: Float = 30, maxAccel: Float = 80, ratio: Float = 2

    init(vehicle: AIVehicle, pos: float3, yaw: Float, fuel: Float) {
        self.vehicle = vehicle; self.pos = pos; self.yaw = yaw; self.fuel = fuel
        if let c = CrashWorld.data?.vehicles["copheli"] {
            _ = c   // masa y cuerpo no influyen en SimpleChopper (todo son aceleraciones)
        }
    }

    var fwd: float3 { float3(cos(yaw), sin(yaw), 0) }

    /// CanSeeTarget [D]: dentro de 75 m siempre; hasta heliLOSdistance si el jugador está por delante; sin muros entre
    /// los dos; en un túnel no (aquí: hoja del helicóptero muy por encima del jugador) [I]. Si lo pierde cerca del último
    /// punto visto (< 20 m, a menos de 150 m) sigue «viéndolo».
    func canSee(_ target: float3, losDistance: Float, collision: CollisionWorld, sheet: HeliSheet?, hidden: Bool) -> Bool {
        if hidden && perpHidden { return false }
        perpHidden = false
        let to = target - pos
        let d = simd_length(to)
        var inSight = d <= PoliceHeli.visualSphere
        if !inSight && d < losDistance { inSight = simd_dot(fwd, to / max(d, 1e-3)) > 0 }
        if inSight {
            if let s = sheet, let h = s.elevation(x: target.x, y: target.y), h > target.z + 12 { inSight = false }   // túnel / paso cubierto
            else {
                // Línea de visión contra los muros de la colisión, por tramos de 15 m [I: CheckHitWorld]
                let n = max(1, Int(d / 15))
                for k in 0..<n {
                    let a = pos + to * (Float(k) / Float(n)), b = pos + to * (Float(k + 1) / Float(n))
                    if collision.hitsWall(from: a - float3(0, 0, 1), to: b - float3(0, 0, 1)) { inSight = false; break }
                }
                if inSight { lastSaw = target }
            }
        }
        if !inSight {
            if hidden { perpHidden = true }
            else if d < PoliceHeli.visualSphere * 2 && simd_distance_squared(target, lastSaw) < 400 { return true }
            return false
        }
        return true
    }

    /// Un paso: decisión (AIActionHeliPursuit), conducción (AIVehicleHelicopter::OnDriving) y vuelo (SimpleChopper).
    func update(dt: Float, player p: AIPlayer, inSight: Bool, lastKnown: float3, searchRadius: Float, sheet: HeliSheet?, camera: float3) {
        fuel -= dt
        if fuel <= 0 && mode != .exit { mode = .exit }
        var dest: float3, driveSpeed: Float, look: float3, destVel = float3(0, 0, 0)
        switch mode {
        case .exit:
            // AIActionHeliExit [D: subir y alejarse]
            dest = pos + fwd * 200 + float3(0, 0, 60)
            driveSpeed = 45; look = dest
        case .search, .straightLine:
            if !inSight && mode != .search { mode = .search; nextSearchDest(lastKnown, searchRadius, sheet) }
            else if inSight && mode == .search { mode = .straightLine }
            if mode == .search {
                // SearchForPerp [D]
                if simd_distance(SIMD2(pos.x, pos.y), SIMD2(searchDest.x, searchDest.y)) < 30 { nextSearchDest(lastKnown, searchRadius, sheet) }
                dest = searchDest; driveSpeed = 70; look = searchDest; destVel = vel
            } else {
                // StraightLinePursuit [D]
                let pf = simd_length(p.vel) > 1 ? simd_normalize(p.vel) : p.fwd
                var lead = abs(p.speed) * 0.4 + 30; if lead > 45 { lead = 45 }
                var seek = p.pos + pf * lead
                let toPerp = simd_distance(pos, p.pos)
                seek.z += toPerp > 55 ? 12 : 6
                let chase = seek.z
                var me2seek = seek - pos; me2seek.z = 0
                let dist = simd_length(me2seek)
                me2seek = dist > 1e-3 ? me2seek / dist : float3(1, 0, 0)
                var adjust = simd_dot(me2seek, p.vel); if adjust < 0 { adjust *= 0.5 }
                var closing: Float
                look = seek
                if dist > 15 { closing = dist > 300 ? 50 : 30 }
                else { closing = dist > 3 ? 20 : dist; if dist < 5 && abs(p.speed) < 15 { look = p.pos } }
                driveSpeed = adjust + closing
                destVel = p.vel
                seek.z = chase
                dest = seek
            }
        }
        // FilterHeliAltitude [D]: nunca por debajo de la hoja
        if let s = sheet, let h = s.elevation(x: dest.x, y: dest.y), dest.z < h { dest.z = h }
        // OnDriving [D]
        var dv = destVel * 9; dv = dv + destVel * 0.1      // SetDestinationVelocity: v·9 + v·0,1
        var comp = dv; comp.z = 0
        dest += comp * PoliceHeli.leadPositionTime
        let working = pos + vel * PoliceHeli.leadPositionTime
        // CheckHeliSheet [D, simplificado]: si el punto adelantado queda bajo la hoja, se sube el destino
        if let s = sheet, let h = s.elevation(x: working.x, y: working.y), working.z < h { dest.z = max(dest.z, h + 2) }
        var move = dest - working
        let moveLen = simd_length(move)
        var yDelt = move.z
        move.z = 0
        let vdif = vel - comp
        let unit = simd_length(move) > 1e-3 ? simd_normalize(move) : float3(0, 0, 0)
        let closingSpeed = simd_dot(vdif, unit), closingRaw = simd_dot(vel, unit)
        var maxDecel = false
        if closingSpeed > 3 {
            let avail = min(PoliceHeli.maxAccel, simd_length(vel) * 0.2 + PoliceHeli.minAccel)
            let use = min(avail, closingSpeed * PoliceHeli.ratio)
            let D = closingSpeed * closingSpeed / (1.55 * use)
            if moveLen <= D { driveSpeed *= 0.4; maxDecel = true }
        } else if closingRaw < -1 && moveLen < 15 { maxDecel = true }
        if moveLen > 2 { move *= driveSpeed / moveLen }
        if yDelt >= 0 && yDelt < 7 { yDelt *= 5; if dv.z > 0 { yDelt += dv.z * 2 } }
        else if yDelt < 0 && yDelt > -5 { yDelt *= 3; if dv.z < 0 { yDelt += dv.z } }
        move.z = yDelt
        fly(dt: dt, desired: move, facing: look - pos, maxDecel: maxDecel)
        // Ocupación del modelo: el AIVehicle que lo dibuja (pos = punto bajo el modelo)
        vehicle.pos = pos - float3(0, 0, vehicle.model.height * 0.5)
        vehicle.yaw = yaw; vehicle.pitch = pitch; vehicle.roll = roll
        vehicle.speed = simd_length(vel)
        vehicle.lights = true
    }

    private func nextSearchDest(_ centre: float3, _ radius: Float, _ sheet: HeliSheet?) {
        // SetNextPerpSearchDest [D]: radio 0,2…0,9 × SearchModeRoadblockRadius, ángulo +1/8 de vuelta
        let r = rng.range(0, radius * 0.7) + radius * 0.2
        searchAngle += 0.125; if searchAngle >= 1 { searchAngle -= 1 }
        let a = searchAngle * 2 * .pi
        searchDest = centre + float3(cos(a), sin(a), 0) * min(r, 400)
        if let s = sheet, let h = s.elevation(x: searchDest.x, y: searchDest.y) { searchDest.z = max(searchDest.z, h) }
        searchDest.z += 5
    }

    /// SimpleChopper::OnTaskSimulate [D]: aceleración limitada hacia la velocidad deseada, cabeceo/alabeo por la aceleración,
    /// guiñada hacia `facing`.
    private func fly(dt: Float, desired d0: float3, facing: float3, maxDecel: Bool) {
        var desired = d0
        let ds = simd_length(desired)
        if ds > maxSpeed { desired *= maxSpeed / ds }
        var maxA = simd_length(vel) * 0.6 + PoliceHeli.minAccel
        if maxA > PoliceHeli.maxAccel || maxDecel { maxA = PoliceHeli.maxAccel }
        let dvel = desired - vel
        let fA = simd_length(dvel) * PoliceHeli.ratio
        let accel = fA > 1 && (fA > maxA || maxDecel) ? dvel * (maxA / fA) : dvel * PoliceHeli.ratio
        vel += accel * dt                                   // el rotor compensa la gravedad
        pos += vel * dt
        // Cabeceo y alabeo por la aceleración local (SetTorqueToMatchPitchAndRoll) [D]
        if dt > 0.005 {
            var a = (vel - prevVel) / dt
            let c = cos(yaw), s = sin(yaw)
            var local = float3(a.x * c + a.y * s, -a.x * s + a.y * c, a.z)   // x adelante, y izquierda
            lastAccel *= 4; local += lastAccel * 0.2; lastAccel = local
            let p = max(-0.1, min(0.1, -(local.x * (9 / PoliceHeli.maxAccel)) * pitchAng))
            let r = max(-0.1, min(0.1, (local.y * (12 / PoliceHeli.maxAccel)) * rollAng))
            pitch += max(-1, min(1, (p * 2 * .pi - pitch) * pitchAlign)) * dt
            roll += max(-1, min(1, (r * 2 * .pi - roll) * rollAlign)) * dt
            a = .zero
        }
        // Guiñada hacia el objetivo: −cruz × 8, ±1,3 rad/s, suavizada (7 ×, 1/8) [D]
        let f2 = SIMD2(facing.x, facing.y)
        if simd_length(f2) > 0.5 {
            let want = atan2(f2.y, f2.x)
            var w = max(-1.3, min(1.3, angleDiff(want, yaw) * 8 * 0.25))
            w = (yawRate * 7 + w) * 0.125
            yawRate = w
            yaw += yawRate * dt
        }
        prevVel = vel
    }
}

/// Gestor del helicóptero: aparición en calor alto, combustible, retirada, línea de visión para la policía, sonido.
final class HeliManager {
    unowned let ai: AIWorld
    let sheet: HeliSheet?
    private(set) var heli: PoliceHeli?
    private var cooldown: Float = 0               // TimeBetweenHeliActive tras irse [D]
    private var chopTimer: Float = 0, chopIndex = 0
    var spawnedCount = 0
    var log: [String] = []
    /// Para pruebas: aparece ya (sin esperar al retraso mínimo).
    var forceSpawn = false

    init(ai: AIWorld, root: URL) {
        self.ai = ai
        sheet = HeliSheet(root: root)
        if let s = sheet { print("Helicóptero: hoja de vuelo con \(s.count) triángulos") }
        ai.models.preload(["COPHELI"])
    }

    var active: Bool { heli != nil }

    func update(dt: Float, camera: float3) {
        let police = ai.police!
        guard let lv = police.level else { return }
        cooldown -= dt
        let heliInLevel = lv.cops.contains { $0.model == "COPHELI" }
        if heli == nil {
            let delay = ai.tables.supportDelay.indices.contains(Int(police.heat) - 1) ? ai.tables.supportDelay[Int(police.heat) - 1] : 30
            if police.inPursuit, police.state == .chase, ai.player.exists, cooldown <= 0,
               heliInLevel || forceSpawn, police.pursuitTime > min(delay, 20) || forceSpawn {
                spawn(fuel: lv.num("HeliFuelTime", 60))
            }
        }
        guard let h = heli else { police.heliSpotting = false; return }
        // Visión y vuelo
        let p = ai.player
        let hidden = ai.tables.inZone("hidden", float2(p.pos.x, p.pos.y))
        let sees = p.exists && h.mode != .exit && h.canSee(p.pos, losDistance: lv.num("heliLOSdistance", 250), collision: ai.collision, sheet: sheet, hidden: hidden)
        h.seesPlayer = sees
        police.heliSpotting = sees && police.inPursuit
        h.update(dt: dt, player: p, inSight: sees, lastKnown: police.lastKnownPosition, searchRadius: lv.num("SearchModeRoadblockRadius", 400), sheet: sheet, camera: camera)
        // Se va: sin persecución o sin combustible y lejos
        if !police.inPursuit && h.mode != .exit { h.mode = .exit }
        if h.mode == .exit && (simd_distance(h.pos, ai.center) > 500 || h.pos.z > ai.center.z + 250) {
            despawn()
            cooldown = lv.num("TimeBetweenHeliActive", 120)
        }
        sound(dt: dt, h)
    }

    private func spawn(fuel: Float) {
        guard let m = ai.models.model("COPHELI") else { return }
        let p = ai.player
        // Entra desde 250 m por detrás del jugador, a 60 m de altura [I]
        let back = -p.fwd
        var pos = p.pos + back * 250 + float3(0, 0, 60)
        if let s = sheet, let h = s.elevation(x: pos.x, y: pos.y) { pos.z = max(pos.z, h + 20) }
        let v = AIVehicle(id: ai.newID(), kind: .cop, model: m, typeName: "copheli")
        v.mode = .parked; v.lights = true
        let h = PoliceHeli(vehicle: v, pos: pos, yaw: atan2(-back.y, -back.x), fuel: fuel)
        if let c = CrashWorld.data?.vehicles["copheli"] { _ = c }
        heli = h
        ai.airVehicles = [v]
        spawnedCount += 1
        ai.stats.heliSpawned += 1
        ai.police.notifyHeliSpawned()
        log.append(String(format: "%.1f s: helicóptero (combustible %.0f s) en (%.0f, %.0f, %.0f)", ai.time, fuel, pos.x, pos.y, pos.z))
        print("Helicóptero: aparece (calor \(String(format: "%.2f", ai.police.heat)), combustible \(Int(fuel)) s)")
    }

    func despawn() {
        heli = nil
        ai.airVehicles = []
        ai.police.heliSpotting = false
        log.append(String(format: "%.1f s: helicóptero se retira", ai.time))
    }

    /// Golpes de pala con las muestras de IG_GLOBAL/FX_HELICOPTER_MB.ABK, 0…11 en orden [I: SoundHeli no portado].
    private func sound(dt: Float, _ h: PoliceHeli) {
        let sfx = SFXWorld.shared
        guard let lib = sfx.lib, let mixer = sfx.mixer, let bank = lib.miscBank("FX_HELICOPTER") else { return }
        chopTimer -= dt
        guard chopTimer <= 0 else { return }
        chopTimer += 1 / 8.5                               // ~8,5 golpes de pala por segundo [I]
        let d = sfx.listenerDistance(h.pos)
        guard d < 600, let smp = lib.sample(bank, chopIndex % 12) else { return }
        chopIndex += 1
        let sp = sfx.space(at: h.pos, velocity: h.vel, ref: 35, maxDistance: 600)
        let v = SFXSampleVoice(smp, loop: false, tag: "heli")
        let g: Float = 0.9 * SFXMix.siren
        v.params.gainL = sp.gainL * g; v.params.gainR = sp.gainR * g; v.params.pitch = sp.doppler; v.params.lowpass = max(1500, sp.lowpass)
        mixer.add(v)
    }

    /// Icono del radar (HUD_SingleRace: HELICOPTER_ICON_GROUP) [D: Minimap].
    var blip: HudBlip? {
        guard let h = heli else { return nil }
        return HudBlip(pos: SIMD2(h.pos.x, h.pos.y), dir: SIMD2(cos(h.yaw), sin(h.yaw)), inPursuit: true, heli: true)
    }
}
