import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreText
import CoreGraphics
import AppKit
import Metal

/// Where the camera bubble sits. Screen coordinates here are CoreImage's, so
/// the origin is the bottom left.
enum BubbleCorner: String, CaseIterable, Sendable {
    case bottomLeft, bottomRight, topLeft, topRight

    var label: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }

    func origin(in canvas: CGSize, diameter d: CGFloat, inset: CGFloat) -> CGPoint {
        switch self {
        case .bottomLeft:  return CGPoint(x: inset, y: inset)
        case .bottomRight: return CGPoint(x: canvas.width - d - inset, y: inset)
        case .topLeft:     return CGPoint(x: inset, y: canvas.height - d - inset)
        case .topRight:    return CGPoint(x: canvas.width - d - inset, y: canvas.height - d - inset)
        }
    }
}

/// Screen frame in, finished frame out. One of these per recording; it holds
/// the CIContext and the masks, which are the only expensive things here, and
/// builds them once.
///
/// The camera is burned into the picture rather than kept as its own track.
/// That fixes where the bubble sits at record time and it cannot be moved
/// afterwards, which is the trade: one file that plays anywhere, against
/// flexibility nobody has asked for yet.
final class Compositor: @unchecked Sendable {
    let canvas: CGSize
    private let context: CIContext
    private var bubbleMask: CIImage?
    private var ringImage: CIImage?
    private var maskDiameter: CGFloat = -1
    private var captionCache: [String: CIImage] = [:]
    private let lock = NSLock()

    /// Diameter as a fraction of the canvas height, so the bubble looks the
    /// same size whatever display it was recorded on.
    var bubbleFraction: CGFloat = 0.17
    var corner: BubbleCorner = .bottomLeft
    var mirrored = true
    var insetFraction: CGFloat = 0.025
    /// Bottom-left of the bubble in canvas pixels. Set while the preview window
    /// is being dragged, so the burned-in bubble lands where you put it on
    /// screen. Nil falls back to `corner`.
    var explicitOrigin: CGPoint?

    init(canvas: CGSize) {
        self.canvas = canvas
        // Metal-backed, and told not to cache intermediates: every frame is
        // different, so a cache here is pure memory growth over a long record.
        let device = MTLCreateSystemDefaultDevice()
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false,
                                            .workingColorSpace: CGColorSpaceCreateDeviceRGB()]
        if let device {
            context = CIContext(mtlDevice: device, options: opts)
        } else {
            context = CIContext(options: opts)
        }
    }

    var diameter: CGFloat { (canvas.height * bubbleFraction / 2).rounded() * 2 }

    // MARK: - the frame

    func render(screen: CVPixelBuffer, camera: CVPixelBuffer?, caption: String?, into out: CVPixelBuffer) {
        var image = CIImage(cvPixelBuffer: screen)

        if let camera, let bubble = bubbleImage(from: camera) {
            let d = diameter
            let inset = (canvas.height * insetFraction).rounded()
            let at = explicitOrigin.map { p in
                CGPoint(x: min(max(0, p.x), canvas.width - d),
                        y: min(max(0, p.y), canvas.height - d))
            } ?? corner.origin(in: canvas, diameter: d, inset: inset)
            image = bubble.transformed(by: .init(translationX: at.x, y: at.y))
                .composited(over: image)
        }

        if let caption, !caption.isEmpty, let text = captionImage(caption) {
            let w = text.extent.width
            let x = ((canvas.width - w) / 2).rounded()
            let y = (canvas.height * 0.055).rounded()
            image = text.transformed(by: .init(translationX: x, y: y)).composited(over: image)
        }

        context.render(image, to: out, bounds: CGRect(origin: .zero, size: canvas),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    // MARK: - the bubble

    /// Centre-cropped to a square, scaled to the bubble, masked to a circle and
    /// dropped on a soft ring so it reads against a busy screen.
    private func bubbleImage(from camera: CVPixelBuffer) -> CIImage? {
        let d = diameter
        buildMasks(diameter: d)
        guard let mask = bubbleMask else { return nil }

        var cam = CIImage(cvPixelBuffer: camera)
        let e = cam.extent
        let side = min(e.width, e.height)
        let square = CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side)
        cam = cam.cropped(to: square).transformed(by: .init(translationX: -square.minX, y: -square.minY))

        if mirrored {
            // Mirrored on purpose. This is what you saw in the preview while you
            // were recording, and an unmirrored face reads as slightly wrong to
            // the person in it. Turn it off with --no-mirror if you ever hold
            // writing up to the lens.
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -side, y: 0))
        }

        let scale = d / side
        cam = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: d, height: d))

        let circle = cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        guard let ring = ringImage else { return circle }
        return circle.composited(over: ring)
    }

    private func buildMasks(diameter d: CGFloat) {
        guard maskDiameter != d else { return }
        maskDiameter = d
        let r = d / 2

        // A radial gradient is the cheap way to an antialiased circle: hard
        // white to the last pixel, then a one-pixel ramp to clear.
        func disc(radius: CGFloat, colour: CIColor) -> CIImage? {
            let f = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: r, y: r),
                "inputRadius0": radius - 1,
                "inputRadius1": radius,
                "inputColor0": colour,
                "inputColor1": CIColor.clear,
            ])
            return f?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: d, height: d))
        }

        bubbleMask = disc(radius: r - 2, colour: .white)
        ringImage = disc(radius: r, colour: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    }

    // MARK: - captions

    /// Captions are drawn once per line of text and reused for every frame that
    /// line is on screen, which at 30fps is the difference between laying out
    /// text ninety times and doing it once.
    private func captionImage(_ text: String) -> CIImage? {
        lock.lock()
        if let hit = captionCache[text] { lock.unlock(); return hit }
        lock.unlock()
        guard let cg = Compositor.drawCaption(text,
                                              maxWidth: canvas.width * 0.7,
                                              fontSize: max(16, canvas.height * 0.032)) else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock()
        // A long recording would otherwise hold every line it ever showed.
        if captionCache.count > 64 { captionCache.removeAll() }
        captionCache[text] = img
        lock.unlock()
        return img
    }

    static func drawCaption(_ text: String, maxWidth: CGFloat, fontSize: CGFloat) -> CGImage? {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = fontSize * 0.18

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange()
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), &fitRange)

        let padX = fontSize * 0.75, padY = fontSize * 0.5
        let w = ceil(textSize.width + padX * 2), h = ceil(textSize.height + padY * 2)
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        let box = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                         cornerWidth: fontSize * 0.45, cornerHeight: fontSize * 0.45, transform: nil)
        ctx.addPath(box)
        ctx.fillPath()

        let textRect = CGRect(x: padX, y: padY, width: ceil(textSize.width), height: ceil(textSize.height))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }
}
