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
