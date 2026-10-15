// Derrumbes de persecución («pursuit breakers»): gasolineras, depósitos de agua, andamios, techos, gazebos, la noria…
// Datos [V]: 38 marcadores TrackPositionMarker *Moment de L2RA.BUN (GasStationMoment ×9, ScaffoldingCollapseMoment ×7,
// WaterTowerMoment ×3, TorusRoofMoment ×3…) y los rompibles de estructura que hay alrededor (smackable *support*,
// scaffolding, gasstationroof, watertower…). En el juego los encadena un EventSequencer (*_seq de cada smackable) y al
// caer avisa a la policía con MBreakerStopCops(posición, duración, radio) [D: mensaje Generated/Messages] y suena la
// música de «pursuit breaker» (MPursuitBreaker) [D]. Los EventSequencer no están decompilados ni exportados [I]:
//   · Grupo = rompibles de estructura a menos de 45 m del marcador.
//   · Se dispara cuando el jugador suelta uno de ellos (su DETACH_FORCE ≥ 0) [I].
//   · Se sueltan todos los del grupo y caen con la gravedad del rigidbodyspecs [I].
//   · Los policías de la persecución a menos de 30 m durante 3 s quedan inmovilizados (cuentan como destruidos) [I].
import Foundation
import simd

final class PursuitBreakers {
    final class Breaker {
        let name: String
        let pos: float3
        var members: [Smackable] = []
        var triggered = false
        var stopTimer: Float = 0
        var immobilized = 0
        var triggeredAt: Float = 0
        init(name: String, pos: float3) { self.name = name; self.pos = pos }
    }
    private(set) var list: [Breaker] = []
    static let groupRadius: Float = 45, stopRadius: Float = 30, stopDuration: Float = 3
    private static let structural = ["support", "scaffold", "watertower", "gasstationroof", "gaspump", "woodroof", "torus", "drivein",
                                     "sailboat", "amphitheater", "gazebo", "billboard", "radiotower", "seafoodpatio", "greenhouse",
                                     "hugemetal", "crane", "hinkley", "boothroof", "busstoproof", "huge_wood_roof", "aluminumroof",
                                     "smallwoodroof", "fishmarketsign"]
    private var rng = SplitMix(seed: 0xB2EA)
    /// Avisos para la música y la HUD (MPursuitBreaker [D]).
    var onTrigger: ((Breaker) -> Void)?

    init(data: CrashData, field: SmackableField) {
        for (name, pos) in data.moments {
            let b = Breaker(name: name, pos: pos)
            for s in field.all where simd_distance(SIMD2(s.pos.x, s.pos.y), SIMD2(pos.x, pos.y)) < PursuitBreakers.groupRadius && abs(s.pos.z - pos.z) < 40 {
                if PursuitBreakers.structural.contains(where: { s.type.name.contains($0) }) && s.breakerGroup == nil { b.members.append(s) }
            }
            guard !b.members.isEmpty else { continue }
            for s in b.members { s.breakerGroup = list.count }
            list.append(b)
        }
    }

    /// Un rompible del grupo se ha soltado: el jugador dispara el derrumbe.
    func smackableHit(_ s: Smackable, byPlayer: Bool, world: CrashWorld) {
        guard let g = s.breakerGroup, g < list.count, byPlayer, s.state == .moving, s.type.detachForce >= 0 else { return }
        trigger(list[g], world: world)
    }

    func trigger(_ b: Breaker, world: CrashWorld) {
        guard !b.triggered else { return }
        b.triggered = true; b.triggeredAt = world.time
        b.stopTimer = PursuitBreakers.stopDuration
        for s in b.members where s.state != .gone {
            s.detach(now: world.time)
            // Empujón inicial hacia fuera del marcador y algo de giro para que caiga [I]
            var out = s.pos - b.pos; out.z = 0
            let d = simd_length(out)
            let dir = d > 0.1 ? out / d : float3(1, 0, 0)
            s.vel += dir * rng.range(0.5, 2.0) + float3(0, 0, rng.range(0, 1.5))
            s.ang += float3(rng.range(-0.8, 0.8), rng.range(-0.8, 0.8), rng.range(-0.3, 0.3))
        }
        world.ai.stats.breakersTriggered += 1
        world.log("derrumbe «\(b.name)» con \(b.members.count) piezas")
        onTrigger?(b)
    }

    func update(dt: Float, world: CrashWorld) {
        for b in list where b.triggered && b.stopTimer > 0 {
            b.stopTimer -= dt
            for v in world.ai.vehicles where v.kind == .cop && !v.damage.destroyed && (v.copRole == .pursuit || v.copRole == .roadblock) {
                if simd_distance(SIMD2(v.pos.x, v.pos.y), SIMD2(b.pos.x, b.pos.y)) < PursuitBreakers.stopRadius {
                    world.immobilize(v)
                    b.immobilized += 1
                }
            }
        }
    }

    /// Un rompible ha vuelto a su sitio: si todo el grupo está otra vez en pie, el derrumbe se puede repetir.
    func reset(containing s: Smackable) {
        guard let g = s.breakerGroup, g < list.count else { return }
        let b = list[g]
        if b.members.allSatisfy({ $0.state == .attached || $0.state == .loose }) { b.triggered = false; b.immobilized = 0 }
    }
}
