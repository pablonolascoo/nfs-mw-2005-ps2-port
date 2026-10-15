// Pruebas sin ventana de las escenas de garaje (GarageScenes.swift):
//   Rockport --garage-scene <tipo> [--fe-angle <pantalla o ángulo>] [--scene-car <preset o coche>] --screenshot x.png
//     tipo: main_fe | career_safehouse | customization_shop | backroom | car_lot (escenario del frontend tal cual)
//     --fe-angle: «carlot_car_select», «angle_final_car_lot», «customize_customizemain»… (fe-cameras.json)
//   Rockport --garage-scene-list   escribe las escenas de garage-scenes/ (zona, interior, tramos, colisión)
import Foundation
import Metal
import simd

enum GarageSceneTestOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var kind: String? { value("--garage-scene") }
    static var angle: String? { value("--fe-angle") }
    static var car: String? { value("--scene-car") }
    static var swapZone: String? { value("--garage-swap-test") }
}

/// Cambio de coche sin pantalla de carga: aparca en la zona, abre «Mis coches» (refugio) o el concesionario y trae el
/// coche --scene-car (por defecto el 2.º del concesionario). Capturas base-swap-0…5 durante la animación.
func runGarageSwapTest(_ o: Options, zone: String) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    guard let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor\n", stderr); exit(1) }
    Career.shared.persist = false
    CarTuning.persist = false
    Career.shared.attach(engine)
    let ui = engine.enableUI(outputFormat: .bgra8Unorm)
    ui?.startGame()
    guard let gs = GarageSystem.attach(engine), let world = gs.world, let ui else { fputs("garajes\n", stderr); exit(1) }
    GarageSystem.fixedStep = 1.0 / 60
    world.log = { print($0) }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!
    var clock = 0.0
    func render(_ n: Int) { for _ in 0..<n { clock += 1.0 / 60; let cb = engine.queue.makeCommandBuffer()!; engine.frame(cb: cb, target: target, dt: 1.0 / 60, scale: o.scale ?? 1, now: clock); cb.commit(); cb.waitUntilCompleted() } }
    guard let g = world.debugPlace(zone: zone, insideAt: true) else { fputs("No existe la zona «\(zone)»\n", stderr); exit(1) }
    if engine.mode != .drive { engine.toggleMode() }
    render(60 * 5)
    let lot = g.kind == .carLot
    if lot { ui.showCarLot(owned: false) } else {
        // «Mis coches» con dos coches en la partida: el de ahora y el que se trae
        let extra = GarageSceneTestOptions.car ?? "MUSTANGGT"
        Career.shared.modifySave { if !$0.cars.contains(extra) { $0.cars.append(extra) } }
        ui.showCarLot(owned: true)
    }
    render(60 * 2)
    let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
    func shot(_ s: String) { if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-\(s).png") } }
    shot("swap-0-antes")
    if let s = ui.screens.last, let f = s.onLeftRight { f(1) }
    let marks = [12, 30, 55, 85, 130, 200]
    var t = 0
    for (i, m) in marks.enumerated() { render(m - t); t = m; shot("swap-\(i + 1)"); print("  \(m) f: \(gs.scenes.swapDebug)") }
    print("Cambio de coche: animando \(gs.scenes.swapping ? "sí" : "no") · fase \(world.debugPhase.rawValue)")
    exit(0)
}

func runGarageSceneTest(_ o: Options, kind: String) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    guard let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor\n", stderr); exit(1) }
    Career.shared.persist = false
    CarTuning.persist = false
    guard let gs = GarageSystem.attach(engine), let k = GarageKind(rawValue: kind) else {
        fputs("garaje: tipo desconocido «\(kind)» (main_fe, career_safehouse, customization_shop, backroom, car_lot)\n", stderr); exit(1)
    }
    GarageSystem.fixedStep = 1.0 / 60
    gs.stage.enter(k, preset: GarageSceneTestOptions.car, animate: false)
    if let a = GarageSceneTestOptions.angle { gs.stage.mover.setCurrent(FECameraAngle.forScreen(a)) }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!
    var clock = 0.0
    for _ in 0..<90 {
        clock += 1.0 / 60
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: 0, scale: o.scale ?? 1, now: clock)
        cb.commit(); cb.waitUntilCompleted()
    }
    print("Escena \(k.rawValue) · interior \(k.interior) · cámara \(gs.stage.mover.current)")
    if let p = o.screenshot { writePNG(target, device: device, queue: engine.queue, path: p); print("Captura: \(p)") }
    exit(0)
}
