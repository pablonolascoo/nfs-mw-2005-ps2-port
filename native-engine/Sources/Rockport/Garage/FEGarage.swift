// Escenario del frontend: el garaje con el coche del jugador que el juego dibuja detrás de los menús
// (GarageMainScreen + SelectCarCameraMover [D]).
//
// - Interior por tipo de garaje (FEManager::GetGarageNameFromType [D]): menú principal = PLATFORMCRIB, refugio =
//   CAREER_SAFEHOUSE, taller = CUSTOMIZATION_SHOP (o BACKROOM), concesionario = CAR_LOT.
// - Colocación (GarageMainScreen::Get*): el interior gira GeometryZAngle (menú 134,4125°, refugio 302,85309°, taller y
//   concesionario 0°) y el coche está en el origen girado CarRotationZ (304,96979°; concesionario 340° con X −0,38°) [D].
// - Cámara: parámetros de la clase `frontend` de GLOBAL\FE_ATTRIB.BIN [V] (cam_orbit_vertical/horizontal/radius,
//   cam_lookat_xyz, cam_roll_angle, cam_fov, cam_anim_speed, cam_damping, cam_periods). Al entrar va de
//   angle_entry_<garaje> a angle_final_<garaje>; cada pantalla pone su cam_angle (mainmenu → angle3,
//   career_mainmenu_sub → angle10, customize_customizemain → angle13).
//   SelectCarCameraMover::CreateCameraMatrix (SLUS 0x1772B0) [V: ensamblador]: M = RotZ(H)·RotX(V)·Trans(0,0,R);
//   ojo = traslación de M⁻¹; arriba = ComputeBankedUpVector(ojo, lookAt, roll); vista = eCreateLookAtMatrix.
//   Con las filas de bMatrix4 (v·M) eso da ojo = (−R·sinV·sinH, −R·sinV·cosH, −R·cosV) [I: convención de signos de
//   eRotate*; comprobado porque así el coche sale de tres cuartos por delante y la cámara queda a 0,7 m del suelo].
// - Las animaciones de cámara (anim_speed s, damping, periods) se aproximan con un muelle amortiguado [I: el mover no está
//   decompilado].
import Foundation
import Metal
import simd

/// Garajes del juego (eGarageType [D]).
enum GarageKind: String, CaseIterable {
    case mainFE = "main_fe", safehouse = "career_safehouse", customShop = "customization_shop", backroom = "backroom", carLot = "car_lot"
    var interior: String {
        switch self {
        case .mainFE: return "PLATFORMCRIB"
        case .safehouse: return "CAREER_SAFEHOUSE"
        case .customShop: return "CUSTOMIZATION_SHOP"
        case .backroom: return "CUSTOMIZATION_SHOP_BACKROOM"
        case .carLot: return "CAR_LOT"
        }
    }
    /// GarageMainScreen::GetGeometryZAngle [D].
    var geometryZAngle: Float {
        switch self {
        case .safehouse: return 302.85309
        case .customShop, .backroom, .carLot: return 0
        case .mainFE: return 134.4125
        }
    }
    /// GarageMainScreen::GetCarRotationZ / X [D].
    var carRotationZ: Float { self == .carLot ? 340 : 304.96979 }
    var carRotationX: Float { self == .carLot ? -0.379623 : 0 }
    /// Desplazamiento Y de la geometría (concesionario 0,075) [D].
    var geometryY: Float { self == .carLot ? 0.075 : 0 }
    static func forZone(_ zoneType: String) -> GarageKind {
        switch zoneType { case "carlot": return .carLot; case "customshop": return .customShop; default: return .safehouse }
    }
}

/// Un ángulo de cámara de FE_ATTRIB.BIN (SelectCarCameraData).
struct FECameraAngle {
    var orbitV: Float, orbitH: Float, radius: Float, roll: Float, fov: Float
    var lookAt: float3
    var animSpeed: Float = 0.5, damping: Float = 8, periods: Int = 1

    /// Ángulos y pantallas del disco: fe-cameras.json (tools/src/cli/fe-cameras.ts, GLOBAL\FE_ATTRIB.BIN) [V].
    static var table: [String: FECameraAngle] = [:]
    /// Pantalla → ángulo (cam_angle): «mainmenu» → angle3, «career_mainmenu_sub» → angle10…
    static var screens: [String: String] = [:]
    /// Sin fe-cameras.json (datos de antes de DATA_FORMAT 5): un tres cuartos genérico [I].
    static let fallback = FECameraAngle(orbitV: 95, orbitH: -20, radius: 6, roll: 0, fov: 55, lookAt: float3(0, 0, 0.6), animSpeed: 0.6, damping: 8, periods: 1)

