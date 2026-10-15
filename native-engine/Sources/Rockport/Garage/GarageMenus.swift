// Menús de los garajes del mundo con los paquetes originales (el juego los abre tras EQuitToFE en el frontend [D]):
//  - Refugio: MainMenu_Sub con las opciones de uiCareerCrib [D: uiCareerMain.cpp]: Volver a la zona libre, Lista Negra
//    (CTop15), Mis coches (CCarSelect → selección de coche), Guardar (CSave). Título 0xE596C4A3, datos CAREER/BOUNTY/CASH_DATA.
//  - Concesionario: Car_Select.fng como UIQRCarSelect en modo concesionario [D: uiQRCarSelect.cpp]: logotipo de la marca,
//    contador n/N, precio (0x20C83C31) y dinero (0x1930B057); coches y precios de FE_ATTRIB.BIN (Cost, UnlockedAt) [V].
//  - Taller: CustomizeMain → CustomizeCategory → CustomizeParts [D: CarCustomize.cpp]: Piezas (kits, alerones, llantas) y
//    Visual (pintura, vinilos, color de llanta, barra de luz). El tuneo se aplica al coche al momento (CarTuning.swift).
// La cámara de cada pantalla es su cam_angle de FE_ATTRIB.BIN (career_mainmenu_sub, carlot_car_select,
// customize_customizemain…) alrededor del coche aparcado.
import Foundation
import simd

extension FEUI {
    /// Coche aparcado en un garaje del mundo: menús del sitio.
    func openGarage(_ g: WorldGarages.Placed) {
        engine.garages?.world?.menuOpened()
        switch g.kind {
        case .safehouse, .mainFE: showSafehouseMenu()
        case .carLot: showCarLot(owned: false)
        case .customShop, .backroom: showCustomizeMain()
        }
    }

    private var garageWorld: WorldGarages? { engine.garages?.world }

    private func garageScreen(_ name: String) { garageWorld?.screenAngle(name) }

    /// Salir del garaje: se cierran los menús y la persiana sube.
    func leaveGarage() {
        leaveTopScreen { [weak self] in
            guard let self else { return }
            self.screens.removeAll()
            self.state = .game
            self.garageWorld?.exitGarage()
        }
    }

    private func garageMenu(_ name: String, title: UInt32?, options: [(UInt32, UInt32, () -> Void)], select: Int = 0, back: @escaping () -> Void) -> FEScreen? {
        screens.removeAll()
        state = .garage
        guard let s = iconMenu(name, title: title, options: options, select: select) else { return nil }
        s.onBack = { [weak s] in s?.leave(then: back) }
        return s
    }

    // MARK: Refugio (uiCareerCrib)

    func showSafehouseMenu(select: Int = 0) {
        let career = Career.shared
        guard let s = garageMenu("MainMenu_Sub", title: nil, options: [
            (0x12BB5EA2, 0x01BD185C, { [weak self] in self?.leaveGarage() }),
            (0x2C14AC23, 0x80B9FF9B, { [weak self] in self?.leaveTopScreen { self?.showSafehouseBlacklist() } }),
            (0xC6A1A6E0, 0x00D5F627, { [weak self] in self?.leaveTopScreen { self?.showCarLot(owned: true) } }),
            (0x228B7E32, 0x001C8ACE, { [weak self] in self?.saveCareer() }),
        ], select: select, back: { [weak self] in self?.leaveGarage() }) else { return }
        let p = s.pkg
        for h: UInt32 in [0x3C458C1, 0xB5C74226] { if let t = p.find(h) { setLabelDeep(p, t, 0xE596C4A3) } }
        p.setScript(p.find("PLAYER_MASTER"), feHash("SHOW"))
        let sv = career.save
        printDeepText(p, p.find("CAREER_DATA"), "\(max(0, 15 - sv.currentBin) * 100 / 15)%")
        printDeepText(p, p.find("BOUNTY_DATA"), FEHud.money(sv.bounty))
        printDeepText(p, p.find("CASH_DATA"), "$" + FEHud.money(sv.cash))
        garageScreen("career_mainmenu_sub")
    }

    private func printDeepText(_ p: FEPackageRT, _ o: FEObj?, _ text: String) {
        guard let o else { return }
        if o.type == 2 { p.printf(o, text) }
        for c in o.children { printDeepText(p, c, text) }
    }

