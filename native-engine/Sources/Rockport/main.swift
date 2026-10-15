// Punto de entrada. Sin argumentos: app a pantalla completa. Con --screenshot o --bench: modo sin ventana.
//
//   Rockport [--data <carpeta>] [--disc <ID>] [--grade <n>] [--cam x,y,z,rumboº,inclinaciónº] [--drive]
//            [--scale <0.5…1>] [--quit-after <s>]
//   Rockport --screenshot salida.png [--size 1920x1080] [--frames 30] [...]
//   Rockport --bench [--seconds 20] [--size 2560x1664] [...]
import AppKit
import simd
import Metal
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var data: String?
    var disc: String?
    var grade: Float?
    var camera: [Float]?
    var drive = false
    var car = false
    var autodrive: Double = 0
    var carCam: [Float]?
    var scale: Float?
    var quitAfter: Double?
    var screenshot: String?
    var bench = false
    var size = (1920, 1080)
    var frames = 30
    var seconds: Double = 20
    var noUI = false
    var uiTest: String?
    var uiTime: Double = 2500
    var uiHudDemo = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--data": o.data = next()
            case "--disc": o.disc = next()
            case "--grade": o.grade = next().flatMap(Float.init)
            case "--cam": o.camera = next()?.split(separator: ",").compactMap { Float($0) }
            case "--drive": o.drive = true
            case "--car": o.car = true
            case "--car-preset":   // preset del juego para el coche del jugador (presets.json); "ninguno" = de serie
                if let n = next() { Config.playerPreset = ["ninguno", "none", "stock"].contains(n.lowercased()) ? nil : n }
            case "--carcam": o.carCam = next()?.split(separator: ",").compactMap { Float($0) }   // pruebas: ojo,objetivo relativos al coche
            case "--autodrive":   // pruebas: acelera N s antes de capturar; sin número (--race-test), piloto automático
                if i + 1 < args.count, let v = Double(args[i + 1]) { o.autodrive = v; i += 1 }
            case "--near":   // depuración: radio del nivel con textura (m)
                if let r = next().flatMap(Float.init) { Config.nearRadius = r; Config.maxNear = 400 }
            case "--scale": o.scale = next().flatMap(Float.init)
            case "--no-ui": o.noUI = true
            case "--ui-test": o.uiTest = next()                                   // UI/FEScreens.swift showForTest
            case "--ui-time": o.uiTime = next().flatMap(Double.init) ?? 2500      // ms de animación antes de la captura
            case "--ui-hud-demo": o.uiHudDemo = true                              // HUD con datos de persecución de ejemplo
            case "--quit-after": o.quitAfter = next().flatMap(Double.init)
            case "--screenshot": o.screenshot = next()
            case "--bench": o.bench = true
            case "--frames": o.frames = next().flatMap(Int.init) ?? 30
            case "--seconds": o.seconds = next().flatMap(Double.init) ?? 20
            case "--size":
                let p = (next() ?? "").split(separator: "x").compactMap { Int($0) }
                if p.count == 2 { o.size = (p[0], p[1]) }
            case "-h", "--help":
                print("""
                Rockport — motor nativo macOS para los datos de NFS Most Wanted (PS2) convertidos desde tu ISO.
                  --data <carpeta>     carpeta map-data/<ID> (o su carpeta padre). También ROCKPORT_DATA.
                  --disc <ID>          disco a usar si hay varios (p. ej. SLES-53559)
                  --grade <n>          (desarrollo) fuerza del tono PS2; en el juego va siempre a 1. También ROCKPORT_GRADE.
                  --cam x,y,z,r,i      cámara inicial (metros; rumbo e inclinación en grados)
                  --drive              empezar conduciendo el BMW M3 GTR
                  --carcam ox,oy,oz,tx,ty,tz  cámara fija respecto al coche (X adelante, Y izquierda, Z arriba)
                  --car-preset <NOMBRE>  coche del juego (presets.json): M3GTRCAREERSTART (por defecto), RAZORMUSTANG, BL2…BL15, ninguno
                  --scale <f>          fija la escala de resolución (desactiva la dinámica)
                  --no-ui              sin la interfaz del juego (arranca en cámara libre, HUD mínimo propio)
                  --ui-test <pantalla> sin ventana (con --screenshot): Splash, MainMenu, Career, Pause, HUD, Dialog o un paquete .fng
                  --ui-time <ms>       tiempo de animación de la interfaz antes de la captura (2500) · --ui-hud-demo datos de persecución
                  --ui-test HUD-chase|HUD-cooldown|HUD-busted|HUD-evaded|Race-<tipo>|Results|Blacklist|CarWon  estados del HUD original
                  --debug-hud          HUD propio de depuración de la persecución (no es la interfaz del juego)
                  --quit-after <s>     salir tras s segundos (pruebas)
                  --screenshot <png>   sin ventana: carga, dibuja --frames fotogramas, guarda PNG y sale
                  --size AxB           tamaño del modo sin ventana (1920x1080)
                  --bench              sin ventana: vuelo a 250 km/h durante --seconds y mide tiempos
                  --audit              carga todas las casillas y comprueba geometría y texturas
                  --physics-test [COCHE]  prueba de la física del juego en un plano: 0–100, punta, frenada, curva, NOS
                  --traffic-test N     sin ventana: N s de tráfico y policía con un coche de prueba; captura (--screenshot) y estadísticas
                  --traffic-max N      máximo de coches de tráfico (20) · --heat H calor inicial · --no-traffic · --no-police
                  --crash-test [ESC]   sin ventana: choques del juego (frontal, lateral, PIT, rompibles, derrumbe; all = todos) → capturas y JSON
                  --heli-test N        sin ventana: persecución de calor 5 con helicóptero durante N s · --no-crash · --no-heli
                  --race-test ID       sin ventana: corre la prueba ID (EventID «15.1.1» o colección) · --autodrive piloto automático
                                       · --seconds N · --opponents N · --screenshot base.png (capturas -start/-mid/-finish + JSON)
                  --career-test        sin ventana: progresión simulada de la Lista Negra (15 → 1) · --save ruta.json
                  --race ID            (app) empieza directamente la carrera rápida ID · --career  (app) entra en la carrera profesional
                  --players N          (app) pantalla partida: con --race, N jugadores (2…4) · --displays all|1|2  pantallas a usar
                  --split-test N       sin ventana: N jugadores con piloto automático (--race ID, --seconds S, --displays D, --screenshot base.png)
                  --quickrace-test     sin ventana: recorre las pantallas de la carrera rápida (--split N) y saca capturas
                  --sound-off · --volume V   sonido del juego apagado · volumen general 0…1
                  --no-movies · --skip-intro · --movie NOMBRE   sin películas · sin las del arranque · (app) reproduce NOMBRE al empezar
                  --iso <ruta> · --lang <idioma>  ISO de donde leer las películas · idioma de las películas y subtítulos
                  --movie-test NOMBRE|all [--seconds N]  sin ventana: película con reloj simulado → .build/movie-test/ (capturas, WAV, sincronía)
                  --music-off · --music-volume V   música apagada · volumen de la música 0…1
                  --music-test [--seconds N]  sin ventana: zona libre → persecución → evasión con la música interactiva → .build/music-test/
                  --sound-test [COCHE] sin ventana: recorrido con guion → .build/sound-test/<COCHE>.wav · --sound-dump bancos · --sound-live S salida real
                  --fx-test burnout|street|pursuit|stats  sin ventana: efectos (humo, nitro, destellos, barra de policía) con capturas y GPU con/sin · ROCKPORT_FX=0|hide
                """)
                exit(0)
            case "--audit": break   // se atiende en el arranque (runAudit)
            case "--physics-test": if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }   // runPhysicsTest
            case "--physics-trace": break
            case "--traffic-test", "--traffic-max", "--heat", "--test-plan": i += 1   // AIEngine.swift (AIOptions)
            case "--no-traffic", "--no-police": break
            case "--no-crash", "--no-heli": break   // Crash/ (choques del juego, helicóptero)
            case "--crash-test": if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }   // Crash/CrashTests.swift
            case "--heli-test": if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            case "--race-test", "--opponents", "--save", "--race": i += 1   // Race/RaceTests.swift, App.swift
            case "--career-test", "--career", "--race-audit": break
            case "--garage-test", "--garage-mode", "--garage-screen", "--garage-select": i += 1   // Garage/GarageTests.swift
            case "--garage-scene", "--fe-angle", "--scene-car", "--garage-swap-test": i += 1   // Garage/GarageScenesTests.swift
            case "--fx-test": i += 1   // Effects/EffectsTests.swift
            case "--split-test", "--displays", "--players", "--split": i += 1   // Multiplayer/ (pantalla partida, varias pantallas)
            case "--quickrace-test", "--multi-display-test", "--unplug-test": break
            case "--lightbar", "--radio-out": i += 1   // Input/LightBarConfig.swift, Audio/PoliceRadio.swift
            case "--debug-hud": break   // HUDPursuit.swift: HUD propio de depuración (el juego usa el original, UI/FEHud.swift)
            case "--radio-log", "--audio-devices", "--radio-test", "--pad-audio-test", "--lightbar-test": break   // Audio/AudioTests.swift
            case "--sound-dump", "--sound-trace", "--sound-off": break   // Audio/SFXTests.swift, Audio/SFXWorld.swift
            case "--sound-live": if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            case "--sound-test": if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            case "--volume": i += 1
            case "--no-movies", "--skip-intro", "--music-off": break        // Movies/Movies.swift, Audio/MusicSystem.swift
            case "--iso", "--lang", "--movie", "--music-volume": i += 1     // ISO de las películas, idioma, película al arrancar, volumen de la música
            default: fputs("argumento desconocido: \(args[i])\n", stderr)
            }
            i += 1
        }
        if o.grade == nil, let g = ProcessInfo.processInfo.environment["ROCKPORT_GRADE"].flatMap(Float.init) { o.grade = g }
        return o
    }
}

