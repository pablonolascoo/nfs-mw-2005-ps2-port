// Malla en GPU: un búfer de vértices y uno de índices por archivo GLB, y una lista de "tramos" de dibujo
// (uno por material). Fusionar todo en dos búferes deja ~40–60 llamadas por casilla cercana, barato en Metal.
import Foundation
import Metal
import simd

struct DrawRange {
    var kind: MaterialKind
    var indexStart: Int
    var indexCount: Int
    var texture: MTLTexture?
    var color: float4
    var cutoff: Float
    var role: String?
    var name: String
    var wrap: Int = 3          // bit 0 repite U, bit 1 repite V
    var part: Int = 0          // pieza (coches: 0 = carrocería, 1…4 = ruedas)
    var visible = true
    var pbr: float2? = nil     // coches: metalicidad y rugosidad propias (acabado de la pintura del preset, CarSkin.swift)
    var light: String? = nil   // coches: material de luz del juego (extras.luz; la pintura toma el del preset). Doc 20.
}

final class GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    var draws: [DrawRange]
    let bounds: AABB
    let triangles: Int
    let bytes: Int

    init(vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, draws: [DrawRange], bounds: AABB, triangles: Int) {
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.draws = draws
        self.bounds = bounds
        self.triangles = triangles
        self.bytes = vertexBuffer.length + indexBuffer.length
    }

    /// Construye la malla agrupando primitivas por material (y por pieza, si se da `partOf`).
    /// `transform` permite reubicar primitivas (ruedas). Se llama desde hilos de carga.
    static func build(device: MTLDevice, file: GLBFile, textures: TextureCache, keyPrefix: String,
                      prims: [GLBPrimitive]? = nil, partOf: ((GLBPrimitive) -> Int)? = nil) -> GPUMesh? {
        let prims = prims ?? file.primitives
        // Agrupación: (pieza, material) → primitivas
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for (i, p) in prims.enumerated() {
            let key = (partOf?(p) ?? 0) * 100_000 + p.material
            if groups[key] == nil { groups[key] = []; order.append(key) }
            groups[key]!.append(i)
        }
        // Orden: opacos primero, luego por textura (menos cambios de estado)
        order.sort { a, b in
            let ka = file.materials[a % 100_000].kind.rawValue, kb = file.materials[b % 100_000].kind.rawValue
            return ka != kb ? ka < kb : a < b
        }
        var vcount = 0, icount = 0
        for p in prims { vcount += p.vertices.count; icount += p.indices.count }
        if icount == 0 { return nil }
        guard let vb = device.makeBuffer(length: max(vcount, 1) * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let ib = device.makeBuffer(length: icount * 4, options: .storageModeShared) else { return nil }
        let vptr = vb.contents().bindMemory(to: Vertex.self, capacity: vcount)
        let iptr = ib.contents().bindMemory(to: UInt32.self, capacity: icount)
        var vo = 0, io = 0
        var bounds = AABB.empty
        var draws: [DrawRange] = []
        var texOf: [Int: MTLTexture?] = [:]
        // Imágenes con alfa útil: las que usa algún material no opaco (relleno de bordes y mipmaps ponderados por alfa).
        var alphaImage = Set<Int>()
        for m in file.materials where m.kind != .opaque { if let im = m.image { alphaImage.insert(im) } }
        for key in order {
            let mi = key % 100_000, part = key / 100_000
            let m = file.materials[mi]
            let start = io
            for pi in groups[key]! {
                let p = prims[pi]
                p.vertices.withUnsafeBufferPointer { src in
                    (vptr + vo).update(from: src.baseAddress!, count: src.count)
                    for v in src { bounds.add(float3(v.px, v.py, v.pz)) }
                }
                for (k, idx) in p.indices.enumerated() { iptr[io + k] = idx + UInt32(vo) }
                vo += p.vertices.count
                io += p.indices.count
            }
            var tex: MTLTexture? = nil
            if let im = m.image, im < file.images.count {
                if let cached = texOf[im] { tex = cached } else {
                    let img = file.images[im]
                    let a = alphaImage.contains(im)
                    if let u = img.uri { tex = textures.texture(url: u, alpha: a) }
                    else if let d = img.data { tex = textures.texture(key: "\(keyPrefix)#\(im)", alpha: a) { d } }
                    texOf[im] = tex
                }
            }
            draws.append(DrawRange(kind: m.kind, indexStart: start, indexCount: io - start, texture: tex, color: m.color,
                                   cutoff: m.cutoff, role: m.role, name: m.name, wrap: m.wrap, part: part, light: m.light))
        }
        return GPUMesh(vertexBuffer: vb, indexBuffer: ib, draws: draws, bounds: bounds, triangles: icount / 3)
    }
}
