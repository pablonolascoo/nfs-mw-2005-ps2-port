// «Pulsa START para unirte»: el paquete PressStart.fng del juego (uiQRPressStart [D]) para repartir mandos entre jugadores.
//
// En el juego [D]: «Jugador %d presiona START.» (0xCF538E1C); el puerto que pulsa queda para ese jugador y el jugador 2 no
// puede usar el del 1 (SetPlayersJoystickPort). Texto de ayuda: «Los jugadores eligen qué puertos de mando usarán el Jugador
// 1 y el Jugador 2. El primero en elegir será designado como Jugador 1.» (0x61E75E95).
//
// Aquí (extensión: hasta 4 jugadores, una sola pantalla para todos):
//   - Cualquier mando (o el teclado) pulsa START / ✕ / A (Intro en el teclado) y se une con el número siguiente.
//   - El primero es el jugador 1 (el «mando maestro»): sus menús, su coche primero.
//   - Un jugador unido que pulsa ○ / B (Retroceso en el teclado) se va; si es el 1 y está solo, se vuelve atrás.
//   - Con 2 o más, el jugador 1 pulsa START (o Intro en el teclado) otra vez para seguir.
//   - Cada mando unido se pinta con el color de su jugador (barra de luz) y enciende su LED de jugador.
import Foundation

final class QRJoinScreen: QRScreen {
    override var perDevice: Bool { true }
    private var blink: Float = 0

    init?(flow: QuickRaceFlow) {
        super.init(flow: flow, package: "PressStart")
        // Al volver a esta pantalla se vuelve a empezar el reparto
        for d in flow.joined { d.setPlayer(nil, color: nil) }
        flow.joined = []
        MenuOwners.allowed = nil
        refresh()
    }

    private func refresh() {
        let n = flow.joined.count
        let fmt = str(0xCF538E1C, "Jugador %d presiona START.")
        if n < 4 { text(0xB244CF71, fmt.replacingOccurrences(of: "%d", with: "\(n + 1)").trimmingCharacters(in: .whitespaces)) }
        else { text(0xB244CF71, es ? "4 jugadores listos" : "4 players ready") }
        // Cuerpo: quién es quién (mando, número y color) y cómo seguir
        var lines: [String] = []
        for (i, d) in flow.joined.enumerated() {
            let who = (es ? "Jugador " : "Player ") + "\(i + 1)"
            let master = i == 0 ? (es ? " (mando principal)" : " (master)") : ""
            lines.append("\(who): \(d.label(spanish: es))\(master)")
        }
        if n == 0 { lines.append(str(0x61E75E95, "El primero en elegir será designado como Jugador 1.")) }
        else if n == 1 { lines.append(es ? "Falta al menos otro jugador." : "Waiting for at least one more player.") }
        else { lines.append(es ? "Jugador 1: START para empezar con \(n) jugadores." : "Player 1: START to race with \(n) players.") }
        for o in pkg.findAll(0x545570C6) { pkg.printf(o, lines.joined(separator: "^")) }
        // Botón «Elegir»: solo con 2 o más
        show(0xE795717D, n >= 2); show(0xB94139F4, n >= 2)
    }

    override func update(dt: Float) {
        blink += dt
    }

    override func handle(devices: [(PlayerDevice, MenuButtons)]) {
        // Mandos desenchufados mientras se espera: fuera de la lista
        let before = flow.joined.count
        flow.joined.removeAll { !$0.connected }
        if flow.joined.count != before { recolor(); refresh() }
        for (d, m) in devices {
            if let i = flow.joined.firstIndex(where: { $0.same(d) }) {
                if m.back {
                    if i == 0 && flow.joined.count == 1 { goBack(); return }
                    d.setPlayer(nil, color: nil)
                    flow.joined.remove(at: i)
                    recolor(); refresh()
                    return
                }
                let go = (d.kind == .keyboard ? m.accept : (m.start || m.accept)) && i == 0 && flow.joined.count >= 2
                if go { confirm(); return }
            } else if m.start || m.accept, flow.joined.count < 4 {
                join(d)
                return
            } else if m.back, flow.joined.isEmpty {
                goBack(); return
            }
        }
    }

    private func join(_ d: PlayerDevice) {
        flow.joined.append(d)
        recolor()
        pkg.post(0x587C018B)            // FEObj_leavescreen en el juego; aquí solo anima el recuadro [I]
        print("Pantalla partida: jugador \(flow.joined.count) = \(d.label(spanish: true)) (\(d.name))")
        refresh()
    }

    /// Pruebas sin ventana: unir un dispositivo sin pulsar nada.
    func testJoin(_ d: PlayerDevice) { flow.joined.append(d); refresh() }

    private func recolor() {
        for (i, d) in flow.joined.enumerated() { d.setPlayer(i, color: SplitScreen.colors[i % 4]) }
    }

    func confirm() {
        guard flow.joined.count >= 2 else { return }
        flow.players = flow.joined.count
        // A partir de aquí los menús los lleva el jugador 1 (y la selección de coche, cada uno la suya)
        // (jugador 1 con teclado: ningún mando mueve los menús; el teclado siempre puede)
        MenuOwners.allowed = Set(flow.joined.prefix(1).compactMap(\.key))
        flow.chosen = Array(flow.chosen.prefix(flow.players))
        flow.leave { [weak flow] in flow?.showCarSelect(player: 0) }
    }

    private func goBack() {
        for d in flow.joined { d.setPlayer(nil, color: nil) }
        flow.joined = []
        let m = flow.mode
        flow.leave { [weak flow] in
            if m == .drag || m == .sprint || m == .speedtrap { flow?.showTrackSelect() } else { flow?.showTrackOptions() }
        }
    }
}
