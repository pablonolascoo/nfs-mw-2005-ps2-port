// Dónde están los datos convertidos y cómo se leen los JSON pequeños (world.json, zones.json, cars.json).
//
// Orden de búsqueda de la carpeta de datos (una carpeta <ID> con world.json dentro):
//   1. `--data <ruta>` en la línea de órdenes
//   2. variable de entorno ROCKPORT_DATA
//   3. ~/Library/Application Support/Rockport/<ID>/   ← destino del futuro instalador (convierte tu ISO aquí)
//   4. desarrollo: map-data/<ID>/ subiendo desde la carpeta actual o desde el ejecutable
// <ID> es el código del disco (p. ej. SLES-53559); se elige con `--disc <ID>` o se toma el primero que haya.
import Foundation

enum DataLocator {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rockport", isDirectory: true)
    }

    static func isDataFolder(_ u: URL) -> Bool {
        let fm = FileManager.default
        // Una instalación a medias (hay install.log pero no install.ok) no cuenta: se vuelve a instalar.
        if fm.fileExists(atPath: u.appendingPathComponent("install.log").path) && !fm.fileExists(atPath: u.appendingPathComponent("install.ok").path) { return false }
        return fm.fileExists(atPath: u.appendingPathComponent("world.json").path)
    }

    /// Busca una carpeta <ID> válida dentro de `parent` (la del disco pedido o la primera que haya).
    static func pick(in parent: URL, disc: String?) -> URL? {
        if let d = disc { let u = parent.appendingPathComponent(d); return isDataFolder(u) ? u : nil }
        let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.first(where: isDataFolder)
    }

    static func locate(arg: String?, disc: String?) -> (URL?, [String]) {
        var tried: [String] = []
        if let a = arg {
            let u = URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL
            tried.append(u.path)
            if isDataFolder(u) { return (u, tried) }
            if let p = pick(in: u, disc: disc) { return (p, tried) }
        }
        if let e = ProcessInfo.processInfo.environment["ROCKPORT_DATA"] {
            let u = URL(fileURLWithPath: (e as NSString).expandingTildeInPath).standardizedFileURL
            tried.append(u.path)
            if isDataFolder(u) { return (u, tried) }
            if let p = pick(in: u, disc: disc) { return (p, tried) }
        }
        tried.append(appSupport.path)
        if let p = pick(in: appSupport, disc: disc) { return (p, tried) }
        // Desarrollo: subir desde la carpeta actual y desde el ejecutable buscando map-data/
        let starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                      URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()]
        for s in starts {
            var dir = s.standardizedFileURL
            for _ in 0..<8 {
                let md = dir.appendingPathComponent("map-data")
                if let p = pick(in: md, disc: disc) { return (p, tried + [md.path]) }
                dir.deleteLastPathComponent()
            }
        }
        return (nil, tried)
    }
}

struct WorldTile: Decodable {
    let id: String
    let x: Float, y: Float, size: Float
    let near: String, far: String
    let tris: Int, farTris: Int
    let zMin: Float, zMax: Float
}

struct WorldFile: Decodable {
    let disc: String
    let tiles: [WorldTile]
    let tileSize: Float?
}

struct Zone: Decodable {
    struct Respawn: Decodable { let position: [Float]; let rotation: Float? }
    let collection: String
    let zoneType: String
    let position: [Float]
    let respawn: Respawn?
}

struct ZonesFile: Decodable { let zones: [Zone] }

struct CarAttribs: Decodable {
    let tires: [[Float]]?
    let className: String?
}

struct CarsFile: Decodable { let cars: [String: CarAttribs] }

final class GameData {
    let root: URL
    let world: WorldFile
    let zones: [Zone]
    let cars: [String: CarAttribs]

    init(root: URL) throws {
        self.root = root
        let dec = JSONDecoder()
        world = try dec.decode(WorldFile.self, from: Data(contentsOf: root.appendingPathComponent("world.json")))
        zones = (try? dec.decode(ZonesFile.self, from: Data(contentsOf: root.appendingPathComponent("zones.json"))).zones) ?? []
        cars = (try? dec.decode(CarsFile.self, from: Data(contentsOf: root.appendingPathComponent("cars.json"))).cars) ?? [:]
    }

    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
}
