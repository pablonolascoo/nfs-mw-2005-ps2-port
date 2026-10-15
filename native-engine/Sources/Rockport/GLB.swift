// Lector GLB mínimo y rápido. Solo entiende lo que escribe tools/src/lib/glb.ts:
// mallas indexadas (POSITION, NORMAL?, TEXCOORD_0?, COLOR_0?, _ID?), materiales con baseColorFactor,
// baseColorTexture → images (uri externa o bufferView embebido) con su muestreador (TilableUV), alphaMode/alphaCutoff,
// extras del material (blend, role) y del nodo (pieza, marcadores: coches), nodos con matriz opcional y un nodo raíz con rotación -90° en X (glTF Y-arriba).
// Devolvemos todo en coordenadas del juego (Z arriba): se ignora la rotación del nodo raíz.
import Foundation
import simd

/// Vértice común a mundo y coches: 32 bytes. Debe coincidir con `VertexIn` en Shaders.swift.
struct Vertex {
    var px: Float, py: Float, pz: Float     // posición (m, Z arriba)
    var u: Float, v: Float                  // UV
    var r: UInt16, g: UInt16, b: UInt16, a: UInt16   // color de vértice en half (puede pasar de 1: luz horneada del PS2)
    var normal: UInt32                      // normal en snorm8 ×3 + relleno
}

enum MaterialKind: Int {
    case opaque = 0, mask, shadow, additive, water, blend
}

struct GLBMaterial {
    var name: String
    var kind: MaterialKind
    var cutoff: Float
    var color: float4
    var role: String?
    var image: Int?
    /// TilableUV del juego: bit 0 = repetir U, bit 1 = repetir V (si no, recorte al borde). 3 = repetir en ambos.
    var wrap: Int = 3
    /// Coches: material de luz del juego de la tira (eLightMaterial, `extras.luz`, doc 20): difusa, especular y reflejo.
    var light: String? = nil
}

struct GLBImage {
    var uri: URL?
    var data: Data?
    var name: String
}

/// Pieza de coche (`extras.pieza` del nodo, tools/src/lib/car-parts.ts carPartInfo): ranura, kit, estilo y si va de serie.
struct CarPiece {
    var slot: String
    var kit: Int?
    var style: Int?
    var stock: Bool
    /// pieza, kit, capo, calcomania, dano, llanta, aleron, techo, freno
    var kind: String
    /// "DAMAGE0" en paneles intactos de policía y tráfico; nombre de la variante en los packs de tuneo.
    var variant: String?
}

struct GLBPrimitive {
    var nodeName: String
    var material: Int
    var vertices: [Vertex]
    var indices: [UInt32]
    /// Solo coches: qué pieza es y sus marcadores (`extras.marcadores`: nombre → matriz del juego, traslación en la columna 3).
    var piece: CarPiece? = nil
    var markers: [String: float4x4] = [:]
}

struct GLBFile {
    var materials: [GLBMaterial]
    var images: [GLBImage]
    var primitives: [GLBPrimitive]
}

enum GLBError: Error, CustomStringConvertible {
    case notGLB(String), badJSON(String), unsupported(String)
    var description: String {
        switch self {
        case .notGLB(let s): return "no es GLB: \(s)"
        case .badJSON(let s): return "JSON de GLB inválido: \(s)"
        case .unsupported(let s): return "GLB no soportado: \(s)"
        }
    }
}

@inline(__always) func half(_ x: Float) -> UInt16 { Float16(x).bitPattern }
@inline(__always) func packNormal(_ n: float3) -> UInt32 {
    func s(_ v: Float) -> UInt32 { UInt32(UInt8(bitPattern: Int8(max(-127, min(127, (v * 127).rounded()))))) }
    return s(n.x) | (s(n.y) << 8) | (s(n.z) << 16)
}

