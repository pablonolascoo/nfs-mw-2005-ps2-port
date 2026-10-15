// Vallas del mundo: los grupos de escenario que el juego activa por nombre (EnableBarrierSceneryGroup) y sus líneas de
// TrackPath (EnableBarriers) [D: GRaceStatus::EnableBarriers / EnableBinBarriers, World/TrackPath.cpp].
//  - Carrera: la lista Barriers de la prueba (BARRIER_SPLINE_n, a veces SCENERY_GROUP_DOOR o candados).
//  - Historia: la lista Barriers del bin actual de la Lista Negra (BARRIER_LOCKED_10…15, los candados entre distritos).
// Cada grupo se dibuja con su GLB (world.json → groups/) y sus líneas se vuelven muros para el coche del jugador y los
// rivales (CollisionWorld.dynamicWalls). Los grupos «drive through» (DriveThroughBarrierFlag) solo cierran la ruta de la IA:
// el jugador puede atravesarlos [I: PlayerBarrier = DriveThroughBarrierFlag en EnableBarriers].
import Foundation
import Metal
import simd

final class RaceWorld {
    unowned let engine: Engine
    let db: RaceDatabase
    private var meshCache: [String: GPUMesh?] = [:]
    /// Grupos activos por origen.
    private(set) var raceGroups: [RaceBarrierRef] = []
    private(set) var binGroups: [RaceBarrierRef] = []

    init(engine: Engine, db: RaceDatabase) { self.engine = engine; self.db = db }

    var activeNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in binGroups + raceGroups where seen.insert(r.group).inserted { out.append(r.group) }
        return out
    }

    func setRaceBarriers(_ refs: [RaceBarrierRef]) { raceGroups = refs; apply() }
    func setBinBarriers(_ refs: [RaceBarrierRef]) { binGroups = refs; apply() }

    /// Líneas de las vallas activas (para la ruta de la IA).
    func lines(for refs: [RaceBarrierRef]? = nil) -> RaceBarrierLines {
        let names = refs.map { $0.map(\.group) } ?? activeNames
        return RaceBarrierLines(groups: names.compactMap { n in db.barrierGroups[n].map { (n, $0) } })
    }

    private func mesh(_ name: String) -> GPUMesh? {
        if let m = meshCache[name] { return m }
        var m: GPUMesh? = nil
        if let g = db.barrierGroups[name], let rel = g.glb {
            let url = engine.data.url(rel)
            if let f = try? GLB.load(url) { m = GPUMesh.build(device: engine.device, file: f, textures: engine.textures, keyPrefix: url.path) }
        }
        meshCache[name] = m
        return m
    }

    private var wallCache: [Int: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)]] = [:]
    /// Muros de collision/groups/<número>.bin (formato NFSC v1, como las casillas).
    private func groupWalls(_ g: RaceBarrierGroup) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)]? {
        guard let n = g.number else { return nil }
        if let w = wallCache[n] { return w }
        guard let d = try? Data(contentsOf: engine.data.url("collision/groups/\(n).bin")), d.count >= 16 else { wallCache[n] = []; return [] }
        var out: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x4353464e else { return }
            let nt = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)), nw = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            guard raw.count >= 16 + (nt * 9 + nw * 6) * 4 else { return }
            func f(_ i: Int) -> Float { raw.loadUnaligned(fromByteOffset: 16 + (nt * 9 + i) * 4, as: Float.self) }
            for k in 0..<nw { let b = k * 6; out.append((SIMD2(f(b), f(b + 1)), SIMD2(f(b + 2), f(b + 3)), min(f(b + 4), f(b + 5)), max(f(b + 4), f(b + 5)))) }
        }
        wallCache[n] = out
        return out
    }

    private func apply() {
        let names = activeNames
        engine.extraMeshes = names.compactMap { mesh($0) }
        var walls: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        for n in names {
            guard let g = db.barrierGroups[n], !g.driveThrough else { continue }
            // Colisión real de los objetos del grupo (STREAML2RA, instancias con GroupNumber) [V]; si no hay, las líneas de TrackPath
            if let gw = groupWalls(g), !gw.isEmpty { walls += gw; continue }
            let z0 = (g.min.map { $0.count > 2 ? $0[2] : -1e4 } ?? -1e4) - 4
            let z1 = (g.max.map { $0.count > 2 ? $0[2] : 1e4 } ?? 1e4) + 4
            for l in g.lines where l.count >= 4 { walls.append((SIMD2(l[0], l[1]), SIMD2(l[2], l[3]), z0, z1)) }
        }
        engine.collision.dynamicWalls = walls
        engine.ai?.net.resetBlocked()
    }
}