    private func showSafehouseBlacklist() {
        screens.removeAll()
        garageScreen("career_safehousereputationoverview")
        let rivals = Career.shared.rivals()
        blacklistCash = Career.shared.save.cash
        showBlacklist(rivals, selected: Career.shared.save.currentBin) { [weak self] _ in
            self?.showSafehouseMenu(select: 1)
        }
        state = .modal
    }

    private func saveCareer() {
        Career.shared.modifySave { _ in }
        messageDialog(title: 0x001C8ACE, text: es ? "Partida guardada." : "Career saved.")
    }

    // MARK: Concesionario y «Mis coches» (UIQRCarSelect)

    /// Coche del concesionario: colección de FE_ATTRIB.BIN → modelo (cars/<MODELO>.glb) [I: tabla de nombres].
    struct LotCar { let model: String; let cost: Int; let unlockedAt: Int; let manufacturer: Int }
    static func lotCars(_ data: GameData) -> [LotCar] {
        struct F: Decodable { struct C: Decodable { let cost: Int; let unlockedAt: Int; let manufacturer: Int }; let cars: [String: C]? }
        guard let f = try? JSONDecoder().decode(F.self, from: Data(contentsOf: data.url("fe-cameras.json"))), let cars = f.cars else { return [] }
        let alias = ["a3_20t": "A3", "a4_32": "A4", "corvette_car": "CORVETTE", "imprezzawrx": "IMPREZAWRX", "carrera_gt": "CARRERAGT",
                     "m3_gtre46": "BMWM3GTRE46", "caymans": "CAYMANS", "997s": "997S"]
        var out: [LotCar] = []
        for (k, c) in cars {
            let model = alias[k] ?? k.uppercased()
            guard FileManager.default.fileExists(atPath: data.url("cars/\(model).glb").path), c.cost > 100 else { continue }
            out.append(LotCar(model: model, cost: c.cost, unlockedAt: c.unlockedAt, manufacturer: c.manufacturer))
        }
        return out.sorted { $0.cost < $1.cost }
    }

