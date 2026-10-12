// Mandos HID que GameController no reconoce, por IOKit (IOHIDManager), con conexión en caliente:
//  · DualShock 3 por USB (054C:0268): se activa con el informe 0xF4 y se lee el informe 0x01 entero
//    (botones, sticks y presión de L2/R2/✕/□); vibración con el informe de salida 0x01. Disposición de bytes
//    tomada del controlador hid-sony de Linux (público) [I: no viene del juego].
//  · Adaptadores USB de mandos de PS2 ("Twin USB Joystick" 0810:0001/0003, GreenAsia 0E8F:0003, 0E8F:3013…):
//    ejes X/Y (stick izq.), Z/Rz (stick der.), botones 1 △ 2 ○ 3 ✕ 4 □ 5 L2 6 R2 7 L1 8 R1 9 Select 10 Start [I].
//  · Cualquier otro mando HID (página 1, uso 4 joystick / 5 gamepad): disposición tipo SDL/DirectInput [I].
// Lo que GameController ya lleva (GCController.supportsHIDDevice) se ignora aquí para no leerlo dos veces.
import Foundation
import IOKit
import IOKit.hid
import IOKit.usb
import GameController

final class HIDPads {
    enum Kind: String { case ds3 = "DualShock 3", ps2 = "adaptador de PS2", generic = "mando HID genérico" }

    final class Pad {
        let device: IOHIDDevice
        let kind: Kind
        let vendor: Int, product: Int, name: String
        var axes = [Int: Float]()          // uso HID → −1…1
        var buttons = [Int: Bool]()        // nº de botón → pulsado
        var hat = 8
        var report = [UInt8](repeating: 0, count: 64)
        var reportBuffer: UnsafeMutablePointer<UInt8>?
        var prev = [String: Bool]()
        var lastRumble: (UInt8, UInt8) = (0, 0)
        init(device: IOHIDDevice, kind: Kind, vendor: Int, product: Int, name: String) {
            self.device = device; self.kind = kind; self.vendor = vendor; self.product = product; self.name = name
        }
    }

