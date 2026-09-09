import AppKit

/// Display geometry is independent of the asset pixels. Resizing never rewrites files.
@MainActor
struct ImageBlockLayout {
    let imageSize: NSSize
    let captionRect: NSRect?
    var size: NSSize { NSSize(width: imageSize.width, height: imageSize.height + (captionRect == nil ? 0 : 28)) }

    init(image: NoteImage, availableWidth: CGFloat) {
        let available = max(40, availableWidth)
        let ratio = CGFloat(max(1, image.pixelHeight)) / CGFloat(max(1, image.pixelWidth))
        let width = min(available, CGFloat(image.displayWidth ?? Double(image.pixelWidth)), 600 / ratio)
        imageSize = NSSize(width: max(1, width), height: max(1, width * ratio))
        captionRect = image.caption == nil ? nil : NSRect(x: 0, y: imageSize.height + 6, width: imageSize.width, height: 22)
    }

    func renderedImage(_ original: NSImage?, asset: NoteImage, ink: NSColor) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            let target = NSRect(origin: .zero, size: imageSize)
            (original ?? NSImage(systemSymbolName: "photo", accessibilityDescription: asset.name))?
                .draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if let rect = captionRect, let caption = asset.caption {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                let placeholder = String(localized: "Image caption", bundle: LanguageSettings.shared.bundle)
                (caption.isEmpty ? placeholder : caption).draw(in: rect, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: caption.isEmpty ? NotePalette.placeholderText(for: ink) : NotePalette.secondaryText(for: ink), .paragraphStyle: style
                ])
            }
            return true
        }
    }
}
