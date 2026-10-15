// Salidas de audio de CoreAudio y búsqueda del altavoz del mando.
// Por USB, el DualSense aparece como dispositivo de audio («DualSense Wireless Controller», 4 canales: 1-2 auriculares/altavoz,
// 3-4 hápticos) y el DualShock 4 como «Wireless Controller» (estéreo) [I: por el nombre USB; probar con hardware].
// Por Bluetooth macOS NO crea dispositivo de audio para ninguno de los dos: ver PadBluetoothAudio.swift.
import Foundation
import CoreAudio

struct AudioOutputDevice: CustomStringConvertible {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: String
    let channels: Int
    var isController: Bool {
        let n = name.lowercased()
        return n.contains("dualsense") || n.contains("wireless controller") || n.contains("dualshock")
    }
    var description: String { "\(name) · \(transport) · \(channels) canales · uid \(uid)" }
}

enum AudioDevices {
    private static func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s) == noErr, let s else { return "" }
        return s.takeRetainedValue() as String
    }

    /// Todas las salidas (dispositivos con canales de salida).
    static func outputs() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = outputChannels(id)
            guard ch > 0 else { return nil }
            let t = u32(id, kAudioDevicePropertyTransportType) ?? 0
            let transport: String = {
                switch t {
                case kAudioDeviceTransportTypeUSB: return "USB"
                case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
                case kAudioDeviceTransportTypeBuiltIn: return "integrado"
                case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "pantalla"
                case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
                default: return String(format: "0x%08X", t)
                }
            }()
            return AudioOutputDevice(id: id, name: string(id, kAudioObjectPropertyName), uid: string(id, kAudioDevicePropertyDeviceUID), transport: transport, channels: ch)
        }
    }

    static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// El altavoz del mando conectado por USB, si lo hay.
    static func controllerSpeaker() -> AudioOutputDevice? { outputs().first { $0.isController && $0.transport != "Bluetooth" } }
}
