// Streaming de las casillas de 400 m (world.json → tiles), como viewer/src/main.ts:
// - Nivel lejano (color de vértice, sin textura): las 212 casillas se cargan al arrancar (~0,9 M triángulos).
// - Nivel cercano (con textura): solo las casillas a menos de `Config.nearRadius` de la cámara, máx. `Config.maxNear`.
// - Liberación: casillas cercanas a más de `Config.keepRadius` durante `Config.keepSeconds`.
// La lectura del GLB, la descodificación de PNG y la creación de búferes se hacen en hilos de fondo.
// El hilo principal solo recoge casillas terminadas (sin trabajo pesado).
import Foundation
import Metal
import simd

final class TileStreamer {
    final class TileState {
        let tile: WorldTile
        let box: AABB
        var far: GPUMesh?
        var near: GPUMesh?
        var nearLoading = false
        var failed = false
        var wantNear = false
        var lastUsed: Double = 0
        var distance: Float = 0
        init(_ t: WorldTile) {
            tile = t
            box = AABB(min: float3(t.x, t.y, t.zMin), max: float3(t.x + t.size, t.y + t.size, t.zMax))
        }
        /// Malla a dibujar este fotograma: la cercana si está lista y se quiere; si no, la lejana.
        var drawMesh: GPUMesh? { (wantNear && near != nil) ? near : far }
    }

    let data: GameData
    let device: MTLDevice
    let textures: TextureCache
    private(set) var tiles: [TileState] = []
    private let loadQueue = DispatchQueue(label: "rockport.tiles", qos: .userInitiated, attributes: .concurrent)
    private let farQueue = DispatchQueue(label: "rockport.far", qos: .utility, attributes: .concurrent)
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var finished: [() -> Void] = []
    private var inflight = 0
    private(set) var farLoaded = 0
    private var lastStream: Double = -1
    private(set) var stats = (near: 0, nearReady: 0, far: 0, loading: 0, nearBytes: 0)

    init(data: GameData, device: MTLDevice, textures: TextureCache) {
        self.data = data
        self.device = device
        self.textures = textures
        slots = DispatchSemaphore(value: Config.parallelLoads)
        tiles = data.world.tiles.map(TileState.init)
    }

    /// Lanza la carga de todas las casillas lejanas (en segundo plano).
    func loadFarTiles() {
        let farSlots = DispatchSemaphore(value: 6)
        for t in tiles {
            farQueue.async { [self] in
                farSlots.wait(); defer { farSlots.signal() }
                let url = data.url(t.tile.far)
                var mesh: GPUMesh? = nil
                if let f = try? GLB.load(url) { mesh = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: url.path) }
                post { t.far = mesh; self.farLoaded += 1 }
            }
        }
    }

    private func post(_ f: @escaping () -> Void) { lock.lock(); finished.append(f); lock.unlock() }

    var allFarLoaded: Bool { farLoaded >= tiles.count }

    /// ¿No queda nada cargando ni por recoger?
    var idle: Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight == 0 && finished.isEmpty
    }

    /// Llamar una vez por fotograma desde el hilo principal.
    func update(camera: float3, now: Double, force: Bool = false) {
        // 1. Recoger trabajo terminado
        lock.lock(); let done = finished; finished.removeAll(); lock.unlock()
        for f in done { f() }

        // 2. Decidir qué casillas quieren detalle (cada 200 ms, como el visor)
        if !force && now - lastStream < 0.2 { return }
        lastStream = now
        for t in tiles { t.distance = t.box.distance(to: camera) }
        let sorted = tiles.sorted { $0.distance < $1.distance }
        var nearCount = 0, ready = 0, nearBytes = 0
        for t in sorted {
            let want = t.distance < Config.nearRadius && nearCount < Config.maxNear
            t.wantNear = want
            if want {
                nearCount += 1
                t.lastUsed = now
                if t.near == nil && !t.nearLoading && !t.failed { startNear(t) }
            }
            if t.near != nil {
                if want { ready += 1 }
                if t.distance > Config.keepRadius && now - t.lastUsed > Config.keepSeconds { t.near = nil }
            }
            nearBytes += t.near?.bytes ?? 0
        }
        lock.lock(); let inf = inflight; lock.unlock()
        stats = (nearCount, ready, tiles.count - nearCount, inf, nearBytes)
    }

    private func startNear(_ t: TileState) {
        t.nearLoading = true
        lock.lock(); inflight += 1; lock.unlock()
        loadQueue.async { [self] in
            slots.wait(); defer { slots.signal() }
            let url = data.url(t.tile.near)
            var mesh: GPUMesh? = nil
            do {
                let f = try GLB.load(url)
                mesh = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: url.path)
            } catch { fputs("casilla \(t.tile.id): \(error)\n", stderr) }
            post {
                t.nearLoading = false
                t.near = mesh
                t.failed = mesh == nil
            }
            lock.lock(); inflight -= 1; lock.unlock()
        }
    }
}
