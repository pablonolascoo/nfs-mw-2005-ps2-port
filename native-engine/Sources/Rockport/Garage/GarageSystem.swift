// Garajes: escenario del frontend (FEGarage.swift) y garajes sin pantallas de carga en el mundo (WorldGarage.swift).
// Se engancha al motor con lo mínimo: una capa de dibujo (Renderer.overlays), un retoque del fotograma
// (Engine.frameOverrides), un paso por fotograma (Engine.frameHooks) y los ganchos de colisión de CollisionWorld.
import Foundation
import Metal
import simd

final class GarageSystem {
    /// Un motor por proceso: la interfaz lo crea al activarse (Engine.enableUI) o las pruebas (--garage-test).
    private(set) static var shared: GarageSystem?
    unowned let engine: Engine
    let library: InteriorLibrary
    let renderer: GarageRenderer
    let stage: FEStage
    private(set) var world: WorldGarages?
    /// Escenas conducibles de los garajes (GarageScenes.swift): paredes y umbral propios, reflejo, cambio de coche.
    let scenes: GarageScenes

    @discardableResult
    static func attach(_ engine: Engine) -> GarageSystem? {
        if let s = shared, s.engine === engine { return s }
        guard let r = try? GarageRenderer(device: engine.device, textures: engine.textures) else { fputs("garaje: sin shaders\n", stderr); return nil }
        let s = GarageSystem(engine: engine, renderer: r)
        shared = s
        return s
    }

    private init(engine: Engine, renderer: GarageRenderer) {
        self.engine = engine
        self.renderer = renderer
        library = InteriorLibrary(device: engine.device, data: engine.data, textures: engine.textures)
        stage = FEStage(engine: engine, library: library)
        world = WorldGarages(engine: engine, library: library)
        world?.onParked = { [weak engine] g in engine?.ui?.openGarage(g) }
        scenes = GarageScenes(engine: engine)   // después de WorldGarages: encadena su suelo
        engine.renderer.overlays.insert(renderer, at: 0)
        engine.frameHooks.append { [weak self] dt in self?.update(dt: dt) }
        engine.frameOverrides.append { [weak self] f in self?.apply(&f) }
    }

    /// dt = 0 con la simulación en pausa (menús del garaje): la cámara del frontend sigue animándose.
    private var lastWall = CFAbsoluteTimeGetCurrent()
    func update(dt: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        let wall = Float(min(0.1, now - lastWall)); lastWall = now
        let camDt = dt > 0 ? dt : (GarageSystem.fixedStep ?? wall)
        stage.update(dt: camDt)
        world?.update(dt: dt, camDt: camDt)
        scenes.update(camDt: camDt)
    }
    /// Pruebas sin ventana: paso fijo para la cámara aunque la simulación esté en pausa.
    static var fixedStep: Float?

    private func apply(_ f: inout SceneFrame) {
        var items: [GarageDrawItem] = []
        if stage.active {
            stage.apply(&f, aspect: engine.cameraAspect ?? engine.aspect)
            items = stage.drawItems
            f.lighting = .frontEnd(stage.kind.interior)   // luz y reflejo del garaje del frontend (doc 20)
        } else if let w = world {
            w.apply(&f, aspect: engine.cameraAspect ?? engine.aspect)
            items = w.drawItems
            if GarageCutout.active, let g = w.current {      // dentro de un garaje del mundo: su luz, con la niebla de la calle
                var l = SceneLighting.frontEnd(g.interior)
                l.fog = SceneLighting.world.fog; l.fogColor = nil; l.fogHeight = .zero; l.sky = true
                f.lighting = l
            }
        }
        scenes.apply(&f)
        renderer.items = items + scenes.drawItems(stage: stage, world: world)
    }
}

extension Engine {
    /// Garajes (Garage/). nil hasta que la interfaz o una prueba los activa.
    var garages: GarageSystem? { GarageSystem.shared?.engine === self ? GarageSystem.shared : nil }
}
