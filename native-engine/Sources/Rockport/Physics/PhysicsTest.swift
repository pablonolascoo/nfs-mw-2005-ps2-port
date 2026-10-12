// `--physics-test [COCHE]`: prueba con guion de la física del juego sobre un plano (sin mapa ni ventana).
// Mide 0–100 km/h, 0–60 mph, velocidad punta (60 s a fondo) y frenada 100→0 km/h, y un giro con freno de mano.
// Con `--physics-trace` imprime el estado cada 0,5 s (depuración).
import Foundation
import Metal
import simd

func runPhysicsTest(_ o: Options, carName: String) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    let textures = TextureCache(device: device)
    guard let car = Car(device: device, data: data, textures: textures, name: carName, paint: Config.playerPaint) else { fputs("no se pudo cargar \(carName)\n", stderr); exit(1) }
    guard car.specs != nil else { fputs("sin physics.json: genera map-data con tools/ (physics-attribs)\n", stderr); exit(1) }
    let flat = FlatGround(z: 0)
    let trace = CommandLine.arguments.contains("--physics-trace")
    let dt = PVehicle.timeStep

    func fresh() -> PVehicle { car.place(float3(0, 0, 0), yaw: 0, ground: flat); return car.vehicle! }
    func kmh(_ v: PVehicle) -> Float { v.speed * 3.6 }
    func log(_ t: Float, _ v: PVehicle) {
        guard trace else { return }
        let ts = v.susp.tires
        print(String(format: "t %5.2f · %6.1f km/h · %5.0f rpm · marcha %d · c %.3f %.3f %.3f %.3f · carga %.0f %.0f %.0f %.0f · tracc %.2f %.2f %.2f %.2f · y %.3f",
                     t, kmh(v), v.engine.rpm, v.engine.gear - 1, ts[0].compression, ts[1].compression, ts[2].compression, ts[3].compression,
                     ts[0].load, ts[1].load, ts[2].load, ts[3].load, ts[0].traction, ts[1].traction, ts[2].traction, ts[3].traction, v.rb.position.y))
    }
    print("Prueba de física · \(carName) · \(car.specs!.mass) kg · paso 1/60 s · plano sin muros")

    // 0. Reposo: 2 s parado (asentar la suspensión)
    var v = fresh()
    var idle = DriverInput()
    for i in 0..<120 { v.step(idle); if i % 30 == 0 { log(Float(i) * dt, v) } }
    let ts = v.susp.tires
    print(String(format: "Reposo: compresión del. %.3f / tras. %.3f m (estática calculada %.3f / %.3f) · ruedas en el suelo %d · deriva %.3f m",
                 ts[0].compression, ts[2].compression, v.staticCompression[0], v.staticCompression[1], v.susp.numWheelsOnGround,
                 simd_length(SIMD2(v.rb.position.x, v.rb.position.z))))

    // 1. Aceleración a fondo: 0–100 km/h, 0–60 mph, 400 m, punta en 60 s
    v = fresh()
    var full = DriverInput(); full.gas = 1
    var t: Float = 0, t100: Float = -1, t60: Float = -1, t200: Float = -1, t400m: Float = -1
    var top: Float = 0
    let start = v.rb.position
    var lastLog: Float = -1
    while t < 60 {
        v.step(full); t += dt
        let k = kmh(v)
        if t60 < 0 && v.speed >= PM.mph2mps(60) { t60 = t }
        if t100 < 0 && k >= 100 { t100 = t }
        if t200 < 0 && k >= 200 { t200 = t }
        if t400m < 0 && simd_length(v.rb.position - start) >= 402.3 { t400m = t }
        top = max(top, k)
        if t - lastLog >= 0.5 { log(t, v); lastLog = t }
    }
    print(String(format: "Aceleración: 0–60 mph %.2f s · 0–100 km/h %.2f s · 0–200 km/h %.2f s · 1/4 milla %.2f s · punta %.1f km/h (%.1f mph) en marcha %d a %.0f rpm",
                 t60, t100, t200, t400m, top, top / 1.609344, v.engine.gear - 1, v.engine.rpm))

    // 2. Frenada 100 → 0 km/h (lanzado a 100 km/h con MatchSpeed, freno a fondo)
    v = fresh()
    v.rb.linearVel = v.rb.forward * (100 / 3.6)
    v.susp.matchSpeed(100 / 3.6); v.engine.matchSpeed(100 / 3.6)
    var brake = DriverInput(); brake.brake = 1
    let b0 = v.rb.position
    t = 0
    while v.forwardSpeed > 0.1 && t < 20 { v.step(brake); t += dt }
    print(String(format: "Frenada 100→0 km/h: %.1f m en %.2f s", simd_length(v.rb.position - b0), t))

    // 3. Giro a 100 km/h: 3 s con el volante a tope a la derecha, luego freno de mano 1 s
    v = fresh()
    v.rb.linearVel = v.rb.forward * (100 / 3.6)
    v.susp.matchSpeed(100 / 3.6); v.engine.matchSpeed(100 / 3.6)
    var turn = DriverInput(); turn.gas = 0.6; turn.steerRight = 1
    var yawRate: Float = 0
    for _ in 0..<180 { v.step(turn) }
    yawRate = v.rb.toLocal(v.rb.angularVel).y
    let lat = v.rb.toLocal(v.rb.linearVel)
    print(String(format: "Curva a fondo (gas 0,6): %.1f km/h · giro %.1f °/s · aceleración lateral %.2f g · deriva %.1f°",
                 kmh(v), yawRate * 180 / .pi, abs(yawRate * v.speed) / 9.81, atan2(lat.x, lat.z) * 180 / .pi))
    // 3b. Derrape con freno de mano: a 100 km/h, volante a la derecha + freno de mano 0,6 s, luego gas a fondo 2 s
    v = fresh()
    v.rb.linearVel = v.rb.forward * (100 / 3.6)
    v.susp.matchSpeed(100 / 3.6); v.engine.matchSpeed(100 / 3.6)
    var hb = DriverInput(); hb.steerRight = 1; hb.handBrake = 1
    var maxSlip: Float = 0, maxState = 0
    for i in 0..<156 {
        if i == 36 { hb.handBrake = 0; hb.gas = 1; hb.steerRight = 0.3 }
        v.step(hb)
        let l = v.rb.toLocal(v.rb.linearVel)
        maxSlip = max(maxSlip, abs(atan2(l.x, max(l.z, 0.1))) * 180 / .pi)
        maxState = max(maxState, v.susp.driftState)
    }
    print(String(format: "Freno de mano a 100 km/h (0,6 s) y gas: deriva máxima %.1f° · estado de derrape máx. %d · %.1f km/h al final",
                 maxSlip, maxState, kmh(v)))

    // 4. NOS: 0–200 km/h con nitro a partir de 50 km/h
    v = fresh()
    var nos = DriverInput(); nos.gas = 1
    t = 0; var tn: Float = -1
    while t < 30 { nos.nos = kmh(v) > 50; v.step(nos); t += dt; if tn < 0 && kmh(v) >= 200 { tn = t; break } }
    print(String(format: "Con NOS: 0–200 km/h %.2f s (sin NOS %.2f s) · nitro restante %.0f %%", tn, t200, v.engine.nosCapacity * 100))
    _ = idle; idle = DriverInput()
    exit(0)
}
