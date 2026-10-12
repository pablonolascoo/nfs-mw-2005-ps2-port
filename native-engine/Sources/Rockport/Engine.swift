// Estado del juego independiente de la ventana: cámara, streaming, coche y entrada.
// Lo usan tanto la app a pantalla completa (App.swift) como el modo sin ventana (--screenshot / --bench).
import Foundation
import Metal
import simd

/// Teclas que el motor entiende (códigos de teclado de macOS, distribución física).
enum Key: UInt16 {
    case a = 0, s = 1, d = 2, q = 12, w = 13, e = 14, r = 15, c = 8, g = 5
    case space = 49, shift = 56, rightShift = 60, control = 59, escape = 53
    case left = 123, right = 124, down = 125, up = 126
    case f = 3, one = 18, two = 19, three = 20
}

final class Engine {
    enum Mode { case fly, drive }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let data: GameData
    let textures: TextureCache
    let renderer: Renderer
    let streamer: TileStreamer
    let collision: CollisionWorld
    var car: Car?
    var mode: Mode = .fly
    /// Tráfico y policía (AIEngine.swift). nil si faltan roads.json / ai.json.
    var ai: AIWorld?
    var aiRenderer: AIRenderer?

    // Cámara libre
    var camPos = float3(1700, 2300, 260)
    var yaw: Float = 0.6
    var pitch: Float = -0.35
    // Cámara de persecución
    var chasePos = float3(0, 0, 0)
    var chaseTarget = float3(0, 0, 0)

    /// Pruebas: cámara fija relativa al coche (ojo y objetivo en metros; X adelante, Y izquierda, Z arriba desde el suelo).
    var carCam: (eye: float3, target: float3)?

    var keys = Set<UInt16>()
    var mouseDelta = float2(0, 0)
    var time: Double = 0
    var aspect: Float = 16 / 9

