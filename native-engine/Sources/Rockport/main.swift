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
    var scale: Float?
    var quitAfter: Double?
    var screenshot: String?
    var bench = false
    var size = (1920, 1080)
    var frames = 30
    var seconds: Double = 20

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
            case "--autodrive": o.autodrive = next().flatMap(Double.init) ?? 0   // pruebas: acelera N s antes de capturar
            case "--far-scale": if let f = next().flatMap(Float.init) { Config.farColorScale = f }
            case "--near":   // depuración: radio del nivel con textura (m)
                if let r = next().flatMap(Float.init) { Config.nearRadius = r; Config.maxNear = 400 }
            case "--scale": o.scale = next().flatMap(Float.init)
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
                  --grade <n>          fuerza del tono PS2 (0 = neutro, 1 = por defecto). También ROCKPORT_GRADE.
                  --cam x,y,z,r,i      cámara inicial (metros; rumbo e inclinación en grados)
                  --drive              empezar conduciendo el BMW M3 GTR
                  --scale <f>          fija la escala de resolución (desactiva la dinámica)
                  --quit-after <s>     salir tras s segundos (pruebas)
                  --screenshot <png>   sin ventana: carga, dibuja --frames fotogramas, guarda PNG y sale
                  --size AxB           tamaño del modo sin ventana (1920x1080)
                  --bench              sin ventana: vuelo a 250 km/h durante --seconds y mide tiempos
                """)
                exit(0)
            default: fputs("argumento desconocido: \(args[i])\n", stderr)
            }
            i += 1
        }
        if o.grade == nil, let g = ProcessInfo.processInfo.environment["ROCKPORT_GRADE"].flatMap(Float.init) { o.grade = g }
        return o
    }
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
    if o.drive { engine.toggleMode() } else if o.car { engine.loadCar() }
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

let options = Options.parse(CommandLine.arguments)
if options.screenshot != nil || options.bench {
    runHeadless(options)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
