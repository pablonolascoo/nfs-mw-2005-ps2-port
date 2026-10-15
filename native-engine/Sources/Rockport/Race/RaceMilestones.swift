// Hitos de persecución (GMilestone [D: Gameplay/GMilestone.h]): la medida de cada tipo a partir del estado de la policía.
// Los nombres (MilestoneName) y los objetivos (GoalEasy/GoalHard, ThreshholdValue) son del disco [V]; cómo se cuenta cada
// medida en este motor es [I] (la lógica de GMilestone.cpp no está decompilada).
import Foundation

enum RaceMilestones {
    /// Valor actual de una medida. `base` = estadísticas de la IA al empezar (para contar solo lo de esta persecución).
    static func value(_ type: String, police: PoliceManager, stats: AIStats, base: AIStats?, pursuitTime: Double?) -> Float {
        let b = base ?? AIStats()
        switch type {
        case "pursuit_length", "pursuit_evasion_time": return Float(pursuitTime ?? Double(police.pursuitTime))
        case "cops_damaged": return Float(stats.playerHitsCops - b.playerHitsCops)
        case "cops_destroyed": return 0          // sin daños de coche en el motor todavía
        case "bounty_in_pursuit", "cost_to_state_in_pursuit", "cost_to_state": return Float(police.costToState)
        case "roadblocks_dodged": return Float(stats.roadblocksDodged - b.roadblocksDodged)
        case "tire_spikes_dodged", "spike_strips_dodged": return Float(stats.roadblocksDodged - b.roadblocksDodged)
        case "total_infractions", "infractions": return Float(police.infractions.count)
        default: return 0
        }
    }

    /// ¿Menos es mejor? (MilestoneBiggerIsBetter = false en la plantilla de evasión [V]).
    static func smallerIsBetter(_ type: String) -> Bool { type == "pursuit_evasion_time" }

    static func reached(_ type: String, value: Float, goal: Float) -> Bool {
        smallerIsBetter(type) ? value > 0 && value <= goal : value >= goal
    }
}
