// Depuración de la interfaz: lista lo que se dibuja de un paquete (ROCKPORT_FE_DUMP=1 en las pruebas sin ventana).
// Cada línea: tipo, hash del nombre, textura o texto, rectángulo en el lienzo 640×480 (origen arriba a la izquierda),
// alfa y cadena de grupos padre. Sirve para identificar objetos en las capturas.
import Foundation
import simd

extension FEAssets {
    func textureName(_ hash: UInt32) -> String? { index.textures[String(format: "%08x", hash)]?.name }
}

extension FERenderer {
    func dump(_ pkg: FEPackageRT, to path: String? = nil) {
        var out = "== \(pkg.name)\n"
        for it in collect(pkg) {
            let o = it.obj
            var xs: [Float] = [], ys: [Float] = []
            for c in [SIMD2<Float>(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5)] {
                let p = it.m * SIMD4(c.x, c.y, 0, 1); xs.append(p.x + 320); ys.append(p.y + 240)
            }
            var chain: [String] = []
            var p = o.parent
            while let g = p { chain.append(String(format: "%08x", g.nameHash)); p = g.parent }
            let what = o.type == 2 ? "\"\(FERenderer.text(of: o, assets: pkg.assets))\"" : (pkg.assets.textureName(o.handle) ?? String(format: "tex %08x", o.handle))
            out += String(format: "t%-2d %08x %-28@ [%4.0f,%4.0f → %4.0f,%4.0f] a%3.0f z%.0f scr %08x  < %@\n", o.type, o.nameHash, what as NSString,
                          xs.min()!, ys.min()!, xs.max()!, ys.max()!, it.color.w, it.z, o.script?.id ?? 0, chain.joined(separator: " < "))
        }
        if let path { try? out.write(toFile: path, atomically: true, encoding: .utf8) } else { print(out) }
    }
}
