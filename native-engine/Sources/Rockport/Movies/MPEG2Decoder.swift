// Vídeo MPEG-2 de las películas con VideoToolbox de macOS (doc 22 §4).
//
// Cada bloque MPCh es una imagen MPEG-2 completa: se pasa tal cual como una muestra (kCMVideoCodecType_MPEG2Video).
// VideoToolbox devuelve las imágenes en ORDEN DE DECODIFICACIÓN [V: doc 22] (I P B B P…): cada muestra lleva su PTS
// (= base del GOP + temporal_reference, MPCFile) y aquí se reordenan a orden de presentación con una ventana pequeña.
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class MPEG2Decoder {
    struct Frame {
        let pts: Int
        let image: CVPixelBuffer
    }

    private let mpc: MPCFile
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var next = 0               // siguiente bloque a decodificar
    private var nextPTS = 0            // siguiente imagen a entregar en orden de presentación
    private var pending: [Int: CVPixelBuffer] = [:]
    private(set) var decodeErrors = 0
    private(set) var decoded = 0
    /// Orden en que VideoToolbox devolvió las imágenes (PTS), para las pruebas.
    private(set) var outputOrder: [Int] = []
    var recordOrder = false

    init(_ mpc: MPCFile) throws {
        self.mpc = mpc
        var fmt: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_MPEG2Video,
                                                width: Int32(mpc.width), height: Int32(mpc.height), extensions: nil, formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else { throw NSError(domain: "MPEG2", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "formato MPEG-2 no válido (\(st))"]) }
        format = fmt
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard r == noErr, let s else { throw NSError(domain: "MPEG2", code: Int(r), userInfo: [NSLocalizedDescriptionKey: "VideoToolbox no decodifica MPEG-2 (\(r))"]) }
        session = s
    }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    var finished: Bool { next >= mpc.pictures.count && pending.isEmpty }

    /// Decodifica hasta tener la siguiente imagen en orden de presentación. nil al terminar.
    func nextFrame() -> Frame? {
        while true {
            if let img = pending.removeValue(forKey: nextPTS) { defer { nextPTS += 1 }; return Frame(pts: nextPTS, image: img) }
            if next >= mpc.pictures.count {
                // Final: lo que quede (si faltó alguna imagen, se salta su hueco)
                guard let k = pending.keys.min() else { return nil }
                nextPTS = k
                continue
            }
            // Una imagen perdida no puede atascar la cola: si hay muchas esperando, se salta el hueco
            if pending.count > 6, let k = pending.keys.min(), k > nextPTS { nextPTS = k; continue }
            decodeOne()
        }
    }

    private func decodeOne() {
        guard let session, let format else { next = mpc.pictures.count; return }
        let pic = mpc.pictures[next]
        next += 1
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: pic.size, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: pic.size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { decodeErrors += 1; return }
        let ok = mpc.data.withUnsafeBytes { raw -> Bool in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + pic.offset, blockBuffer: block, offsetIntoDestination: 0, dataLength: pic.size) == noErr
        }
        guard ok else { decodeErrors += 1; return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25), presentationTimeStamp: CMTime(value: CMTimeValue(pic.pts), timescale: 25),
                                        decodeTimeStamp: CMTime(value: CMTimeValue(next - 1), timescale: 25))
        var size = pic.size
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { decodeErrors += 1; return }
        var info = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &info) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            guard status == noErr, let image else { self.decodeErrors += 1; return }
            let k = pts.isValid ? Int(pts.value) : -1
            self.decoded += 1
            if self.recordOrder { self.outputOrder.append(k) }
            if k >= self.nextPTS { self.pending[k] = image }
        }
        if st != noErr { decodeErrors += 1 }
        if next >= mpc.pictures.count {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }
}
