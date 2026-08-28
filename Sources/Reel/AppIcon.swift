import SwiftUI
import AppKit

/// A screen with someone in the corner of it, which is the whole app. Drawn in
/// code so there is no binary asset in the repo. It is judged at 32px in the
/// menu bar, so it is three shapes and no detail.
struct AppIconArt: View {
    var size: CGFloat

    private var slate: Color { Color(red: 0.13, green: 0.15, blue: 0.20) }
    private var deep: Color { Color(red: 0.05, green: 0.06, blue: 0.09) }
    private var glass: Color { Color(red: 0.30, green: 0.72, blue: 0.98) }
    private var live: Color { Color(red: 0.98, green: 0.32, blue: 0.34) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [slate, deep], startPoint: .top, endPoint: .bottom))

            // The screen being recorded.
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(glass.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                        .strokeBorder(glass.opacity(0.85), lineWidth: size * 0.035))
                .frame(width: size * 0.60, height: size * 0.40)
                .offset(y: -size * 0.045)

            // You, in the corner of it, recording.
            Circle()
                .fill(live)
                .overlay(Circle().strokeBorder(.white.opacity(0.92), lineWidth: size * 0.032))
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.19, y: size * 0.19)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
enum IconMaker {
    static let sizes: [(name: String, px: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func write(to dir: String) {
        let set = "\(dir)/AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        for (name, px) in sizes {
            let renderer = ImageRenderer(content: AppIconArt(size: px))
            renderer.scale = 1
            guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(set)/\(name).png"))
        }
        print("wrote \(set)")
    }
}
