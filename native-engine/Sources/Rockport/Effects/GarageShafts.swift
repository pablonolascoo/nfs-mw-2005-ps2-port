// Haces de luz de las ventanas de las paredes que construimos para los garajes conducibles (garage-scenes/, doc 07 §5).
// Los interiores del disco traen sus propios rayos (CRIB1_LIGHTRAYS*, CSHOP_LIGHTRAYS01, QRACE_LIGHTRAYS01, SFX_LIGHTRAY:
// aditivos, doc 20 §1) y ya se dibujan; nuestras paredes (SHELL) llevan ventanas como calcomanías (CSHOP_WINDOW1…) sin luz.
// Aquí, por cada ventana, dos planos cruzados aditivos que bajan desde la ventana hacia dentro a 50° [I], con degradado a lo
// largo, bordes suaves y un leve movimiento de polvo (EffectsGPU.swift `fs_shaft`). Solo luz: no cambia la escena.
import Foundation
import Metal
import simd

final class GarageShafts {
    unowned let engine: Engine
    private var cacheZone: String?
    private var local: [float4] = []      // vértices en el marco de la puerta (pos, uvw)
    private var model = float4x4.identity
    /// Color y fuerza de los haces (luz de día cálida, como el sol de la calle) [I].
    static var colour = float4(1.0, 0.9, 0.68, 0.16)

    init(engine: Engine) { self.engine = engine }

    /// Triángulos de los haces del garaje del mundo abierto ahora (nil si no hay).
    func items(frame: SceneFrame) -> (verts: [float4], colour: float4)? {
        guard GarageCutout.active, let gs = engine.garages, !gs.stage.active, let g = gs.world?.current, let s = gs.scenes.activeScene else {
            return nil
        }
        if cacheZone != g.info.key { cacheZone = g.info.key; build(s) }
        guard !local.isEmpty else { return nil }
        var out = local
        for i in stride(from: 0, to: out.count, by: 2) { out[i] = s.model * float4(out[i].x, out[i].y, out[i].z, 1) }
        return (out, GarageShafts.colour)
    }

    private func build(_ s: GarageScenes.Scene) {
        local = []
        guard let mesh = s.shell else { return }
        let vb = mesh.vertexBuffer.contents().bindMemory(to: Vertex.self, capacity: mesh.vertexBuffer.length / MemoryLayout<Vertex>.stride)
        let ib = mesh.indexBuffer.contents().bindMemory(to: UInt32.self, capacity: mesh.indexBuffer.length / 4)
        let floorZ: Float = 0
        for d in mesh.draws where d.name.uppercased().contains("WINDOW") {
            // Cada ventana es un cuadrado de 2 triángulos: se agrupan de 6 en 6 índices
            var k = d.indexStart
            while k + 5 < d.indexStart + d.indexCount {
                var b = AABB.empty
                for j in 0..<6 { let v = vb[Int(ib[k + j])]; b.add(float3(v.px, v.py, v.pz)) }
                k += 6
                let size = b.size, c = b.center
                // Normal hacia dentro: el eje más fino de la caja; hacia el centro del volumen (x < 0, y → 0)
                // (paredes izquierda/derecha: y fino; fondo y fachada: x fino, el fondo mira a +x y la fachada a −x)
                let n: float3 = size.y < size.x ? float3(0, c.y > 0 ? -1 : 1, 0) : float3(c.x < s.info.shell.back * 0.5 ? 1 : -1, 0, 0)
                let width = max(size.x, size.y), height = size.z
                let ang: Float = 50 * .pi / 180
                let dir = simd_normalize(n * cos(ang) + float3(0, 0, -sin(ang)))
                let len = max(1, (c.z - floorZ) / sin(ang))
                let across = simd_normalize(simd_cross(n, float3(0, 0, 1)))
                // Plano 1: a lo ancho de la ventana; plano 2: a lo alto (perpendicular)
                let up = simd_normalize(simd_cross(dir, across))
                for (axis, half) in [(across, width * 0.5), (up, height * 0.5)] {
                    let a0 = c - axis * half, a1 = c + axis * half
                    let b0 = a0 + dir * len + axis * (-half * 0.25), b1 = a1 + dir * len + axis * (half * 0.25)
                    let q: [(float3, float2)] = [(a0, float2(-1, 0)), (a1, float2(1, 0)), (b1, float2(1, 1)), (a0, float2(-1, 0)), (b1, float2(1, 1)), (b0, float2(-1, 1))]
                    for (p, uv) in q { local.append(float4(p, 1)); local.append(float4(uv.x, uv.y, 1, 0)) }
                }
            }
        }
    }
}