    init(device: MTLDevice, data: GameData, outputFormat: MTLPixelFormat) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "Rockport", code: 1, userInfo: [NSLocalizedDescriptionKey: "sin cola de comandos Metal"]) }
        queue = q
        self.data = data
        textures = TextureCache(device: device)
        renderer = try Renderer(device: device, queue: q, textures: textures, outputFormat: outputFormat)
        streamer = TileStreamer(data: data, device: device, textures: textures)
        collision = CollisionWorld(root: data.root)
        streamer.loadFarTiles()
        setupAI(outputFormat: outputFormat)
        // Punto de partida: refugio 1 (respawn de zones.json) si existe
        if let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 {
            let p = float3(r.position[0], r.position[1], r.position[2])
            let a = (r.rotation ?? 0) * .pi / 180
            camPos = p - float3(cos(a), sin(a), 0) * 60 + float3(0, 0, 35)
            yaw = a; pitch = -0.4
        }
    }

    /// Carga el coche del jugador y lo coloca en el respawn del primer refugio.
    func loadCar() {
        guard car == nil else { return }
        car = Car(device: device, data: data, textures: textures, name: Config.playerCar, paint: Config.playerPaint)
        guard let car else { return }
        if let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 {
            car.place(float3(r.position[0], r.position[1], r.position[2]), yaw: (r.rotation ?? 0) * .pi / 180, collision: collision)
        } else {
            car.place(camPos, yaw: yaw, collision: collision)
        }
        chasePos = car.position - car.forward * 7 + float3(0, 0, 2.5)
        chaseTarget = car.position + float3(0, 0, 1)
    }

    func toggleMode() {
        if mode == .fly {
            loadCar()
            if car != nil { mode = .drive }
        } else {
            mode = .fly
            camPos = chasePos
            let d = simd_normalize(chaseTarget - chasePos)
            yaw = atan2(d.y, d.x); pitch = asin(max(-1, min(1, d.z)))
        }
    }

    func setCamera(x: Float, y: Float, z: Float, yawDeg: Float, pitchDeg: Float) {
        camPos = float3(x, y, z); yaw = yawDeg * .pi / 180; pitch = pitchDeg * .pi / 180
    }

    private func down(_ k: Key) -> Bool { keys.contains(k.rawValue) }

    /// Avanza la simulación `dt` segundos.
    func update(dt: Float) {
        time += Double(dt)
        if GameInput.shared.takeToggleRequest(polling: mode == .fly) { toggleMode() }   // Start / dos dedos: modo foto
        switch mode {
        case .fly:
            yaw -= mouseDelta.x * 0.0022
            pitch = max(-1.5, min(1.5, pitch - mouseDelta.y * 0.0022))
            let fwd = float3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
            let right = simd_normalize(simd_cross(fwd, float3(0, 0, 1)))
            var mv = float3(0, 0, 0)
            if down(.w) || down(.up) { mv += fwd }
            if down(.s) || down(.down) { mv -= fwd }
            if down(.d) || down(.right) { mv += right }
            if down(.a) || down(.left) { mv -= right }
            if down(.e) || down(.space) { mv.z += 1 }
            if down(.q) || down(.control) { mv.z -= 1 }
            let fast = down(.shift) || down(.rightShift)
            if simd_length_squared(mv) > 0 { camPos += simd_normalize(mv) * (fast ? 220 : 40) * dt }
        case .drive:
            guard let car else { mode = .fly; return }
            // Teclado + mandos (Input/), física del juego a 60 Hz (Physics/) y cámara camerainfo (Camera/)
            let pad = GameInput.shared.poll(keys: keys)
            car.update(dt: dt, input: Car.Input(driver: pad.driver), collision: collision)
            if pad.reset { car.reset() }
            if pad.nextCamera { car.camera.next(1) }
            if pad.prevCamera { car.camera.next(-1) }
            car.camera.update(dt: dt, car: car, lookBack: pad.driver.lookBack, aspect: aspect)
            chasePos = car.camera.eye; chaseTarget = car.camera.target
            Controllers.shared.update(feedback: car.padFeedback)
        }
        mouseDelta = .zero
    }

    /// Punto en coordenadas del coche → mundo (sin inclinación).
    private func carPoint(_ car: Car, _ p: float3) -> float3 {
        let f = car.forward, l = float3(-f.y, f.x, 0)
        return car.position + f * p.x + l * p.y + float3(0, 0, p.z)
    }

    var eye: float3 {
        if let cc = carCam, let car { return carPoint(car, cc.eye) }
        return mode == .drive ? chasePos : camPos
    }

    func makeFrame() -> SceneFrame {
        let view: float4x4
        if let cc = carCam, let car {
            view = .lookAt(eye: carPoint(car, cc.eye), target: carPoint(car, cc.target), up: float3(0, 0, 1))
        } else if mode == .drive {
            view = .lookAt(eye: chasePos, target: chaseTarget, up: car?.camera.up ?? float3(0, 0, 1))
        } else {
            let fwd = float3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
            view = .lookAt(eye: camPos, target: camPos + fwd, up: float3(0, 0, 1))
        }
        let fov = mode == .drive && carCam == nil ? (car?.camera.fovY ?? Config.fovYDegrees) : Config.fovYDegrees
        let proj = float4x4.perspectiveReversedInfinite(fovY: fov * .pi / 180, aspect: aspect, near: Config.nearPlane)
        let meshes = streamer.tiles.compactMap { $0.drawMesh }
        var carDraw: (GPUMesh, [float4x4])? = nil
        if let car { carDraw = (car.mesh, car.partMatrices) }   // aparcado también en modo libre
        return SceneFrame(view: view, proj: proj, camPos: eye, time: Float(time), meshes: meshes, car: carDraw, carShadow: car?.shadowMatrix)
    }

    /// Streaming + simulación + codificación del fotograma.
    func frame(cb: MTLCommandBuffer, target: MTLTexture, dt: Float, scale: Float, now: Double) {
        update(dt: dt)
        streamer.update(camera: eye, now: now)
        let f = makeFrame()
        updateAI(dt: dt, frame: f)
        renderer.encode(cb, frame: f, target: target, scale: scale)
    }
}