    private struct File: Decodable {
        struct A: Decodable { let orbitV: Float; let orbitH: Float; let radius: Float; let roll: Float; let fov: Float; let lookAt: [Float]; let animSpeed: Float; let damping: Float; let periods: Int }
        let angles: [String: A]; let screens: [String: String]
    }
    static func load(_ data: GameData) {
        guard table.isEmpty, let f = try? JSONDecoder().decode(File.self, from: Data(contentsOf: data.url("fe-cameras.json"))) else { return }
        for (k, a) in f.angles {
            table[k] = FECameraAngle(orbitV: a.orbitV, orbitH: a.orbitH, radius: a.radius, roll: a.roll, fov: a.fov,
                                     lookAt: a.lookAt.count == 3 ? float3(a.lookAt[0], a.lookAt[1], a.lookAt[2]) : .zero,
                                     animSpeed: a.animSpeed, damping: a.damping, periods: max(1, a.periods))
        }
        screens = f.screens
    }
    /// Ángulo de una pantalla («mainmenu») o un ángulo por nombre («angle3»).
    static func forScreen(_ s: String) -> FECameraAngle { screens[s].flatMap { table[$0] } ?? table[s] ?? fallback }
    static func named(_ n: String) -> FECameraAngle { table[n] ?? table["angle_qr_default"] ?? fallback }

    /// Ojo en el espacio del escenario (coche en el origen, suelo z = 0) [V/I: CreateCameraMatrix].
    var eye: float3 {
        let v = orbitV * .pi / 180, h = orbitH * .pi / 180
        return float3(-radius * sin(v) * sin(h), -radius * sin(v) * cos(h), -radius * cos(v))
    }

    static func lerp(_ a: FECameraAngle, _ b: FECameraAngle, _ t: Float) -> FECameraAngle {
        var o = b
        // FindBestAngleGoal: el giro horizontal va por el camino corto [D: nombre de la función]
        var dh = (b.orbitH - a.orbitH).truncatingRemainder(dividingBy: 360)
        if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        o.orbitH = a.orbitH + dh * t
        o.orbitV = a.orbitV + (b.orbitV - a.orbitV) * t
        o.radius = a.radius + (b.radius - a.radius) * t
        o.roll = a.roll + (b.roll - a.roll) * t
        o.fov = a.fov + (b.fov - a.fov) * t
        o.lookAt = a.lookAt + (b.lookAt - a.lookAt) * t
        return o
    }
}

/// SelectCarCameraMover: de un ángulo a otro con animación amortiguada.
final class FECameraMover {
    private(set) var current: FECameraAngle
    private var start: FECameraAngle, goal: FECameraAngle
    private var t: Float = 0, total: Float = 0
    var userH: Float = 0
    init(_ a: FECameraAngle) { current = a; start = a; goal = a }
    func setCurrent(_ a: FECameraAngle) { current = a; start = a; goal = a; t = 0; total = 0 }
    func setDesired(_ a: FECameraAngle) { start = current; goal = a; t = 0; total = max(0.05, a.animSpeed) }
    var settled: Bool { t >= total }
    func update(dt: Float) {
        guard total > 0 else { current = goal; return }
        t = min(total, t + dt)
        let u = t / total
        // Muelle amortiguado: llega con «periods» oscilaciones que se apagan con «damping» [I]
        let k = 1 - exp(-goal.damping * u) * cos(Float(goal.periods) * .pi * u * 0.5)
        current = FECameraAngle.lerp(start, goal, u >= 1 ? 1 : min(1.02, max(0, k)))
    }

    /// Vista desde el escenario colocado en `origin`; `aspect` de la pantalla.
    func matrices(origin: float3, aspect: Float, radiusScale: Float = 1) -> (view: float4x4, proj: float4x4, eye: float3) {
        var c = current
        c.radius *= radiusScale
        // Depuración: ROCKPORT_FE_CAM="V,H,R,lx,ly,lz[,fov]" fija el ángulo
        if let e = ProcessInfo.processInfo.environment["ROCKPORT_FE_CAM"] {
            let v = e.split(separator: ",").compactMap { Float($0) }
            if v.count >= 6 { c = FECameraAngle(orbitV: v[0], orbitH: v[1], radius: v[2], roll: 0, fov: v.count > 6 ? v[6] : 55, lookAt: float3(v[3], v[4], v[5])) }
        }
        c.orbitH += userH
        let eye = origin + c.eye
        let target = origin + c.lookAt
        // ComputeBankedUpVector: el «arriba» del mundo girado `roll` grados alrededor de la dirección de vista
        let f = simd_normalize(target - eye)
        let r0 = simd_normalize(simd_cross(f, float3(0, 0, 1)))
        let u0 = simd_cross(r0, f)
        let a = c.roll * .pi / 180
        let up = u0 * cos(a) + r0 * sin(a)
        let view = float4x4.lookAt(eye: eye, target: target, up: up)
        // cam_fov es el campo horizontal en 4:3 del PS2; en panorámico se conserva el vertical (Hor+) [I]
        let vfov = 2 * atan(tan(c.fov * .pi / 360) * 0.75)
        return (view, .perspectiveReversedInfinite(fovY: vfov, aspect: aspect, near: 0.1), eye)
    }
}

