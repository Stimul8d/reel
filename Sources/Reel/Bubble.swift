import AppKit
import CoreImage
import CoreVideo
import Foundation

/// The camera bubble you can see while recording: a borderless circular window
/// floating over everything, draggable, showing exactly what is being burned
/// into the film.
///
/// It has to be the same size and in the same place as the bubble in the
/// recording, or the preview is a lie. So it is sized from the compositor's
/// own diameter, converted from capture pixels back into screen points, and it
/// reports where it has been dragged to so the compositor can follow.
///
/// It does not appear in the recording: ScreenCaptureKit is told to exclude
/// this application from the shot.
@MainActor
final class Bubble {
    private var window: NSWindow?
    private var view: BubbleView?
    private var timer: Timer?
    private var screen: NSScreen?
    private var canvas: CGSize = .zero
    private var observer: NSObjectProtocol?

    /// Called with the bubble's bottom-left corner in capture pixels whenever
    /// it moves.
    var onMove: ((CGPoint) -> Void)?

    func show(camera: Camera, canvas: CGSize, diameterPixels: CGFloat,
              on displayID: CGDirectDisplayID, corner: BubbleCorner, inset: CGFloat, mirrored: Bool) {
        hide()
        self.canvas = canvas
        let target = NSScreen.screens.first { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        guard let target else { return }
        screen = target

        // Capture pixels back into screen points, so what you see is the size
        // it will be in the file.
        let scale = target.frame.width / canvas.width
        let d = max(80, (diameterPixels * scale).rounded())
        let pad = (inset * scale).rounded()

        var origin: CGPoint
        switch corner {
        case .bottomLeft:  origin = CGPoint(x: pad, y: pad)
        case .bottomRight: origin = CGPoint(x: target.frame.width - d - pad, y: pad)
        case .topLeft:     origin = CGPoint(x: pad, y: target.frame.height - d - pad)
        case .topRight:    origin = CGPoint(x: target.frame.width - d - pad, y: target.frame.height - d - pad)
        }
        origin.x += target.frame.minX
        origin.y += target.frame.minY

        let w = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: d, height: d),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Never steals focus: you are meant to carry on working underneath it.
        w.ignoresMouseEvents = false

        let v = BubbleView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        v.camera = camera
        v.mirrored = mirrored
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        view = v

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }

        // 20fps is plenty for a preview and leaves the machine alone; the
        // recording itself takes camera frames independently.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            MainActor.assumeIsolated { v.refresh() }
        }
        report()
    }

    private func report() {
        guard let window, let screen, canvas.width > 0 else { return }
        let scale = canvas.width / screen.frame.width
        let x = (window.frame.minX - screen.frame.minX) * scale
        let y = (window.frame.minY - screen.frame.minY) * scale
        onMove?(CGPoint(x: x.rounded(), y: y.rounded()))
    }

    func setRecording(_ on: Bool) { view?.recording = on; view?.needsDisplay = true }

    func hide() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

private final class BubbleView: NSView {
    weak var camera: Camera?
    var mirrored = true
    var recording = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var image: CGImage?

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = bounds.width / 2
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
    }

    func refresh() {
        guard let px = camera?.currentFrame() else { return }
        var ci = CIImage(cvPixelBuffer: px)
        let e = ci.extent
        let side = min(e.width, e.height)
        let square = CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side)
        ci = ci.cropped(to: square).transformed(by: .init(translationX: -square.minX, y: -square.minY))
        if mirrored {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
        }
        image = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: side, height: side))
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        if let image {
            ctx.draw(image, in: bounds)
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fill(bounds)
        }
        ctx.restoreGState()
        ctx.addPath(circle)
        ctx.setStrokeColor(recording
            ? NSColor(red: 0.98, green: 0.32, blue: 0.34, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(recording ? 4 : 3)
        ctx.strokePath()
    }
}
