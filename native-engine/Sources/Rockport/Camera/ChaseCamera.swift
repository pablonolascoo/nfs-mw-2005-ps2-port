// Cámara de persecución con los valores del juego: clase camerainfo (FOV, HEIGHT, LAG, ANGLE, STIFFNESS, LATOFFSET,
// TILTING) de cada vista del coche (ecar.CameraInfo_Close/Far/Bumper/Hood…) [V: physics.json].
// El movimiento de la cámara del juego (CubicCameraMover, Camera/Movers/Cubic.cpp) NO está decompilado: el muelle,
// el retraso de rumbo y el FOV con la velocidad son propios [H]. Cada valor es un par: el primero es el de pantalla completa
// y el segundo el de pantalla partida (CameraInfo: FullScreenPOVArray / SplitScreenPOVArray [D]); `splitScreen` elige.
import Foundation
import simd

final class ChaseCamera {
    struct View { let name: String; let info: VehicleSpecs.CameraInfo }
    let views: [View]
    private(set) var index: Int
    private(set) var eye = float3(0, 0, 0), target = float3(0, 0, 0), up = float3(0, 0, 1)
    private(set) var fovY: Float = 55
    private var vel = float3(0, 0, 0)
    private var heading: Float = 0
    private var initialized = false
    private var fovExtra: Float = 0
    /// Pantalla partida (Multiplayer/): usa el segundo valor de cada par de camerainfo.
    var splitScreen = false

    /// Orden de las vistas como en el menú del juego: parachoques, capó, cerca, lejos [I].
    static let order = ["bumper", "hood", "close", "far"]

    init(specs: VehicleSpecs?) {
        let cams = specs?.cameras ?? [:]
        var v: [View] = []
        for n in ChaseCamera.order { if let c = cams[n] { v.append(View(name: n, info: c)) } }
        views = v
        index = v.firstIndex { $0.name == "far" } ?? max(0, v.count - 1)      // por defecto: lejos [I]
        // Desarrollo/capturas: ROCKPORT_CAMERA=bumper|hood|close|far
        if let want = ProcessInfo.processInfo.environment["ROCKPORT_CAMERA"], let i = v.firstIndex(where: { $0.name == want }) { index = i }
    }

    var current: View? { views.isEmpty ? nil : views[index] }
    func next(_ d: Int) { guard !views.isEmpty else { return }; index = (index + d + views.count) % views.count; initialized = false }

    /// FOV del juego (grados, horizontal [I]) → vertical para el aspecto de la pantalla.
    static func verticalFov(_ h: Float, aspect: Float) -> Float { 2 * atan(tan(h * .pi / 360) / max(aspect, 0.1)) * 180 / .pi }

    func update(dt: Float, car: Car, lookBack: Bool, aspect: Float) {
        let f = car.forward
        let upCar = float3(0, 0, 1)
        let speed = simd_length(car.velocity)
        guard let v = current?.info else {
            // Sin physics.json: la cámara de siempre
            let want = car.position - f * (6.5 + car.kmh / 60) + float3(0, 0, 2.3 + car.kmh / 160)
            eye += (want - eye) * min(1, dt * 6); target = car.position + f * 3 + float3(0, 0, 1.1); up = upCar
            fovY = 55; return
        }
        func pick<T>(_ a: [T]) -> T? { splitScreen && a.count > 1 ? a[1] : a.first }
        let height = pick(v.HEIGHT) ?? 1.7, lag = pick(v.LAG) ?? -5, angle = pick(v.ANGLE) ?? 0
        let stiff = pick(v.STIFFNESS) ?? 0.5, lat = pick(v.LATOFFSET) ?? 0
        let inside = lag > 0                                  // parachoques y capó: LAG positivo, dentro del coche
        // Rumbo de la cámara: sigue al coche con retraso; derrapando mira algo hacia donde va el coche [H]
        var want = car.yaw
        if speed > 5, !inside {
            let vel = car.velocity
            let vy = atan2(vel.y, vel.x)
            var d = vy - car.yaw; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            want = car.yaw + d * 0.35
        }
        if !initialized { heading = want }
        var dh = want - heading; while dh > .pi { dh -= 2 * .pi }; while dh < -.pi { dh += 2 * .pi }
        let rate: Float = inside ? 60 : 2 + 10 * stiff         // STIFFNESS 0,5 → 7 rad/s
        heading += dh * min(1, dt * rate)
        let hf = float3(cos(heading), sin(heading), 0), left = float3(-hf.y, hf.x, 0)
        let base = car.position
        var wantEye: float3, wantTarget: float3
        if lookBack {
            wantEye = base + f * (inside ? 0.5 : abs(lag) * 0.6) + float3(0, 0, max(height, 1.2))
            wantTarget = base - f * 20 + float3(0, 0, 1)
        } else if inside {
            // LAG/HEIGHT desde el centro del coche, mirando adelante con ANGLE grados hacia abajo
            let fwdOff = pick(v.LAG).map { name == "bumper" ? max($0, Float(car.halfLength) - 0.3) : $0 } ?? 0
            wantEye = base + f * fwdOff + left * lat + float3(0, 0, height)
            let pitch = angle * .pi / 180
            wantTarget = wantEye + f * (cos(pitch) * 20) - float3(0, 0, sin(pitch) * 20)
        } else {
            wantEye = base + hf * lag + left * lat + float3(0, 0, height)
            wantTarget = base + hf * 3 + float3(0, 0, 0.9 - angle * 0.05)
        }
        if !initialized || inside || lookBack { eye = wantEye; vel = car.velocity; initialized = true }
        else {
            // Muelle crítico hacia la posición deseada; se alarga un poco al acelerar [H]
            let w: Float = 4 + 10 * stiff
            let x = eye - wantEye
            let a = -w * w * x - 2 * w * (vel - car.velocity)
            vel += a * dt; eye += vel * dt
        }
        target = wantTarget
        // Inclinación con el coche si TILTING (un poco, para no marear) [H]
        up = (pick(v.TILTING) ?? true) ? simd_normalize(float3(0, 0, 1) + left * sin(car.roll) * 0.3) : float3(0, 0, 1)
        // FOV: el de la vista + hasta 8° con la velocidad y 6° con nitro [H]
        let wantExtra = inside ? 0 : min(8, speed / 80 * 8) + (car.isNOSEngaged ? 6 : 0)
        fovExtra += (wantExtra - fovExtra) * min(1, dt * 3)
        fovY = ChaseCamera.verticalFov((pick(v.FOV) ?? 78) + fovExtra, aspect: aspect)
    }

    private var name: String { current?.name ?? "" }
}
