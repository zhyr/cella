import SwiftUI
import AppKit

/// NSVisualEffectView wrapped for SwiftUI, used for the panel's translucent
/// backdrop material.
///
/// The blur is rounded with `maskImage`, not by clipping the layer.
///
/// A `behindWindow` effect is composited by the window server from the pixels
/// *behind* the window, so it ignores layer clipping (`cornerRadius` /
/// `masksToBounds`) and keeps painting across the view's full rectangular
/// bounds. On a rounded, borderless panel that leaves a blurred wedge in every
/// corner — and because AppKit derives the window shadow from the content's
/// alpha, the shadow follows the square bounds too, which is what turns the
/// wedge into a hard edged triangle. Masking the effect itself is the only way
/// to round it.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat
    /// Bounds the mask has to cover. The panel is fixed-size, so the mask can
    /// be drawn at full size once — nothing gets stretched, nothing misaligns.
    let maskSize: CGSize

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        v.maskImage = Self.maskImage(size: maskSize, cornerRadius: cornerRadius)
        return v
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context _: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }

    /// Renders the very same rounded rectangle the panel is clipped with —
    /// SwiftUI's continuous corner included — so the blur ends exactly where the
    /// content does.
    private static func maskImage(size: CGSize, cornerRadius: CGFloat) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        // Draw at 2× so the arcs stay crisp on Retina displays; the image's
        // logical size stays in points, which is what `maskImage` stretches to.
        let scale: CGFloat = 2
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(
            Path(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: cornerRadius,
                style: .continuous
            ).cgPath
        )
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
