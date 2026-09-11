import AppKit
import Foundation
import ImageIO

nonisolated enum RemoteImageImportError: Error { case invalidURL, response, tooLarge, unsafeSVG, invalidSVG }

/// No browser, cookies or cache. Only the image URL is requested, never its link.
nonisolated enum RemoteImageImporter {
    static let maximumBytes = 20 * 1024 * 1024
    static func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        return try await fetch(url, configuration: configuration)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        guard RemoteImageReference.downloadURL(url.absoluteString) != nil else { throw RemoteImageImportError.invalidURL }
        let session = URLSession(configuration: configuration, delegate: ImageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw RemoteImageImportError.response }
        guard response.expectedContentLength <= maximumBytes else { throw RemoteImageImportError.tooLarge }
        var data = Data(); data.reserveCapacity(min(maximumBytes, max(4096, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw RemoteImageImportError.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func prepare(_ data: Data, name: String, directory: URL) async throws -> NoteImage {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 {
            return try await Task.detached(priority: .userInitiated) {
                try NoteImageImporter.prepare(data: data, name: name, directory: directory).image
            }.value
        }
        let size = try SVGImageValidation.size(of: data)
        try Task.checkCancellation()
        let png = try await rasterizeSVG(data, size: size)
        return try await Task.detached(priority: .userInitiated) {
            let prepared = try NoteImageImporter.prepare(data: png, name: name, directory: directory)
            // Keep the original SVG bytes for export; preview/copy uses PNG.
            try data.write(to: directory.appendingPathComponent(prepared.image.id.uuidString + ".original"), options: .atomic)
            var image = prepared.image; image.isSVG = true
            image.displayWidth = min(10000, max(40, size.width))
            return image
        }.value
    }
    @MainActor private static func rasterizeSVG(_ data: Data, size: CGSize) throws -> Data {
        guard let image = NSImage(data: data), image.isValid else { throw RemoteImageImportError.invalidSVG }
        let scale = min(2, 1400 / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RemoteImageImportError.invalidSVG }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RemoteImageImportError.invalidSVG }
        return png
    }
}

nonisolated private final class ImageRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, RemoteImageReference.downloadURL(url.absoluteString) != nil,
              !(response.url?.scheme == "https" && url.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// SVG is accepted only as a self-contained static image. The XML parser never
/// resolves entities, and active/external resources are rejected before AppKit.
nonisolated final class SVGImageValidation: NSObject, XMLParserDelegate {
    private var valid = true, sawRoot = false, elements = 0
    private var dimensions = CGSize.zero
    private var depth = 0
    static func size(of data: Data) throws -> CGSize {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY"),
              !text.localizedCaseInsensitiveContains("<?xml-stylesheet") else { throw RemoteImageImportError.unsafeSVG }
        let delegate = SVGImageValidation(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.sawRoot,
              delegate.dimensions.width > 0, delegate.dimensions.height > 0,
              delegate.dimensions.width <= 10000, delegate.dimensions.height <= 10000,
              delegate.dimensions.width * delegate.dimensions.height <= 16_000_000 else { throw RemoteImageImportError.unsafeSVG }
        return delegate.dimensions
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1; elements += 1
        let allowed: Set<String> = ["svg", "g", "defs", "title", "desc", "rect", "path", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "filter", "feFlood", "feComposite", "feGaussianBlur", "feOffset", "feMerge", "feMergeNode", "feColorMatrix", "feBlend"]
        guard depth < 64, elements <= 10000, allowed.contains(elementName) else { valid = false; parser.abortParsing(); return }
        if !sawRoot {
            guard elementName == "svg" else { valid = false; parser.abortParsing(); return }
            sawRoot = true
            func dimension(_ key: String) -> Double? { attributes[key].flatMap { Double($0.replacingOccurrences(of: "px", with: "")) } }
            if let width = dimension("width"), let height = dimension("height") { dimensions = CGSize(width: width, height: height) }
            else if let viewBox = attributes["viewBox"]?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap({ Double($0) }), viewBox.count == 4 {
                dimensions = CGSize(width: viewBox[2], height: viewBox[3])
            }
        }
        for (name, value) in attributes {
            let name = name.lowercased(), lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("on") || name == "style" || name == "xml:base"
                || ((name == "href" || name.hasSuffix(":href")) && !lower.hasPrefix("#"))
                || value.contains("\\")
                || (lower.range(of: #"url\s*\("#, options: .regularExpression) != nil && lower.range(of: #"^url\(\s*#[a-z0-9_.:-]+\s*\)$"#, options: .regularExpression) == nil) {
                valid = false; parser.abortParsing(); return
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
}
