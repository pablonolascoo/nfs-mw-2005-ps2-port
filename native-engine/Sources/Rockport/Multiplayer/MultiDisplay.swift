// Varias pantallas: una ventana sin bordes a pantalla completa en cada pantalla extra (NSScreen.screens), cada una con su
// MTKView/CAMetalLayer, su vsync y su resolución dinámica. La simulación va con la pantalla principal (App.swift); las demás
// solo dibujan sus vistas (`Engine.renderDisplay`) con el último estado.
//
// Límites (docs/es/19):
//   - Pantallas con distinta frecuencia: cada una dibuja a la suya; la simulación avanza al ritmo de la principal, así que en
//     una de 120 Hz con la principal a 60 Hz se ve cada estado dos veces (sin interpolar).
//   - GPU: cada pantalla es otra pasada de escena completa; el presupuesto (Config.gpuBudgetMs) es por pantalla y la escala
//     baja sola en la que no llegue.
//   - El teclado y el ratón van a la ventana principal (la de la pantalla principal sigue siendo la ventana clave).
import AppKit
import MetalKit
import QuartzCore

final class MultiDisplay: NSObject, MTKViewDelegate {
    static let shared = MultiDisplay()

    private final class Output {
        let window: NSWindow
        let view: MTKView
        let display: Int
        var scale: Float = 1
        var gpuMs: Double = 0
        init(window: NSWindow, view: MTKView, display: Int) { self.window = window; self.view = view; self.display = display }
    }
    private var outputs: [Output] = []
    private weak var engine: Engine?
    private let lock = NSLock()

    /// Pantallas extra abiertas.
    var count: Int { outputs.count }

    /// Abre `extra` ventanas en las pantallas que no son la principal (si las hay). Sin app en marcha no hace nada.
    func open(extra: Int, engine: Engine) {
        guard NSApp?.isRunning == true, extra > 0 else { return }
        close()
        self.engine = engine
        let main = NSScreen.main ?? NSScreen.screens.first
        let others = NSScreen.screens.filter { $0 != main }
        for (k, screen) in others.prefix(extra).enumerated() {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.isOpaque = true; w.backgroundColor = .black
            w.level = .normal
            w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            let v = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: engine.device)
            v.colorPixelFormat = .bgra8Unorm
            v.depthStencilPixelFormat = .invalid
            v.framebufferOnly = true
            v.preferredFramesPerSecond = screen.maximumFramesPerSecond
            (v.layer as? CAMetalLayer)?.displaySyncEnabled = true
            (v.layer as? CAMetalLayer)?.maximumDrawableCount = 3
            v.delegate = self
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFront(nil)
            outputs.append(Output(window: w, view: v, display: k + 1))
            print("Pantalla \(k + 2): \(screen.localizedName) · \(Int(screen.frame.width * screen.backingScaleFactor))×\(Int(screen.frame.height * screen.backingScaleFactor)) a \(screen.maximumFramesPerSecond) Hz")
        }
    }

    func close() {
        for o in outputs { o.view.delegate = nil; o.window.orderOut(nil) }
        outputs.removeAll()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let e = engine, let o = outputs.first(where: { $0.view === view }), e.splitScreen?.active == true,
              let drawable = view.currentDrawable, let cb = e.queue.makeCommandBuffer() else { return }
        // Resolución dinámica de esta pantalla, como App.updateScale
        lock.lock(); let g = o.gpuMs; lock.unlock()
        if g > Config.gpuBudgetMs { o.scale *= 0.96 } else if g < Config.gpuBudgetMs * 0.7 { o.scale *= 1.01 }
        o.scale = max(Config.minRenderScale, min(Config.maxRenderScale, o.scale))
        e.renderDisplay(o.display, cb: cb, target: drawable.texture, scale: o.scale)
        cb.addCompletedHandler { [weak self] b in
            self?.lock.lock(); o.gpuMs = (b.gpuEndTime - b.gpuStartTime) * 1000; self?.lock.unlock()
        }
        cb.present(drawable)
        cb.commit()
    }
}