    private var manager: IOHIDManager?
    private(set) var pads: [Pad] = []
    static let ps2Adapters: Set<Int> = [0x0810_0001, 0x0810_0003, 0x0E8F_0003, 0x0E8F_3013, 0x0925_8866, 0x0925_1700, 0x2563_0575]

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<HIDPads>.fromOpaque(ctx).takeUnretainedValue().added(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<HIDPads>.fromOpaque(ctx).takeUnretainedValue().removed(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { print("IOHIDManager: no se pudo abrir (\(r)). Revisa Privacidad › Monitorización de entrada si no responde ningún mando HID.") }
        manager = m
    }

    func hasDevice(vendor: Int) -> Bool { pads.contains { $0.vendor == vendor } }

    private static func prop(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? 0 }

    private func added(_ dev: IOHIDDevice) {
        if pads.contains(where: { $0.device === dev }) { return }
        if GCController.supportsHIDDevice(dev) { return }      // ya lo lleva GameController
        let v = HIDPads.prop(dev, kIOHIDVendorIDKey), p = HIDPads.prop(dev, kIOHIDProductIDKey)
        let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? String(format: "%04X:%04X", v, p)
        let kind: Kind = (v == 0x054C && p == 0x0268) ? .ds3 : HIDPads.ps2Adapters.contains(v << 16 | p) ? .ps2 : .generic
        let pad = Pad(device: dev, kind: kind, vendor: v, product: p, name: name)
        pads.append(pad)
        let ctx = Unmanaged.passUnretained(pad).toOpaque()
        if kind == .ds3 {
            // Sin este informe de características el DualShock 3 no manda nada por USB
            var enable: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0xF4, &enable, enable.count)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            pad.reportBuffer = buf
            IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, _, report, len in
                guard let ctx else { return }
                let pad = Unmanaged<HIDPads.Pad>.fromOpaque(ctx).takeUnretainedValue()
                for i in 0..<min(len, 64) { pad.report[i] = report[i] }
            }, ctx)
            setDS3(pad, strong: 0, weak: 0)
        } else {
            IOHIDDeviceRegisterInputValueCallback(dev, { ctx, _, _, value in
                guard let ctx else { return }
                Unmanaged<HIDPads.Pad>.fromOpaque(ctx).takeUnretainedValue().handle(value)
            }, ctx)
        }
        print(String(format: "Mando conectado: %@ (%04X:%04X, %@) · IOKit HID", name, v, p, kind.rawValue))
    }

    private func removed(_ dev: IOHIDDevice) {
        guard let i = pads.firstIndex(where: { $0.device === dev }) else { return }
        print("Mando desconectado: \(pads[i].name)")
        pads[i].reportBuffer?.deallocate()
        pads.remove(at: i)
    }

    // MARK: Lectura

    func poll() -> PadState {
        var out = PadState()
        for p in pads { out.merge(p.kind == .ds3 ? readDS3(p) : readGeneric(p)) }
        return out
    }

    private func edge(_ p: Pad, _ k: String, _ v: Bool) -> Bool { let was = p.prev[k] ?? false; p.prev[k] = v; return v && !was }

    /// Informe USB 0x01 del DualShock 3 (49 bytes) [I: hid-sony].
    private func readDS3(_ p: Pad) -> PadState {
        let r = p.report
        var s = PadState()
        guard r[0] == 0x01 else { return s }
        let b1 = r[2], b2 = r[3]
        func axis(_ v: UInt8) -> Float { (Float(v) - 128) / 127 }
        s.steer = Deadzone.apply(axis(r[6]), Deadzone.steer)
        let ry = Deadzone.apply(-axis(r[9]), Deadzone.rightStick)
        // Presión analógica: L2 r[18], R2 r[19], ✕ r[24], □ r[25]. El juego llena GAS con ✕ al 80 % (mUpperDZ 0,8) [V valor, I uso]
        let l2 = Float(r[18]) / 255, r2 = Float(r[19]) / 255
        s.gas = max(r2, max(ry, 0))
        s.brake = max(l2, max(-ry, 0))
        s.handBrake = (b2 & 0x40) != 0 ? 1 : ((b2 & 0x08) != 0 ? 1 : 0)   // ✕ o R1
        s.nos = (b2 & 0x20) != 0                                            // ○
        s.lookBack = (b2 & 0x04) != 0 || (b1 & 0x02) != 0                   // L1 o L3
        s.nextCamera = edge(p, "tri", (b2 & 0x10) != 0) || edge(p, "dr", (b1 & 0x20) != 0)
        s.prevCamera = edge(p, "dl", (b1 & 0x80) != 0)
        s.reset = edge(p, "sq", (b2 & 0x80) != 0) || edge(p, "sel", (b1 & 0x01) != 0)
        s.toggleFreeCamera = edge(p, "start", (b1 & 0x08) != 0)
        s.shiftUp = (b1 & 0x10) != 0; s.shiftDown = (b1 & 0x40) != 0
        s.active = s.gas > 0 || s.brake > 0 || s.steer != 0
        return s
    }

    private func readGeneric(_ p: Pad) -> PadState {
        var s = PadState()
        func btn(_ n: Int) -> Bool { p.buttons[n] ?? false }
        let ps2 = p.kind == .ps2
        // Botones según disposición: PS2 (1 △ 2 ○ 3 ✕ 4 □ 5 L2 6 R2 7 L1 8 R1 9 Select 10 Start 11 L3 12 R3)
        // o genérica (1 ✕ 2 ○ 3 □ 4 △ 5 L1 6 R1 7 L2 8 R2 9 Select 10 Start 11 L3 12 R3) [I]
        let (tri, cir, cro, squ, l2, r2, l1, r1) = ps2 ? (1, 2, 3, 4, 5, 6, 7, 8) : (4, 2, 1, 3, 7, 8, 5, 6)
        s.steer = Deadzone.apply(p.axes[kHIDUsage_GD_X] ?? 0, Deadzone.steer)
        let ry = Deadzone.apply(-(p.axes[kHIDUsage_GD_Rz] ?? p.axes[kHIDUsage_GD_Ry] ?? 0), Deadzone.rightStick)
        // L2/R2 son botones digitales en estos mandos; el gas/freno analógico va por el stick derecho
        s.gas = max(btn(r2) ? 1 : 0, max(ry, 0))
        s.brake = max(btn(l2) ? 1 : 0, max(-ry, 0))
        s.handBrake = (btn(cro) || btn(r1)) ? 1 : 0
        s.nos = btn(cir)
        s.lookBack = btn(l1) || btn(11)
        s.nextCamera = edge(p, "tri", btn(tri)) || edge(p, "dr", p.hat == 2)
        s.prevCamera = edge(p, "dl", p.hat == 6)
        s.reset = edge(p, "sq", btn(squ)) || edge(p, "sel", btn(9))
        s.toggleFreeCamera = edge(p, "start", btn(10))
        s.shiftUp = p.hat == 0; s.shiftDown = p.hat == 4
        s.active = s.gas > 0 || s.brake > 0 || s.steer != 0
        return s
    }

    // MARK: Vibración (solo DualShock 3 por USB)

    func rumble(strong: Float, weak: Float) {
        for p in pads where p.kind == .ds3 { setDS3(p, strong: strong, weak: weak) }
    }

    /// Informe de salida 0x01 de 36 bytes: motor pequeño encendido/apagado y motor grande 0…255; LED 1 [I: hid-sony].
    private func setDS3(_ p: Pad, strong: Float, weak: Float) {
        let big = UInt8(max(0, min(255, strong * 255))), small: UInt8 = weak > 0.3 ? 1 : 0
        if (small, big) == p.lastRumble && big != 0 { return }
        p.lastRumble = (small, big)
        var r: [UInt8] = [0x01, 0x00, 0xFF, small, 0xFF, big, 0, 0, 0, 0, 0x02]
        for _ in 0..<4 { r += [0xFF, 0x27, 0x10, 0x00, 0x32] }
        r += [0, 0, 0, 0, 0]
        _ = IOHIDDeviceSetReport(p.device, kIOHIDReportTypeOutput, 0x01, &r, r.count)
    }
}

