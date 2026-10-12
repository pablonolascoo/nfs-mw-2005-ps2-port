// Atributos VLT de un vehículo, leídos de map-data/<ID>/physics.json (tools/src/cli/physics-attribs.ts).
// Cada clase es la colección del índice 0 del array RefSpec del pvehicle, con herencia resuelta [D: Behavior.h LookupKey].
// Los nombres de campo son los del juego (chassis.SPRING_STIFFNESS…). AxlePair = [delante, detrás].
import Foundation

struct VehicleSpecs: Decodable {
    struct Chassis: Decodable {
        let WHEEL_BASE: Float, DRAG_COEFFICIENT: Float, AERO_COEFFICIENT: Float, AERO_CG: Float
        let FRONT_AXLE: Float, FRONT_WEIGHT_BIAS: Float, ROLL_CENTER: Float, SHOCK_BLOWOUT: Float
        let SHOCK_VALVING: [Float], RIDE_HEIGHT: [Float], SHOCK_STIFFNESS: [Float], SHOCK_EXT_STIFFNESS: [Float]
        let SWAYBAR_STIFFNESS: [Float], TRAVEL: [Float], SPRING_STIFFNESS: [Float], SPRING_PROGRESSION: [Float]
        let TRACK_WIDTH: [Float], SHOCK_DIGRESSION: [Float]
    }
    struct Tires: Decodable {
        let SECTION_WIDTH: [Float], ASPECT_RATIO: [Float], RIM_SIZE: [Float]
        let STATIC_GRIP: [Float], DYNAMIC_GRIP: [Float], GRIP_SCALE: [Float]
        let YAW_CONTROL: [Float], YAW_SPEED: Float, STEERING: Float
    }
    struct Engine: Decodable {
        let TORQUE: [Float], ENGINE_BRAKING: [Float], SPEED_LIMITER: [Float]
        let IDLE: Float, MAX_RPM: Float, RED_LINE: Float, FLYWHEEL_MASS: Float
    }
    struct Transmission: Decodable {
        let GEAR_RATIO: [Float], GEAR_EFFICIENCY: [Float], DIFFERENTIAL: [Float]
        let FINAL_GEAR: Float, TORQUE_SPLIT: Float, TORQUE_CONVERTER: Float, CLUTCH_SLIP: Float, SHIFT_SPEED: Float, OPTIMAL_SHIFT: Float
    }
    struct Brakes: Decodable { let BRAKES: [Float], BRAKE_LOCK: [Float], EBRAKE: Float }
    struct Induction: Decodable {
        let HIGH_BOOST: Float, LOW_BOOST: Float, SPOOL: Float, SPOOL_TIME_UP: Float, SPOOL_TIME_DOWN: Float, PSI: Float, VACUUM: Float
    }
    struct Nos: Decodable {
        let TORQUE_BOOST: Float, NOS_CAPACITY: Float, NOS_DISENGAGE: Float, FLOW_RATE: Float
        let RECHARGE_MIN: Float, RECHARGE_MAX: Float, RECHARGE_MIN_SPEED: Float, RECHARGE_MAX_SPEED: Float
    }
    struct RigidBodySpecs: Decodable {
        let GRAVITY: Float, WALL_FRICTION: [Float], GROUND_FRICTION: [Float], WALL_ELASTICITY: [Float], GROUND_ELASTICITY: [Float]
        let WORLD_MOMENT_SCALE: [Float], GROUND_MOMENT_SCALE: [Float]
    }
    struct CameraInfo: Decodable {
        let FOV: [Float], HEIGHT: [Float], LAG: [Float], ANGLE: [Float], STIFFNESS: [Float], LATOFFSET: [Float], TILTING: [Bool]
        let SELECTABLE: [Bool]?
    }

    let model: String
    let mass: Float
    let tensorScale: [Float]
    let chassis: Chassis
    let tires: Tires
    let engine: Engine
    let transmission: Transmission
    let brakes: Brakes
    let induction: Induction
    let nos: Nos
    let rigidbody: RigidBodySpecs
    let cameras: [String: CameraInfo]?
}

struct ControllerRecord: Decodable { let device: String?; let updateType: Int; let lowerDZ: Float; let upperDZ: Float }

struct PhysicsFile: Decodable {
    /// Se decodifica cada vehículo por separado: las plantillas (default, traffic…) pueden no tener todas las clases.
    let vehicles: [String: FailableSpecs]
    let controller: [String: [ControllerRecord]]?
    struct FailableSpecs: Decodable {
        let specs: VehicleSpecs?
        init(from d: Decoder) throws { specs = try? VehicleSpecs(from: d) }
    }

    static func load(_ data: GameData) -> PhysicsFile? {
        let url = data.url("physics.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(PhysicsFile.self, from: d) }
        catch { fputs("physics.json: \(error)\n", stderr); return nil }
    }

    /// Colección pvehicle de un modelo: la que tiene ese MODEL o ese nombre (en minúsculas). BMWM3 → bmwm3gtr [V: cars.json].
    func specs(model: String) -> VehicleSpecs? {
        let k = model.lowercased()
        if let s = vehicles[k]?.specs { return s }
        if let s = vehicles.values.compactMap(\.specs).first(where: { $0.model.lowercased() == k }) { return s }
        return GameData.attribAlias[k].flatMap { vehicles[$0]?.specs }
    }
}