/// El escenario del frontend: interior + coche del jugador + cámara, lejos de la ciudad.
final class FEStage {
    /// Lejos del mapa y fuera del plano del mar (±20 km alrededor de (2200, 1800)): nada del mundo se ve desde aquí.
    static let origin = float3(-30000, -30000, 0)
    unowned let engine: Engine
    let library: InteriorLibrary
    private(set) var kind: GarageKind = .mainFE
    private(set) var car: Car?
    private var carKey = ""
    let mover = FECameraMover(FECameraAngle.fallback)
    private(set) var active = false
    private let ground = FlatGround(z: FEStage.origin.z)

    init(engine: Engine, library: InteriorLibrary) {
        self.engine = engine; self.library = library
        FECameraAngle.load(engine.data)
    }

    /// Entra en el frontend con un garaje: cámara de entrada → final (GarageMainScreen::GarageMainScreen [D]).
    func enter(_ k: GarageKind, preset: String? = nil, animate: Bool = true) {
        kind = k
        active = true
        loadCar(preset: preset)
        let entry = FECameraAngle.table["angle_entry_\(k.rawValue)"], final = FECameraAngle.table["angle_final_\(k.rawValue)"] ?? FECameraAngle.named("angle_qr_default")
        if animate, let entry { mover.setCurrent(entry); mover.setDesired(final) } else { mover.setCurrent(final) }
    }
    func leave() { active = false }

    /// Ángulo de la pantalla (cam_angle de su colección: mainmenu → angle3…).
    func screenAngle(_ name: String) { mover.setDesired(FECameraAngle.forScreen(name)) }

    /// Coche del jugador: el de la carrera profesional o el preset por defecto (BMW M3 GTR de la historia).
    func loadCar(preset: String? = nil) {
        let want = preset ?? Career.shared.currentCarPreset ?? Config.playerPreset ?? Config.playerCar
        guard want != carKey || car == nil else { place(); return }
        car = CarTuning.build(want, engine: engine)
        carKey = want
        place()
    }
    func setCar(_ c: Car, key: String) { car = c; carKey = key; place() }

    private func place() {
        guard let car else { return }
        car.place(FEStage.origin + float3(0, 0, 0.5), yaw: kind.carRotationZ * .pi / 180, ground: ground, probe: 2)
        // Unos pasos de física parado para que la suspensión se asiente
        for _ in 0..<40 { car.update(dt: 1.0 / 60, input: Car.Input(), collision: ground) }
    }

    func update(dt: Float) {
        guard active else { return }
        mover.update(dt: dt)
        car?.update(dt: dt, input: Car.Input(handbrake: true), collision: ground)
    }

    /// Matrices de las piezas con las ruedas delanteras giradas CarSelectTireSteerAngle = 21,6723° [D].
    var carParts: [float4x4]? {
        guard let car else { return nil }
        var parts = car.partMatrices
        let a = 21.6723 * Float.pi / 180
        for i in [1, 2, 5, 6] where i < parts.count { parts[i] = parts[i] * float4x4(rotationZ: a) }
        return parts
    }

    /// Lo que dibuja la capa de garajes en el frontend.
    var drawItems: [GarageDrawItem] {
        guard active, let m = library.mesh(kind.interior) else { return [] }
        let model = float4x4(translation: FEStage.origin + float3(0, kind.geometryY, 0)) * float4x4(rotationZ: kind.geometryZAngle * .pi / 180)
        return [GarageDrawItem(mesh: m, model: model, clip: nil)]
    }

    /// Fotograma del frontend: sin mundo, el interior lo pone la capa de garajes y el coche va en el sitio del jugador.
    func apply(_ f: inout SceneFrame, aspect: Float) {
        guard active else { return }
        let m = mover.matrices(origin: FEStage.origin, aspect: aspect)
        f.view = m.view; f.proj = m.proj; f.camPos = m.eye
        f.meshes = []
        f.extraCars = []
        if let car, let parts = carParts { f.car = (car.mesh, parts); f.carShadow = car.shadowMatrix } else { f.car = nil; f.carShadow = nil }
    }
}