enum GLB {
    static func load(_ url: URL) throws -> GLBFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data, baseURL: url.deletingLastPathComponent())
    }

    static func parse(_ data: Data, baseURL: URL) throws -> GLBFile {
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GLBFile in
            guard raw.count >= 20, raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x46546c67 else { throw GLBError.notGLB(baseURL.path) }
            let jsonLen = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            let jsonData = Data(bytes: raw.baseAddress! + 20, count: jsonLen)
            guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { throw GLBError.badJSON(baseURL.path) }
            let binStart = 20 + jsonLen + 8
            let bin = UnsafeRawBufferPointer(rebasing: raw[min(binStart, raw.count)...])

            let accessors = json["accessors"] as? [[String: Any]] ?? []
            let views = json["bufferViews"] as? [[String: Any]] ?? []

            // Acceso a un accessor como puntero (los datos no se copian hasta montar los vértices).
            func view(_ i: Int) -> (ptr: UnsafeRawPointer, count: Int, comps: Int, type: Int, stride: Int) {
                let a = accessors[i]
                let v = views[a["bufferView"] as! Int]
                let off = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
                let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as! String] ?? 1
                let type = a["componentType"] as! Int
                let size = type == 5126 || type == 5125 ? 4 : type == 5123 ? 2 : 1
                let stride = v["byteStride"] as? Int ?? comps * size
                return (bin.baseAddress! + off, a["count"] as! Int, comps, type, stride)
            }

            // Materiales
            var materials: [GLBMaterial] = []
            for m in json["materials"] as? [[String: Any]] ?? [] {
                let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
                let cf = (pbr["baseColorFactor"] as? [Double]) ?? [1, 1, 1, 1]
                let extras = m["extras"] as? [String: Any]
                let blend = extras?["blend"] as? String
                let alphaMode = m["alphaMode"] as? String ?? "OPAQUE"
                var kind: MaterialKind = .opaque
                switch (alphaMode, blend) {
                case (_, "sombra"?): kind = .shadow       // sombras horneadas (SHD_*) sobre el suelo
                case (_, "agua"?): kind = .water          // ANM_WATERA_*: agua animada
                case (_, "aditiva"?): kind = .additive
                case ("MASK", _): kind = .mask
                case ("BLEND", _): kind = .blend          // "mezcla"/"recorte_mezcla" (carteles, pintadas) y cristales de coche
                default: kind = .opaque
                }
                var tex: Int? = nil
                var wrap = 3
                if let bct = pbr["baseColorTexture"] as? [String: Any], let ti = bct["index"] as? Int,
                   let textures = json["textures"] as? [[String: Any]], ti < textures.count {
                    tex = textures[ti]["source"] as? Int
                    // Muestreador: 10497 = REPEAT, 33071 = CLAMP_TO_EDGE (por eje)
                    if let si = textures[ti]["sampler"] as? Int, let samplers = json["samplers"] as? [[String: Any]], si < samplers.count {
                        let s = samplers[si]
                        wrap = ((s["wrapS"] as? Int ?? 10497) == 33071 ? 0 : 1) | ((s["wrapT"] as? Int ?? 10497) == 33071 ? 0 : 2)
                    }
                }
                materials.append(GLBMaterial(name: m["name"] as? String ?? "", kind: kind,
                                             cutoff: Float(m["alphaCutoff"] as? Double ?? 0.5),
                                             color: float4(Float(cf[0]), Float(cf[1]), Float(cf[2]), Float(cf.count > 3 ? cf[3] : 1)),
                                             role: extras?["role"] as? String, image: tex, wrap: wrap, light: extras?["luz"] as? String))
            }

            // Imágenes: URI relativa al GLB (casillas) o PNG embebido (coches)
            var images: [GLBImage] = []
            for im in json["images"] as? [[String: Any]] ?? [] {
                let name = im["name"] as? String ?? ""
                if let uri = im["uri"] as? String {
                    images.append(GLBImage(uri: URL(fileURLWithPath: uri, relativeTo: baseURL).standardizedFileURL, data: nil, name: name))
                } else if let bv = im["bufferView"] as? Int {
                    let v = views[bv]
                    let off = v["byteOffset"] as? Int ?? 0, len = v["byteLength"] as? Int ?? 0
                    images.append(GLBImage(uri: nil, data: Data(bytes: bin.baseAddress! + off, count: len), name: name))
                } else {
                    images.append(GLBImage(uri: nil, data: nil, name: name))
                }
            }

            // Nodos: recorrido desde la escena; la rotación del nodo raíz (Z→Y de glTF) se ignora a propósito.
            let nodes = json["nodes"] as? [[String: Any]] ?? []
            let meshes = json["meshes"] as? [[String: Any]] ?? []
            let sceneRoots: [Int] = {
                if let scenes = json["scenes"] as? [[String: Any]], let s = scenes.first, let n = s["nodes"] as? [Int] { return n }
                return [0]
            }()
            var prims: [GLBPrimitive] = []

            func localMatrix(_ n: [String: Any]) -> float4x4 {
                if let m = n["matrix"] as? [Double], m.count == 16 {
                    let f = m.map { Float($0) }
                    return float4x4(columns: (float4(f[0], f[1], f[2], f[3]), float4(f[4], f[5], f[6], f[7]),
                                              float4(f[8], f[9], f[10], f[11]), float4(f[12], f[13], f[14], f[15])))
                }
                var t = float4x4.identity
                if let tr = n["translation"] as? [Double] { t = float4x4(translation: float3(Float(tr[0]), Float(tr[1]), Float(tr[2]))) }
                var r = float4x4.identity
                if let q = n["rotation"] as? [Double] { r = float4x4(simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3]))) }
                var s = float4x4.identity
                if let sc = n["scale"] as? [Double] { s = float4x4(scale: float3(Float(sc[0]), Float(sc[1]), Float(sc[2]))) }
                return t * r * s
            }

            func visit(_ ni: Int, _ parent: float4x4, isRoot: Bool) throws {
                let n = nodes[ni]
                let world = isRoot ? parent : parent * localMatrix(n)
                let name = n["name"] as? String ?? ""
                let extras = n["extras"] as? [String: Any]
                var piece: CarPiece? = nil
                if let p = extras?["pieza"] as? [String: Any], let slot = p["slot"] as? String {
                    piece = CarPiece(slot: slot, kit: p["kit"] as? Int, style: p["style"] as? Int, stock: p["stock"] as? Bool ?? false,
                                     kind: p["kind"] as? String ?? "pieza", variant: p["variant"] as? String)
                }
                var markers: [String: float4x4] = [:]
                for m in extras?["marcadores"] as? [[String: Any]] ?? [] {
                    guard let nombre = m["nombre"] as? String, let a = m["matriz"] as? [Double], a.count == 16 else { continue }
                    let f = a.map { Float($0) }
                    markers[nombre] = float4x4(columns: (float4(f[0], f[1], f[2], f[3]), float4(f[4], f[5], f[6], f[7]),
                                                         float4(f[8], f[9], f[10], f[11]), float4(f[12], f[13], f[14], f[15])))
                }
                if let mi = n["mesh"] as? Int {
                    let normalM = simd_float3x3(float3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                                float3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                                float3(world.columns.2.x, world.columns.2.y, world.columns.2.z)).inverse.transpose
                    let identity = world == .identity
                    for p in meshes[mi]["primitives"] as? [[String: Any]] ?? [] {
                        let attrs = p["attributes"] as? [String: Int] ?? [:]
                        guard let posI = attrs["POSITION"], let idxI = p["indices"] as? Int else { continue }
                        let pos = view(posI)
                        let count = pos.count
                        if count == 0 { continue }
                        guard pos.type == 5126 else { throw GLBError.unsupported("POSITION no float") }
                        let nrm = attrs["NORMAL"].map(view)
                        let uv = attrs["TEXCOORD_0"].map(view)
                        let col = attrs["COLOR_0"].map(view)
                        var verts = [Vertex](repeating: Vertex(px: 0, py: 0, pz: 0, u: 0, v: 0, r: half(1), g: half(1), b: half(1), a: half(1), normal: packNormal(float3(0, 0, 1))), count: count)
                        verts.withUnsafeMutableBufferPointer { vb in
                            for i in 0..<count {
                                let pp = (pos.ptr + i * pos.stride).assumingMemoryBound(to: Float.self)
                                var P = float3(pp[0], pp[1], pp[2])
                                if !identity { let w = world * float4(P, 1); P = float3(w.x, w.y, w.z) }
                                vb[i].px = P.x; vb[i].py = P.y; vb[i].pz = P.z
                                if let uv = uv, uv.type == 5126 {
                                    let up = (uv.ptr + i * uv.stride).assumingMemoryBound(to: Float.self)
                                    vb[i].u = up[0]; vb[i].v = up[1]
                                }
                                if let c = col, c.type == 5126 {
                                    let cp = (c.ptr + i * c.stride).assumingMemoryBound(to: Float.self)
                                    vb[i].r = half(cp[0]); vb[i].g = half(cp[1]); vb[i].b = half(cp[2])
                                    vb[i].a = half(c.comps == 4 ? cp[3] : 1)
                                }
                                if let nr = nrm, nr.type == 5126 {
                                    let np = (nr.ptr + i * nr.stride).assumingMemoryBound(to: Float.self)
                                    var N = float3(np[0], np[1], np[2])
                                    if !identity { N = normalM * N }
                                    let l = simd_length(N)
                                    vb[i].normal = packNormal(l > 0 ? N / l : float3(0, 0, 1))
                                }
                            }
                        }
                        let ix = view(idxI)
                        var indices = [UInt32](repeating: 0, count: ix.count)
                        indices.withUnsafeMutableBufferPointer { ib in
                            switch ix.type {
                            case 5125: for i in 0..<ix.count { ib[i] = (ix.ptr + i * ix.stride).loadUnaligned(as: UInt32.self) }
                            case 5123: for i in 0..<ix.count { ib[i] = UInt32((ix.ptr + i * ix.stride).loadUnaligned(as: UInt16.self)) }
                            default: for i in 0..<ix.count { ib[i] = UInt32((ix.ptr + i * ix.stride).load(as: UInt8.self)) }
                            }
                        }
                        prims.append(GLBPrimitive(nodeName: name, material: p["material"] as? Int ?? 0, vertices: verts, indices: indices,
                                                  piece: piece, markers: markers))
                    }
                }
                for c in n["children"] as? [Int] ?? [] { try visit(c, world, isRoot: false) }
            }
            for r in sceneRoots where r < nodes.count { try visit(r, .identity, isRoot: true) }
            return GLBFile(materials: materials, images: images, primitives: prims)
        }
    }
}
