// Ajustes globales del motor. Todo lo que un usuario querría tocar está aquí.
import simd

enum Config {
    // MARK: Tono PS2
    /// Fuerza del "tono PS2" (0 = imagen neutra, 1 = tono por defecto, >1 exagerado).
    /// Un único número controla el tinte cálido amarillo/ámbar, el negro levantado y el ajuste de saturación.
    /// Se puede cambiar al arrancar con `--grade <n>` o la variable `ROCKPORT_GRADE`.
    static let ps2GradeStrength: Float = 1.0

    // MARK: Streaming de casillas (igual que viewer/src/main.ts)
    /// Distancia (m, de la cámara a la caja de la casilla) por debajo de la cual se carga el nivel con textura.
    static var nearRadius: Float = 650
    /// Las casillas con detalle se liberan si quedan más lejos que esto durante `keepSeconds`.
    static let keepRadius: Float = 1100
    static let keepSeconds: Double = 5
    /// Máximo de casillas con detalle a la vez.
    static var maxNear = 28
    /// Cargas de casillas en paralelo (hilos de fondo).
    static let parallelLoads = 4

    // El nivel lejano ya no lleva corrección de brillo: el conversor guarda su color (color medio × luz horneada)
    // como (c/128)^2,2, igual que el cercano. Medido [V] en la misma vista: lejano/cercano ≈ 0,95–1,2 (antes 1,8).

    // MARK: Resolución dinámica
    /// Objetivo de tiempo de GPU por fotograma (ms). Por debajo de 16,7 ms para dejar margen al vsync de 60 Hz.
    static let gpuBudgetMs: Double = 13.5
    static let minRenderScale: Float = 0.5
    static let maxRenderScale: Float = 1.0

    // MARK: Cámara
    static let fovYDegrees: Float = 55
    static let nearPlane: Float = 0.3

    // MARK: Cielo y niebla (colores sRGB del visor web)
    static let skyHorizon = SIMD3<Float>(0x8f, 0xa3, 0xad) / 255
    static let skyHaze = SIMD3<Float>(0xd9, 0xc7, 0xa2) / 255
    static let skyZenith = SIMD3<Float>(0x3d, 0x5a, 0x73) / 255
    static let fogStart: Float = 1200
    static let fogEnd: Float = 9000

    // MARK: Luz del coche (los coches no traen luz horneada). Igual que viewer/src/main.ts.
    /// HemisphereLight(0xdfe8ff, 0x2a2416, 1.4) y DirectionalLight(0xffe2b0, 2.2) en (30, -20, 50).
    static let hemiSky = SIMD3<Float>(0xdf, 0xe8, 0xff) / 255
    static let hemiGround = SIMD3<Float>(0x2a, 0x24, 0x16) / 255
    static let hemiIntensity: Float = 1.4
    static let sunColor = SIMD3<Float>(0xff, 0xe2, 0xb0) / 255
    static let sunIntensity: Float = 2.2
    static let sunPosition = SIMD3<Float>(30, -20, 50)

    /// Color de pintura del coche del jugador (BMW M3 GTR: plata).
    static let playerPaint = SIMD3<Float>(0xae, 0xb7, 0xc2) / 255
    static let playerCar = "BMWM3GTRE46"
}