    func showCarLot(owned: Bool) {
        screens.removeAll()
        state = .garage
        guard let s = push("Car_Select") else { showSafehouseMenu(); return }
        let p = s.pkg
        let career = Career.shared
        let lot = FEUI.lotCars(engine.data)
        // Lista: coches del jugador o los del concesionario
        let entries: [(key: String, model: String, cost: Int, locked: Int?)] = owned
            ? career.save.cars.map { k in (k, CarPresets.named(k, in: engine.data)?.car ?? k, 0, nil) }
            : lot.map { c in (c.model, c.model, c.cost, career.save.currentBin > c.unlockedAt ? c.unlockedAt : nil) }
        guard !entries.isEmpty else { showSafehouseMenu(); return }
        var idx = owned ? max(0, career.save.cars.firstIndex(of: career.save.currentCar) ?? 0) : 0
        // Fuera lo que no es de este modo (pantalla partida, online, impound) [D: constructor]
        for h: UInt32 in [0xe3fe27fe, 0xe998fe99, 0x39dc21f9, 0xbc7b91f, 0x0e9ed0a2, 0x5ba2f765] { p.setVisible(p.find(h), false) }
        if owned { for h: UInt32 in [0x19398802, 0x1930b057, 0x20d113dc, 0x20c83c31] { p.setVisible(p.find(h), false) } }
        else { p.setLabel(p.find(0xdc18c4d4), 0xa9950b93); p.setLabel(p.find(0xb94139f4), 0x7010bbf2) }
        func show() {
            let e = entries[idx]
            printDeepText(p, p.find(0x6f25a248), "\(idx + 1)")
            printDeepText(p, p.find(0xb2037bdc), "\(entries.count)")
            let brand = FEUI.brand(e.model)
            if let logo = p.find(0x3e01ad1d) {
                let h = feHash("CARSELECT_MANUFACTURER_" + brand)
                if assets.hasTexture(h) { logo.handle = h; p.setVisible(logo, true) } else { p.setVisible(logo, false) }
            }
            p.setVisible(p.find(0xb05dd708), false)
            for h: UInt32 in [0xd6d32016, 0x79d6e45c] {
                p.setVisible(p.find(h), true)
                p.printf(p.find(h), FEUI.carName(e.model, data: engine.data))
            }
            if !owned {
                printDeepText(p, p.find(0x1930b057), "$" + FEHud.money(career.save.cash))
                printDeepText(p, p.find(0x20c83c31), "$" + FEHud.money(e.cost))
                if let lock = e.locked {
                    p.setScript(p.find(0xd0f7c7cc), FEH.show)
                    let fmt = assets.string(0x4ef2a115) ?? "%s (#%d)"
                    let rival = assets.string(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", lock + 1))) ?? ""
                    printDeepText(p, p.find(0x2d25b2c4), fmt.replacingOccurrences(of: "%s", with: rival).replacingOccurrences(of: "%d", with: "\(lock + 1)"))
                } else { p.setScript(p.find(0xd0f7c7cc), FEH.hide) }
            }
            engine.garages?.world?.preview(key: e.key)
        }
        show()
        s.onLeftRight = { d in idx = (idx + d + entries.count) % entries.count; show() }
        s.onBack = { [weak self, weak s] in
            self?.engine.garages?.world?.preview(key: nil)
            s?.leave { owned ? self?.showSafehouseMenu(select: 2) : self?.leaveGarage() }
        }
        s.actions = [{ [weak self] in
            guard let self else { return }
            let e = entries[idx]
            if owned {
                career.modifySave { $0.currentCar = e.key }
                self.engine.garages?.world?.preview(key: nil)
                CarTuning.replacePlayerCar(self.engine, key: e.key)
                s.leave { self.showSafehouseMenu(select: 2) }
                return
            }
            if e.locked != nil { self.messageDialog(title: 0x7010bbf2, text: p.find(0x2d25b2c4).flatMap { $0.text } ?? ""); return }
            if career.save.cars.contains(e.key) { self.messageDialog(title: 0x7010bbf2, text: self.es ? "Ya tienes este coche." : "You already own this car."); return }
            if e.cost > career.save.cash { self.messageDialog(title: 0x7010bbf2, text: self.assets.string(0x40fa955d) ?? "") ; return }
            career.modifySave { $0.cash -= e.cost; $0.cars.append(e.key); $0.currentCar = e.key }
            self.engine.garages?.world?.preview(key: nil)
            CarTuning.replacePlayerCar(self.engine, key: e.key)
            self.messageDialog(title: 0x7010bbf2, text: (self.es ? "Comprado: " : "Bought: ") + FEUI.carName(e.model, data: self.engine.data)) { [weak self] in
                self?.leaveGarage()
            }
        }]
        garageScreen(owned ? "career_car_select" : "carlot_car_select")
    }

    static func brand(_ model: String) -> String {
        let m = model.uppercased()
        let table: [(String, String)] = [("BMW", "BMW"), ("911", "Porsche"), ("997", "Porsche"), ("CAYMAN", "Porsche"), ("CARRERAGT", "Porsche"),
            ("A3", "Audi"), ("A4", "Audi"), ("TT", "Audi"), ("CAMARO", "Chevrolet"), ("COBALT", "Chevrolet"), ("CORVETTE", "Chevrolet"),
            ("CTS", "Cadillac"), ("CLIO", "Renault"), ("CLK", "Mercedes"), ("SL", "Mercedes"), ("DB9", "AstonMartin"), ("ECLIPSE", "Mitsubishi"),
            ("LANCER", "Mitsubishi"), ("ELISE", "Lotus"), ("FORDGT", "Ford"), ("MUSTANG", "Ford"), ("GALLARDO", "Lamborghini"),
            ("MURCIELAGO", "Lamborghini"), ("GTI", "Volkswagen"), ("GTO", "Pontiac"), ("IMPREZA", "Subaru"), ("IS300", "Lexus"),
            ("MONARO", "Vauxhall"), ("PUNTO", "Fiat"), ("RX7", "Mazda"), ("RX8", "Mazda"), ("SUPRA", "Toyota"), ("VIPER", "Dodge")]
        return table.first { m.hasPrefix($0.0) }?.1 ?? ""
    }
    /// Nombre del coche: el del juego (CARSELECT_*/texto) si existe, si no el modelo [I].
    static func carName(_ model: String, data: GameData) -> String {
        if let p = CarPresets.named(model, in: data), p.car != model { return p.car }
        let pretty = ["BMWM3GTRE46": "BMW M3 GTR", "911TURBO": "Porsche 911 Turbo S", "997S": "Porsche 911 Carrera S", "CAYMANS": "Porsche Cayman S",
                      "CARRERAGT": "Porsche Carrera GT", "LANCEREVO8": "Mitsubishi Lancer Evolution VIII", "IMPREZAWRX": "Subaru Impreza WRX STi",
                      "MUSTANGGT": "Ford Mustang GT", "FORDGT": "Ford GT", "GALLARDO": "Lamborghini Gallardo", "MURCIELAGO": "Lamborghini Murciélago",
                      "SLR": "Mercedes-Benz SLR McLaren", "SL500": "Mercedes-Benz SL 500", "CLK500": "Mercedes-Benz CLK 500", "DB9": "Aston Martin DB9",
                      "CORVETTE": "Chevrolet Corvette C6", "VIPER": "Dodge Viper SRT-10", "SUPRA": "Toyota Supra", "RX7": "Mazda RX-7", "RX8": "Mazda RX-8",
                      "ECLIPSEGT": "Mitsubishi Eclipse", "GTI": "Volkswagen Golf GTI", "GTO": "Pontiac GTO", "IS300": "Lexus IS 300", "CTS": "Cadillac CTS",
                      "CLIO": "Renault Clio V6", "PUNTO": "Fiat Punto", "COBALTSS": "Chevrolet Cobalt SS", "CAMARO": "Chevrolet Camaro SS",
                      "A3": "Audi A3 3.2 quattro", "A4": "Audi A4 3.2 FSI quattro", "TT": "Audi TT 3.2 quattro", "ELISE": "Lotus Elise",
                      "MONARO": "Vauxhall Monaro VXR"]
        return pretty[model.uppercased()] ?? model
    }

    // MARK: Taller (CustomizeMain → CustomizeCategory → CustomizeParts)

    func showCustomizeMain(select: Int = 0) {
        let back = { [weak self] in self?.leaveGarage() ?? () }
        guard let s = garageMenu("CustomizeMain", title: nil, options: [
            (0x6e0ca66c, 0x055dce1a, { [weak self] in self?.leaveTopScreen { self?.showCustomizeCategory(parts: true) } }),
            (0x3987d054, 0xbaef8282, { [weak self] in self?.messageDialog(title: 0xbaef8282, text: self?.es == true ? "Próximamente." : "Coming soon.") }),
            (0x3e31ba56, 0xbfa7d7c4, { [weak self] in self?.leaveTopScreen { self?.showCustomizeCategory(parts: false) } }),
        ], select: select, back: back) else { return }
        if let tg = s.pkg.find("TITLE_GROUP") { setLabelDeep(s.pkg, tg, 0x1d0f2bd7) }
        s.scroller?.setGrey(1)
        hideCustomizeExtras(s.pkg)
        garageScreen("customize_customizemain")
    }

    /// Lo que el juego solo enseña con su carrito de la compra y el medidor de calor de las piezas [I: sin carrito aquí].
    private func hideCustomizeExtras(_ p: FEPackageRT) {
        for h: UInt32 in [0xb6b79052, 0xe08434fc, 0x5d58bcc6] { p.setVisible(p.find(h), false) }
    }

    func showCustomizeCategory(parts: Bool) {
        let key = garageCarKey
        let carModel = CarTuning.preset(key, data: engine.data, tune: nil)?.car ?? key
        let hasPreset = CarPresets.named(key, in: engine.data) != nil
        var opts: [(UInt32, UInt32, () -> Void)] = []
        if parts {
            opts.append((0x028c24f6, 0x6134c218, { [weak self] in self?.showTuneList(.kit) }))
            if hasPreset {
                opts.append((0xbb034ea6, 0x94e73021, { [weak self] in self?.showTuneList(.spoiler) }))
                opts.append((0x0294d2a3, 0xf868eb0b, { [weak self] in self?.showTuneList(.rims) }))
            }
        } else {
            opts.append((0xa3b76154, 0x055da70c, { [weak self] in self?.showTuneList(.paint) }))
            if hasPreset, !CarTuning.vinylDonors(engine.data, car: carModel).isEmpty {
                opts.append((0x55778e5a, 0xbfa52c55, { [weak self] in self?.showTuneList(.vinyl) }))
            }
            opts.append((0x028f88bc, 0x78980a6b, { [weak self] in self?.showTuneList(.lightBar) }))
        }
        guard let s = garageMenu("CustomizeCategory", title: nil, options: opts.map { o in (o.0, o.1, { [weak self] in self?.leaveTopScreen(o.2) }) },
                                 back: { [weak self] in self?.showCustomizeMain(select: parts ? 0 : 2) }) else { return }
        if let tg = s.pkg.find("TITLE_GROUP") { setLabelDeep(s.pkg, tg, parts ? 0x055dce1a : 0xbfa7d7c4) }
        hideCustomizeExtras(s.pkg)
        // Barra de luz: extensión propia (no está en el juego); su nombre va en texto libre
        if !parts {
            s.customHeader = { [weak self, weak s] i in
                guard let self, let s, let sc = s.scroller else { return }
                let isLight = i == sc.options.count - 5
                for t in s.titleObjects {
                    if isLight { s.pkg.printf(t, self.es ? "Barra de luz del mando" : "Controller light bar") } else { s.pkg.setLabel(t, sc.currentOption.name) }
                }
            }
            s.refreshHeader()
        }
        garageScreen(parts ? "customize_customizecategory" : "customize_customizecategory_2051")
    }

    enum TuneKind { case paint, vinyl, rims, spoiler, kit, lightBar }

    private var garageCarKey: String { Career.shared.active ? Career.shared.save.currentCar : (Config.playerPreset ?? Config.playerCar) }

    /// Lista de piezas (CustomizeParts.fng): ← → cambia y se ve en el coche al momento; ✕ instala; △ deja lo que había.
    func showTuneList(_ kind: TuneKind) {
        let key = garageCarKey
        let data = engine.data
        let original = CarTuning.tune(key) ?? CarTune()
        let model = CarTuning.preset(key, data: data, tune: nil)?.car ?? key
        // (nombre visible, tuneo que aplica)
        var items: [(String, CarTune)] = []
        var lightItems: [(String, () -> Void)] = []
        var icon: UInt32 = 0x028c24f6
        var titleHash: UInt32 = 0x6134c218
        switch kind {
        case .paint:
            icon = 0xa3b76154; titleHash = 0x055da70c
            for c in CarTuning.paints(data) {
                var t = original; t.paint = c.name
                let finish = ["GLOSS": es ? "Brillo" : "Gloss", "METAL": es ? "Metalizado" : "Metallic", "PEARL": es ? "Perlado" : "Pearl"][c.finish] ?? c.finish.capitalized
                items.append(("\(finish) #\(c.rgb.uppercased())", t))
            }
        case .vinyl:
            icon = 0x55778e5a; titleHash = 0xbfa52c55
            var none = original; none.vinyl = ""
            items.append((es ? "Sin vinilo" : "No vinyl", none))
            for d in CarTuning.vinylDonors(data, car: model) { var t = original; t.vinyl = d.name; items.append((d.vinyl?.name ?? d.name, t)) }
        case .rims:
            icon = 0x0294d2a3; titleHash = 0xf868eb0b
            var stock = original; stock.rims = ""
            items.append((es ? "De serie" : "Stock", stock))
            for d in CarTuning.rimDonors(data) { var t = original; t.rims = d.name; items.append((d.rim?.name ?? d.name, t)) }
        case .spoiler:
            icon = 0xbb034ea6; titleHash = 0x94e73021
            var none = original; none.spoiler = ""
            items.append((es ? "Sin alerón" : "No spoiler", none))
            for (i, d) in CarTuning.spoilerDonors(data).enumerated() { var t = original; t.spoiler = d.name; items.append(((es ? "Alerón " : "Spoiler ") + "\(i + 1)", t)) }
        case .kit:
            icon = 0x028c24f6; titleHash = 0x6134c218
            for k in CarTuning.kits(data, car: model) { var t = original; t.kit = k; items.append((k == 0 ? (es ? "De serie" : "Stock") : "Kit \(k)", t)) }
        case .lightBar:
            icon = 0x028f88bc; titleHash = 0x78980a6b
            for (m, esName, enName) in LightBar.modes where m != .custom { lightItems.append((es ? esName : enName, { LightBar.shared.setMode(m) })) }
            for (n, c) in [("Naranja", SIMD3<Float>(1, 0.4, 0)), ("Rojo", SIMD3(1, 0, 0)), ("Azul", SIMD3(0, 0.3, 1)), ("Verde", SIMD3(0, 1, 0.2)),
                           ("Morado", SIMD3(0.6, 0, 1)), ("Blanco", SIMD3(1, 1, 1))] {
                let en = ["Naranja": "Orange", "Rojo": "Red", "Azul": "Blue", "Verde": "Green", "Morado": "Purple", "Blanco": "White"][n] ?? n
                lightItems.append(((es ? "Color propio: " + n : "Custom: " + en), { LightBar.shared.setMode(.custom); LightBar.shared.setCustomColor(c) }))
            }
        }
        let count = kind == .lightBar ? lightItems.count : items.count
        guard count > 0 else { showCustomizeCategory(parts: kind == .kit || kind == .rims || kind == .spoiler); return }
        let current = kind == .lightBar ? 0 : max(0, items.firstIndex { $0.1 == original } ?? 0)
        let isParts = kind == .kit || kind == .rims || kind == .spoiler
        let opts: [(UInt32, UInt32, () -> Void)] = (0..<min(count, 40)).map { _ in (icon, titleHash, {}) }
        guard let s = garageMenu("CustomizeParts", title: nil, options: opts, select: current,
                                 back: { [weak self] in
                                     guard let self else { return }
                                     // △: se queda lo que había (se vuelve a montar el coche sin la vista previa)
                                     if kind != .lightBar { CarTuning.replacePlayerCar(self.engine, key: key) }
                                     self.showCustomizeCategory(parts: isParts)
                                 }) else { return }
        let p = s.pkg
        if let tg = p.find("TITLE_GROUP") { setLabelDeep(p, tg, titleHash) }
        hideCustomizeExtras(p)
        printDeepText(p, p.find(0x783eea2b), "")
        printDeepText(p, p.find(0xc60adcfd), "$" + FEHud.money(Career.shared.save.cash))
        printDeepText(p, p.find(0xdbb80edd), "$0")
        printDeepText(p, p.find(0x7a6d2f71), "$" + FEHud.money(Career.shared.save.cash))
        var lastApplied = -1
        s.customHeader = { [weak self, weak s] i in
            guard let self, let s else { return }
            let name = kind == .lightBar ? lightItems[i].0 : items[i].0
            for t in s.titleObjects { s.pkg.printf(t, name) }
            printDeepText(s.pkg, s.pkg.find(0x6f25a248), "\(i + 1)")
            printDeepText(s.pkg, s.pkg.find(0xb2037bdc), "\(count)")
            s.pkg.setVisible(s.pkg.find(0x8121a4f3), i == current)
            // Vista previa en el coche (el juego también monta la pieza al pasar por ella)
            if i != lastApplied, kind != .lightBar {
                lastApplied = i
                CarTuning.replacePlayerCar(self.engine, key: key, tune: items[i].1)
            }
        }
        s.refreshHeader()
        s.actions = (0..<opts.count).map { i in { [weak self] in
            guard let self else { return }
            if kind == .lightBar { lightItems[i].1() } else { CarTuning.set(key, items[i].1); CarTuning.replacePlayerCar(self.engine, key: key) }
            self.messageDialog(title: titleHash, text: (self.es ? "Instalado: " : "Installed: ") + (kind == .lightBar ? lightItems[i].0 : items[i].0)) { [weak self] in
                self?.showCustomizeCategory(parts: isParts)
            }
        } }
        garageScreen(kind == .paint ? "customize_customizeparts_257" : kind == .rims ? "customize_customizegenerictop_259" : "customize_customizeparts")
    }

}

extension IconScroller {
    /// Opción en gris (no seleccionable), como IsGreyOut [D]: Rendimiento del taller (sin piezas de motor aquí).
    func setGrey(_ index: Int) {
        let i = index + 2
        guard i < options.count else { return }
        greyOut(i)
    }
}
