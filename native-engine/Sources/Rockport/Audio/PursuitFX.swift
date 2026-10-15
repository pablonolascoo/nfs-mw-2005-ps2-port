// Mira la persecución (PoliceManager, solo lectura) y la traduce en luz del mando y radio de la policía.
// Lo llama AIEngine.updateAI una vez por fotograma (una línea). No cambia nada de la IA.
//
// Qué evento de radio suena en cada momento [D: nombres y parámetros de Speech/EAXCop.cpp y SND_GEN/COPSPEECH.hpp;
// cuándo exactamente lo decide SoundAI/PursuitFlow en el juego y aquí es una aproximación I]:
//   empieza la persecución → InitPursuit (nº de sospechosos = uno)
//   cada 12–22 s de persecución → PursuitUpdateRep / SuspectBehaviour / IntentToRam / DispPursuitUpdate
//   sube el calor → HeatJump (nivel) y CallForBU (código, tipo de refuerzo)
//   llega otra patrulla → BUArrives
//   control de carretera → CallForRB (con pinchos o sin ellos); el jugador se acerca → RBApproach; lo esquiva → RBAverted
//   se pierde de vista (enfriamiento) → LostVisual; se le vuelve a ver → RegainVisual
//   escapa → LostSuspect · arresto → Arrest y DispArrestReply
//   sin persecución, cada 50–90 s → Disp911Report + Unit911Reply (avisos de fondo)
// Intensidad alta (parámetro 2 = 1) con calor ≥ 4 [H: SoundAI::IsHighIntensity no está decompilado].
import Foundation
import simd

final class PursuitFX {
    static let shared = PursuitFX()

    private var last: PoliceManager.State = .none
    private var lastHeat = 1
    private var lastCops = 0
    private var hadRoadblock = false, approached = false, dodged = false
    private var chatter: Double = 0
    private var ambient: Double = 40
    private var voice = 0
    private var started = false
    private var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970))

    /// Cada fotograma (tras ai.update). `root` = carpeta del disco, para cargar radio/ la primera vez.
    func update(police p: PoliceManager, dt: Float, root: URL, headless: Bool) {
        let radio = PoliceRadio.shared
        if !started {
            started = true
            radio.silent = headless
            radio.attach(root: root)
        }
        let state = p.state, heat = p.heat
        let light: PursuitLight
        switch state { case .none: light = .none; case .chase: light = .chase; case .cooldown: light = .cooldown; case .busted: light = .busted; case .evaded: light = .evaded }
        LightBar.shared.note(light, heat: heat)
        guard radio.library != nil else { last = state; return }
        let hi = heat >= 4 ? 1 : 0
        let cops = p.copsInPursuit

        if state != last {
            switch (last, state) {
            case (_, .chase) where last == .cooldown:
                radio.say("RegainVisual", voice: voice, params: [2: hi], priority: 3)
            case (_, .chase):
                voice = Int(rng.next() % 8)
                radio.say("InitPursuit", voice: voice, params: [2: 0], priority: 3)
                chatter = 8; lastHeat = Int(heat); lastCops = cops
            case (.chase, .cooldown):
                radio.say("LostVisual", voice: voice, params: [2: hi], priority: 3)
                chatter = 10
            case (_, .evaded):
                radio.say("LostSuspect", voice: voice, params: [2: hi], priority: 4)
                ambient = 60
            case (_, .busted):
                radio.say("Arrest", voice: voice, params: [2: hi], priority: 5)
                radio.say("DispArrestReply", voice: 0, priority: 5, after: true)
                ambient = 60
            default: break
            }
            last = state
            approached = false
        }

        switch state {
        case .chase, .cooldown:
            chatter -= Double(dt)
            // Calor que sube de nivel
            let h = Int(heat)
            if state == .chase && h > lastHeat {
                lastHeat = h
                if !radio.say("HeatJump", voice: voice, params: [2: max(0, min(8, h - 2))], priority: 2) {
                    radio.say("CallForBU", voice: voice, params: [2: Int(rng.next() % 2), 3: 3], priority: 2)
                }
                chatter = max(chatter, 6)
            }
            // Refuerzos que se suman
            if cops > lastCops && chatter < 6 && state == .chase { radio.say("BUArrives", voice: (voice + 1 + Int(rng.next() % 6)) % 8, priority: 1); chatter = 8 }
            lastCops = cops
            // Control de carretera
            if let rb = p.roadblock {
                if !hadRoadblock {
                    let spikes = rb.props.contains { $0.spike }
                    radio.say("CallForRB", voice: voice, params: [2: Int(rng.next() % 2), 3: spikes ? 1 : 0], priority: 2)
                }
                let d = simd_distance(rb.center, p.world.player.pos)
                if !approached && d < 220 && state == .chase {
                    approached = true
                    radio.say("RBApproach", voice: (voice + 3) % 8, params: [2: rb.props.contains { $0.spike } ? 1 : 0], priority: 2)
                }
                if rb.dodged && !dodged { radio.say("RBAverted", voice: (voice + 3) % 8, priority: 2) }
                dodged = rb.dodged
            } else { dodged = false; approached = false }
            hadRoadblock = p.roadblock != nil
            // Charla de persecución
            if chatter <= 0 && !radio.isBusy {
                let pool = state == .chase ? ["PursuitUpdateRep", "SuspectBehaviour", "IntentToRam", "DispPursuitUpdate", "SuspectOutrun"]
                                           : ["SuspectPossiblyGone", "QuadrentForming", "DispBreakAway"]
                let ev = pool[Int(rng.next() % UInt64(pool.count))]
                radio.say(ev, voice: ev.hasPrefix("Disp") ? 0 : voice, params: [2: ev == "SuspectBehaviour" ? 0 : hi], priority: 1)
                chatter = 12 + Double(rng.next() % 10)
            }
        case .none:
            hadRoadblock = false
            if radio.settings.ambient {
                ambient -= Double(dt)
                if ambient <= 0 && !radio.isBusy {
                    if radio.say("Disp911Report", voice: 0, params: [3: 0], priority: 0) {
                        radio.say("Unit911Reply", voice: Int(rng.next() % 8), priority: 0, after: true)
                    }
                    ambient = 50 + Double(rng.next() % 40)
                }
            }
        default: break
        }
    }
}
