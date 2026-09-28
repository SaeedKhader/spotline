import AppKit
import CMPV
import OpenGL.GL3

/// Draws mpv's video frames through the libmpv OpenGL render API, the same
/// approach IINA uses. OpenGL is deprecated on macOS but libmpv has no Metal
/// render API; see docs/ARCHITECTURE.md section 4 for the fallback plan.
///
/// Drawing is synchronous on the main thread: mpv's update callback asks for a
/// redraw, and Core Animation calls `draw(inCGLContext:…)` on its next commit.
final class MPVVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    private let handle: MPVHandle
    private let onRenderContextReady: @MainActor @Sendable () -> Void
    /// Only touched on the main thread, where Core Animation drives this layer.
    private var renderContext: OpaquePointer?
    private lazy var redrawRelay = RedrawRelay(layer: self)

    init(handle: MPVHandle, onRenderContextReady: @escaping @MainActor @Sendable () -> Void) {
        self.handle = handle
        self.onRenderContextReady = onRenderContextReady
        super.init()
        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    /// Core Animation copies layers for presentation; the copy never renders.
    override init(layer: Any) {
        let other = layer as! MPVVideoLayer
        handle = other.handle
        onRenderContextReady = other.onRenderContextReady
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("MPVVideoLayer is not decodable")
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let core = CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue))
        let legacy = CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_Legacy.rawValue))
        // Accelerated first; the fallbacks cover virtual machines such as CI runners.
        let candidates: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, core, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers],
            [kCGLPFAOpenGLProfile, core, kCGLPFAAllowOfflineRenderers],
            [kCGLPFAOpenGLProfile, legacy],
        ]
        for attributes in candidates {
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attributes + [CGLPixelFormatAttribute(0)], &pixelFormat, &count) == kCGLNoError,
               let pixelFormat {
                return pixelFormat
            }
        }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        CGLSetCurrentContext(context)
        if renderContext == nil { createRenderContext() }
        return context
    }

    override func releaseCGLContext(_ context: CGLContextObj) {
        if let renderContext {
            CGLSetCurrentContext(context)
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        super.releaseCGLContext(context)
    }

    override func draw(
        inCGLContext context: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime layerTime: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            super.draw(inCGLContext: context, pixelFormat: pixelFormat, forLayerTime: layerTime, displayTime: displayTime)
            return
        }
        _ = mpv_render_context_update(renderContext)

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var target = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
        var flipY: Int32 = 1
        // Never let mpv wait for a frame's display time on the main thread.
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &target) { target in
            withUnsafeMutablePointer(to: &flipY) { flipY in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockForTargetTime in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: target),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipY),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockForTargetTime),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(renderContext, &parameters)
                }
            }
        }
        super.draw(inCGLContext: context, pixelFormat: pixelFormat, forLayerTime: layerTime, displayTime: displayTime)
        mpv_render_context_report_swap(renderContext)
    }

    private func createRenderContext() {
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        var initParameters = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name,
                      let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue),
                      let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                else { return nil }
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        var context: OpaquePointer?
        let result = withUnsafeMutablePointer(to: &initParameters) { initParameters in
            var parameters = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParameters),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&context, handle.raw, &parameters)
        }
        guard result >= 0, let context else {
            print("mpv: \(MPVError(code: result, context: "mpv_render_context_create"))")
            return
        }
        renderContext = context
        mpv_render_context_set_update_callback(context, { relay in
            guard let relay else { return }
            Unmanaged<RedrawRelay>.fromOpaque(relay).takeUnretainedValue().requestRedraw()
        }, Unmanaged.passUnretained(redrawRelay).toOpaque())
        let ready = onRenderContextReady
        DispatchQueue.main.async { MainActor.assumeIsolated { ready() } }
    }
}

/// The context pointer for mpv's render update callback, which runs on an mpv
/// thread. It asks for a redraw on the main thread if the layer still exists.
private final class RedrawRelay: @unchecked Sendable {
    private weak var layer: MPVVideoLayer?

    init(layer: MPVVideoLayer) { self.layer = layer }

    func requestRedraw() {
        DispatchQueue.main.async { self.layer?.setNeedsDisplay() }
    }
}

/// Hosts `MPVVideoLayer` and keeps it sized for the window's backing scale.
final class MPVVideoView: NSView {
    let videoLayer: MPVVideoLayer

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        fatalError("MPVVideoView is not decodable")
    }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        videoLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        videoLayer.setNeedsDisplay()
    }
}