// MARK: - Auditoría de casillas

/// `--audit`: carga TODAS las casillas (cercanas y lejanas) como lo hace el streaming y comprueba que cada una tenga
/// geometría y que cada material con imagen tenga su textura. En el visor web una casilla con más de 256 texturas
/// del mismo tamaño se quedaba sin paredes; aquí cada material lleva su textura suelta (sin arrays), pero se verifica.
func runAudit(_ o: Options) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    let textures = TextureCache(device: device)
    let lock = NSLock()
    var bad: [String] = [], tris = 0, draws = 0, maxTex = 0, maxTexTile = ""
    let t0 = CACurrentMediaTime()
    DispatchQueue.concurrentPerform(iterations: data.world.tiles.count) { i in
        let t = data.world.tiles[i]
        for (lvl, rel) in [("cercana", t.near), ("lejana", t.far)] {
            let url = data.url(rel)
            guard let f = try? GLB.load(url) else { lock.lock(); bad.append("\(t.id) \(lvl): GLB ilegible"); lock.unlock(); continue }
            let mesh = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: url.path)
            let expected = lvl == "cercana" ? t.tris : t.farTris
            lock.lock()
            if let mesh {
                tris += mesh.triangles; draws += mesh.draws.count
                let missing = mesh.draws.filter { d in d.texture == nil && f.materials.first { $0.name == d.name }?.image != nil }
                if !missing.isEmpty { bad.append("\(t.id) \(lvl): \(missing.count) materiales sin textura (\(missing.prefix(3).map(\.name).joined(separator: ", ")))") }
                if abs(mesh.triangles - expected) > max(2, expected / 100) { bad.append("\(t.id) \(lvl): \(mesh.triangles) triángulos, world.json dice \(expected)") }
                let nt = Set(f.materials.compactMap(\.image)).count
                if nt > maxTex { maxTex = nt; maxTexTile = t.id }
            } else if expected > 0 { bad.append("\(t.id) \(lvl): sin malla (world.json: \(expected) triángulos)") }
            lock.unlock()
        }
    }
    print(String(format: "Auditoría: %d casillas × 2 niveles en %.1f s · %.2f M triángulos · %d tramos · %d texturas · máx. %d texturas en una casilla (%@)",
                 data.world.tiles.count, CACurrentMediaTime() - t0, Double(tris) / 1e6, draws, textures.count, maxTex, maxTexTile))
    if bad.isEmpty { print("Todo bien: todas las casillas tienen geometría y todas sus texturas.") }
    else { print("Problemas (\(bad.count)):"); for b in bad.sorted() { print("  " + b) } }
    exit(bad.isEmpty ? 0 : 1)
}