extension HIDPads.Pad {
    func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el)), usage = Int(IOHIDElementGetUsage(el))
        let v = IOHIDValueGetIntegerValue(value)
        if page == kHIDPage_Button { buttons[usage] = v != 0; return }
        guard page == kHIDPage_GenericDesktop else { return }
        if usage == kHIDUsage_GD_Hatswitch {
            let lo = IOHIDElementGetLogicalMin(el), hi = IOHIDElementGetLogicalMax(el)
            hat = (v < lo || v > hi) ? 8 : (hi - lo == 3 ? (v - lo) * 2 : v - lo)
            return
        }
        let lo = Float(IOHIDElementGetLogicalMin(el)), hi = Float(IOHIDElementGetLogicalMax(el))
        guard hi > lo else { return }
        axes[usage] = (Float(v) - lo) / (hi - lo) * 2 - 1
    }
}

/// ¿Hay un dispositivo USB con este fabricante y alguno de estos productos? (detección del Xbox 360 sin controlador)
enum USBProbe {
    static func present(vendor: Int, products: [Int]) -> Bool {
        guard let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        dict["idVendor"] = vendor
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        var found = false
        var s = IOIteratorNext(it)
        while s != 0 {
            if let p = IORegistryEntryCreateCFProperty(s, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
               products.contains(p.intValue) { found = true }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        return found
    }
}
