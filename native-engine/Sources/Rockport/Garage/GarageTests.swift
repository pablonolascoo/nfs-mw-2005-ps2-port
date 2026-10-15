// Pruebas sin ventana de los garajes:
//   Rockport --garage-test zone_safehouse_1 --screenshot base.png [--size WxH] [--garage-mode drive|inside|menu|list]
//     drive  (por defecto): el coche sale a 18 m de la puerta y un piloto automático entra despacio, aparca y abre los menús.
//            Capturas base-1-fuera.png (puerta subiendo), base-2-dentro.png, base-3-aparcado.png (menú del sitio).
//     inside: el coche ya aparcado en la plaza (menú directo).
//     list:   todas las zonas: coloca cada garaje y escribe fondo, ancho, plaza y muros (sin capturas).
//   --garage-screen <pantalla> en modo inside: blacklist | carlot | mycars | customize | parts | visual | paint | rims | spoiler | vinyl | lightbar
import Foundation
import Metal
import QuartzCore
import simd

enum GarageTestOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var zone: String? { value("--garage-test") }
    static var mode: String { value("--garage-mode") ?? "drive" }
    static var screen: String? { value("--garage-screen") }
}

func runGarageTest(_ o: Options, zone: String) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    guard let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor\n", stderr); exit(1) }
    Career.shared.persist = false
    CarTuning.persist = false
    Career.shared.attach(engine)
    let ui = engine.enableUI(outputFormat: .bgra8Unorm)
    ui?.startGame()
    guard let gs = GarageSystem.attach(engine), let world = gs.world else { fputs("garajes: falta garages.json o interiors/\n", stderr); exit(1) }
    GarageSystem.fixedStep = 1.0 / 60
    world.log = { print($0) }
    if GarageTestOptions.mode == "list" {
        engine.loadCar()
        for info in world.infos { _ = world.debugPlace(zone: info.key, insideAt: false) }
        exit(0)
    }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!
    var clock = 0.0
    func render(_ dt: Float) {
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: o.scale ?? 1, now: clock)
        cb.commit(); cb.waitUntilCompleted()
    }
    func settle() {
        let t0 = CACurrentMediaTime()
        while true {
            clock += 1.0 / 60; render(0)
            let s = engine.streamer.stats
            if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && clock > 0.5 { break }
            if CACurrentMediaTime() - t0 > 60 { break }
            usleep(5000)
        }
    }
    let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
    func shot(_ suffix: String) { if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-\(suffix).png") } }

    let inside = GarageTestOptions.mode != "drive"
    guard let g = world.debugPlace(zone: zone, insideAt: inside) else { fputs("No existe la zona «\(zone)»\n", stderr); exit(1) }
    if engine.mode != .drive { engine.toggleMode() }
    settle()
    if !inside {
        // Piloto automático: hacia la puerta y luego a la plaza, despacio
        var stage = 0
        engine.driverFilter = { d, _, _ in
            guard let car = engine.car else { return }
            let target = stage == 0 ? g.doorP + g.out * 4 : g.spot
            let to = target - car.position
            let dist = simd_length(SIMD2(to.x, to.y))
            if stage == 0 && dist < 2.5 { stage = 1 }
            let want = atan2(to.y, to.x)
            var e = want - car.yaw
            while e > .pi { e -= 2 * .pi }; while e < -.pi { e += 2 * .pi }
            let steer = max(-1, min(1, e * 2.2))
            d.steerLeft = max(0, steer); d.steerRight = max(0, -steer)
            let vmax: Float = stage == 0 ? 6 : max(0, min(4, dist * 0.9))
            if car.speed < vmax - 0.5 { d.gas = 0.55; d.brake = 0 } else if car.speed > vmax + 0.3 { d.gas = 0; d.brake = 0.8 } else { d.gas = 0.1; d.brake = 0 }
            if stage == 1 && dist < 1.2 { d.gas = 0; d.brake = 1 }
        }
        var shotOut = false, shotIn = false
        for i in 0..<(60 * 40) {
            clock += 1.0 / 60
            render(1.0 / 60)
            let ph = world.debugPhase
            if !shotOut, ph == .opening, (g.door?.open ?? 0) > 0.55 { shot("1-fuera"); shotOut = true }
            if !shotIn, ph == .inside, let car = engine.car, simd_distance(car.position, g.spot) < 6 { shot("2-dentro"); shotIn = true }
            if ph == .menu || ph == .parked { print("Aparcado en \(i / 60) s"); break }
        }
        engine.driverFilter = nil
    } else if let car = engine.car {
        // Coche ya en la plaza: aparcar al momento
        for _ in 0..<45 { clock += 1.0 / 60; render(1.0 / 60) }
        _ = car
    }
    // Menús con la cámara del frontend (la simulación está en pausa: la cámara anima con el paso fijo)
    for _ in 0..<(60 * 4) { clock += 1.0 / 60; render(1.0 / 60) }
    if let scr = GarageTestOptions.screen, let ui {
        switch scr {
        case "blacklist": ui.leaveTopScreen { ui.showSafehouseMenu(); ui.showSafehouseBlacklistForTest() }
        case "carlot": ui.showCarLot(owned: false)
        case "mycars": ui.showCarLot(owned: true)
        case "customize": ui.showCustomizeMain()
        case "parts": ui.showCustomizeCategory(parts: true)
        case "visual": ui.showCustomizeCategory(parts: false)
        case "paint": ui.showTuneList(.paint)
        case "rims": ui.showTuneList(.rims)
        case "spoiler": ui.showTuneList(.spoiler)
        case "vinyl": ui.showTuneList(.vinyl)
        case "kit": ui.showTuneList(.kit)
        case "lightbar": ui.showTuneList(.lightBar)
        default: break
        }
        if let n = GarageTestOptions.value("--garage-select").flatMap(Int.init), let s = ui.screens.last {
            if let sc = s.scroller { for _ in 0..<n { _ = sc.scroll(1) }; sc.snap(); s.refreshHeader() }
            else if let f = s.onLeftRight { for _ in 0..<n { f(1) } }
        }
        for _ in 0..<(60 * 3) { clock += 1.0 / 60; render(1.0 / 60) }
    }
    print("Fase final: \(world.debugPhase.rawValue) · cámara \(world.mover.current)")
    shot("3-aparcado")
    exit(0)
}

extension FEUI {
    func showSafehouseBlacklistForTest() {
        screens.removeAll()
        engine.garages?.world?.screenAngle("career_safehousereputationoverview")
        blacklistCash = Career.shared.save.cash
        showBlacklist(Career.shared.rivals(), selected: Career.shared.save.currentBin) { _ in }
    }
}
