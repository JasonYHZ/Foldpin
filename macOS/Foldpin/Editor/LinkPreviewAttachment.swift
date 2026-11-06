import AppKit

@MainActor
enum LinkPreviewAttachment {
    private static let thumbnails: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.totalCostLimit = 12 * 1024 * 1024; cache.countLimit = 64
        return cache
    }()

    private static func thumbnail(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let cached = thumbnails.object(forKey: data as NSData) { return cached }
        guard let cg = LinkPreviewThumbnail.image(data) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails.setObject(image, forKey: data as NSData, cost: cg.width * cg.height * 4)
        return image
    }

    static func make(_ preview: NoteLinkPreview, width: CGFloat, color: NSColor) -> NSTextAttachment {
        // Reserve the same height while metadata/images load; no text jumps.
        let size = NSSize(width: max(80, width - 2), height: 184)
        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(origin: .zero, size: size)
        let cover = thumbnail(preview.thumbnail)
        let detail = preview.summary.isEmpty
            ? (preview.state == .unavailable ? String(localized: "Preview unavailable. You can still open this link.", bundle: LanguageSettings.shared.bundle) : "")
            : preview.summary
        attachment.image = NSImage(size: size, flipped: true) { rect in
            let card = rect.insetBy(dx: 1, dy: 4)
            let box = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
            color.withAlphaComponent(0.025).setFill(); box.fill()
            var left: CGFloat = 15
            if let cover {
                let imageWidth = min(220, max(70, rect.width * 0.28))
                let imageRect = NSRect(x: card.minX, y: card.minY, width: imageWidth, height: card.height)
                // Center-crop the site's cover, like a bookmark thumbnail.
                let scale = max(imageRect.width / cover.size.width, imageRect.height / cover.size.height)
                let cropSize = NSSize(width: imageRect.width / scale, height: imageRect.height / scale)
                let source = NSRect(x: (cover.size.width - cropSize.width) / 2, y: (cover.size.height - cropSize.height) / 2,
                                    width: cropSize.width, height: cropSize.height)
                NSGraphicsContext.saveGraphicsState(); box.addClip()
                cover.draw(in: imageRect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                left = imageRect.maxX + 15
            }
            color.withAlphaComponent(0.15).setStroke(); box.lineWidth = 1; box.stroke()
            let available = max(20, rect.width - left - 15)
            let single = NSMutableParagraphStyle(); single.lineBreakMode = .byTruncatingTail
            let wrap = NSMutableParagraphStyle(); wrap.lineBreakMode = .byWordWrapping
            let urlStyle = NSMutableParagraphStyle(); urlStyle.lineBreakMode = .byCharWrapping
            let site = preview.siteName.isEmpty ? preview.host : preview.siteName
            NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color.withAlphaComponent(0.55)]))?
                .draw(in: NSRect(x: left, y: 17, width: 12, height: 12))
            (site as NSString).draw(in: NSRect(x: left + 18, y: 15, width: max(20, available - 18), height: 17),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: color.withAlphaComponent(0.6), .paragraphStyle: single])
            (preview.displayTitle as NSString).draw(with: NSRect(x: left, y: 39, width: available, height: 35),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color, .paragraphStyle: wrap])
            (detail as NSString).draw(with: NSRect(x: left, y: 81, width: available, height: 34),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color.withAlphaComponent(0.7), .paragraphStyle: wrap])
            // Show the actual destination, including its path, rather than a
            // hostname-only label. The native tooltip retains the entire URL.
            (preview.url as NSString).draw(with: NSRect(x: left, y: 135, width: available, height: 33),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color.withAlphaComponent(0.56), .paragraphStyle: urlStyle])
            return true
        }
        attachment.image?.accessibilityDescription = preview.displayTitle + ". " + preview.summary + ". " + preview.url
        return attachment
    }
}