// MARK: - Modo sin ventana

func runHeadless(_ o: Options) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    let data: GameData
    do { data = try GameData(root: root) } catch { fputs("world.json: \(error)\n", stderr); exit(1) }
    let engine: Engine
    do { engine = try Engine(device: device, data: data, outputFormat: .bgra8Unorm) } catch { fputs("motor: \(error)\n", stderr); exit(1) }
    if let g = o.grade { engine.renderer.gradeStrength = g }
    if let c = o.camera, c.count == 5 { engine.setCamera(x: c[0], y: c[1], z: c[2], yawDeg: c[3], pitchDeg: c[4]) }
    if let t = o.uiTest, let ui = engine.enableUI(outputFormat: .bgra8Unorm) {
        ui.showForTest(t)
        if o.uiHudDemo { ui.hudDemo = true }
    } else if o.drive { engine.toggleMode() } else if o.car || o.carCam != nil { engine.loadCar() }
    if let c = o.carCam, c.count == 6 { engine.carCam = (float3(c[0], c[1], c[2]), float3(c[3], c[4], c[5])) }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!
    print("Rockport sin ventana · \(root.path) · \(W)×\(H) · GPU \(device.name)")

    // 1. Esperar a que carguen todas las casillas lejanas y las cercanas a la cámara
    let t0 = CACurrentMediaTime()
    var clock = 0.0
    func renderOne(dt: Float, sync: Bool = true) -> (gpu: Double, cpu: Double) {
        let c0 = CACurrentMediaTime()
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: o.scale ?? 1, now: clock)
        cb.commit()
        let cpu = (CACurrentMediaTime() - c0) * 1000
        if sync { cb.waitUntilCompleted() }
        return ((cb.gpuEndTime - cb.gpuStartTime) * 1000, cpu)
    }
    while true {
        clock += 1.0 / 60
        _ = renderOne(dt: o.bench ? 0 : 1.0 / 60)
        let s = engine.streamer.stats
        if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && clock > 0.5 { break }
        if CACurrentMediaTime() - t0 > 120 { fputs("aviso: tiempo de carga agotado\n", stderr); break }
        usleep(5000)
    }
    let s = engine.streamer.stats
    print(String(format: "Carga: %.2f s · %d casillas cercanas, %d lejanas · %d texturas (%.0f MB) · casillas cercanas %.0f MB",
                 CACurrentMediaTime() - t0, s.near, s.far, engine.textures.count, Double(engine.textures.bytesResident) / 1048576, Double(s.nearBytes) / 1048576))

    if o.bench {
        // 2a. Vuelo recto a 250 km/h a 60 fps simulados: el streaming trabaja de verdad mientras tanto
        var gpu: [Double] = [], cpu: [Double] = [], wall: [Double] = []
        let frames = Int(o.seconds * 60)
        engine.mode = .fly
        for _ in 0..<frames {
            let w0 = CACurrentMediaTime()
            clock += 1.0 / 60
            engine.camPos += float3(cos(engine.yaw), sin(engine.yaw), 0) * (250 / 3.6 / 60)
            let r = renderOne(dt: 1.0 / 60)
            gpu.append(r.gpu); cpu.append(r.cpu); wall.append((CACurrentMediaTime() - w0) * 1000)
        }
        let over = wall.filter { $0 > 16.7 }.count
        print(String(format: "Vuelo %d fotogramas a %d×%d: GPU med %.2f ms p95 %.2f máx %.2f · CPU med %.2f ms p95 %.2f · total med %.2f ms p95 %.2f · %.1f%% > 16,7 ms · %d llamadas · %.2f M tri",
                     frames, W, H, median(gpu), pct(gpu, 0.95), gpu.max() ?? 0, median(cpu), pct(cpu, 0.95), median(wall), pct(wall, 0.95),
                     Double(over) * 100 / Double(frames), engine.renderer.lastDrawCalls, Double(engine.renderer.lastTriangles) / 1e6))
        exit(0)
    }

    // 2b. Prueba de conducción: acelerar (y girar un poco) N segundos sobre la colisión real
    if o.autodrive > 0, let car = engine.car {
        engine.mode = .drive
        let start = car.position
        engine.keys.insert(Key.w.rawValue)
        for i in 0..<Int(o.autodrive * 60) {
            if i == Int(o.autodrive * 30) { engine.keys.insert(Key.a.rawValue) }
            clock += 1.0 / 60; _ = renderOne(dt: 1.0 / 60)
        }
        engine.keys.removeAll()
        print(String(format: "Conducción %.1f s: %.0f km/h · recorrido %.1f m · z %.2f → %.2f · en el suelo: %@",
                     o.autodrive, car.kmh, simd_distance(start, car.position), start.z, car.position.z, car.grounded ? "sí" : "no"))
    }

    // 2b'. Interfaz: deja correr sus animaciones (APPEAR de los paquetes) antes de la captura
    if o.uiTest != nil { for _ in 0..<Int(o.uiTime / 1000 * 60) { clock += 1.0 / 60; _ = renderOne(dt: 1.0 / 60) } }

    // 2c. N fotogramas fijos (medida estable) y captura
    var gpu: [Double] = []
    for _ in 0..<max(1, o.frames) { clock += 1.0 / 60; gpu.append(renderOne(dt: 1.0 / 60).gpu) }
    print(String(format: "Vista fija %d×%d: GPU med %.2f ms p95 %.2f · %d llamadas · %.2f M tri",
                 W, H, median(gpu), pct(gpu, 0.95), engine.renderer.lastDrawCalls, Double(engine.renderer.lastTriangles) / 1e6))
    if let path = o.screenshot { writePNG(target, device: device, queue: engine.queue, path: path) }
    exit(0)
}

/// Copia la textura BGRA8 a memoria y la guarda como PNG.
func writePNG(_ tex: MTLTexture, device: MTLDevice, queue: MTLCommandQueue, path: String) {
    let W = tex.width, H = tex.height, bpr = W * 4
    let buf = device.makeBuffer(length: bpr * H, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: W, height: H, depth: 1),
              to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * H)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let provider = CGDataProvider(data: Data(bytes: buf.contents(), count: bpr * H) as CFData),
          let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("no se pudo escribir \(path)\n", stderr); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("Captura: \(path)")
}

// MARK: - Arranque

// `--probe <iso>`: solo detecta el disco (lo mismo que hace el instalador) y sale.
if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    if let r = DiscProbe.probe(url) { print("\(r.id) · \(r.known?.label ?? "desconocido")"); exit(0) }
    print("no es una ISO de PS2 reconocible"); exit(2)
}
// Pruebas de audio y luz del mando sin ventana (Audio/AudioTests.swift)
if AudioTests.handle(CommandLine.arguments) { exit(0) }
// Pruebas del sonido del juego sin ventana (Audio/SFXTests.swift)
if SFXTests.handle(CommandLine.arguments) { exit(0) }
// Pruebas de los efectos (partículas, destellos) sin ventana (Effects/EffectsTests.swift)
if EffectsTests.handle(CommandLine.arguments) { exit(0) }
// Películas y música sin ventana (Movies/MovieTests.swift, Audio/MusicTests.swift)
if MovieTests.handle(CommandLine.arguments) { exit(0) }
if MusicTests.handle(CommandLine.arguments) { exit(0) }
let options = Options.parse(CommandLine.arguments)
if let i = CommandLine.arguments.firstIndex(of: "--physics-test") {
    let a = CommandLine.arguments
    runPhysicsTest(options, carName: i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : Config.playerCar)
} else if let ev = RaceTestOptions.raceTest {
    runRaceTest(options, eventKey: ev)
} else if let z = GarageTestOptions.zone {
    runGarageTest(options, zone: z)
} else if let k = GarageSceneTestOptions.kind {
    runGarageSceneTest(options, kind: k)
} else if let z = GarageSceneTestOptions.swapZone {
    runGarageSwapTest(options, zone: z)
} else if RaceTestOptions.careerTest {
    runCareerTest(options)
} else if let n = MPTestOptions.splitTest {
    runSplitTest(options, players: n)
} else if MPTestOptions.quickRaceTest {
    runQuickRaceTest(options)
} else if RaceTestOptions.raceAudit {
    runRaceAudit(options)
} else if let k = CrashOptions.crashTest {
    runCrashTest(options, scenario: k)
} else if let secs = CrashOptions.heliTest {
    runHeliTest(options, seconds: secs)
} else if let secs = AIOptions.trafficTest {
    runTrafficTest(options, seconds: secs)
} else if CommandLine.arguments.contains("--audit") {
    runAudit(options)
} else if options.screenshot != nil || options.bench {
    runHeadless(options)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
