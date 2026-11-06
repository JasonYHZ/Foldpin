import Foundation
import CoreFoundation

/// Fetch page metadata and one bounded cover image: no cookies, credentials, JavaScript or third-party
/// preview service. A bounded response cannot turn a paste into a large download.
nonisolated enum LinkPreviewFetcher {
    static let maximumBytes = 1_048_576
    enum Failure: Error { case invalidURL, response, tooLarge, encoding }

    static func fetch(_ url: URL) async throws -> NoteLinkPreview {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return try await fetch(url, configuration: configuration)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration) async throws -> NoteLinkPreview {
        guard RemoteImageReference.downloadURL(url.absoluteString) != nil else { throw Failure.invalidURL }
        let session = URLSession(configuration: configuration, delegate: LinkPreviewRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { throw Failure.response }
        guard response.expectedContentLength <= maximumBytes else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count % 8192 == 0 { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw Failure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        // Prefer the declared HTTP charset, then a short HTML charset hint.
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        let hint = captures(#"(?i)charset\s*=\s*[\"']?\s*([a-z0-9_-]+)"#, in: prefix).first?.first
        let charset = response.textEncodingName ?? hint
        let encoding = charset.flatMap { name -> String.Encoding? in
            let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard value != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        }
        guard let html = encoding.flatMap({ String(data: data, encoding: $0) })
            ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw Failure.encoding }
        var preview = parse(html, url: url, baseURL: response.url)
        if let imageURL = preview.imageURL.flatMap(URL.init(string:)) {
            do { preview.thumbnail = try await fetchThumbnail(imageURL, session: session) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Text and the original link remain useful without an image. */ }
        }
        try Task.checkCancellation()
        return preview
    }

    static func parse(_ html: String, url: URL, baseURL: URL? = nil) -> NoteLinkPreview {
        // Ignore fake tags in comments/script/style. Never interpret HTML as a
        // view or let the parser resolve external entities/resources.
        let source = String(html.prefix(maximumBytes))
            .replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        var meta: [String: String] = [:]
        for tag in captures(#"(?is)(<meta\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>)"#, in: source).prefix(1024) {
            var attributes: [String: String] = [:]
            for pair in captures(#"(?is)([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#, in: tag[0]) {
                attributes[pair[0].lowercased()] = pair.dropFirst().first { !$0.isEmpty } ?? ""
            }
            let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
            if meta[key] == nil, let value = attributes["content"], !value.isEmpty { meta[key] = value }
        }
        let title = meta["og:title"] ?? meta["twitter:title"]
            ?? captures(#"(?is)<title\b[^>]*>(.*?)</title\s*>"#, in: source).first?.first ?? ""
        let rawImage = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]
        let imageURL = rawImage.flatMap { value -> URL? in
            let decoded = clean(value, limit: 8192)
            guard let resolved = URL(string: decoded, relativeTo: baseURL ?? url)?.absoluteURL,
                  let valid = RemoteImageReference.downloadURL(resolved.absoluteString),
                  (baseURL ?? url).scheme?.lowercased() != "https" || valid.scheme?.lowercased() == "https" else { return nil }
            return valid
        }
        return NoteLinkPreview(url: url.absoluteString, title: clean(title, limit: 512),
            summary: clean(meta["og:description"] ?? meta["description"] ?? meta["twitter:description"] ?? "", limit: 1200),
            siteName: clean(meta["og:site_name"] ?? "", limit: 200), state: .loaded, imageURL: imageURL?.absoluteString)
    }

    private static func fetchThumbnail(_ url: URL, session: URLSession) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true else { throw Failure.response }
        guard response.expectedContentLength <= LinkPreviewThumbnail.maximumDownloadBytes else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count % 8192 == 0 { try Task.checkCancellation() }
            guard data.count < LinkPreviewThumbnail.maximumDownloadBytes else { throw Failure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return LinkPreviewThumbnail.prepare(data)
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    private static func clean(_ value: String, limit: Int) -> String {
        var text = value.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        let entities = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                        "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®", "trade": "™",
                        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]
        if let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) {
            let original = text as NSString
            let output = NSMutableString(string: text)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
                let entity = original.substring(with: match.range(at: 1))
                let number = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16) : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
                let replacement = number.flatMap(Unicode.Scalar.init).map(String.init) ?? entities[entity]
                if let replacement { output.replaceCharacters(in: match.range, with: replacement) }
            }
            text = output as String
        }
        return String(text.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }).joined(separator: " ").prefix(limit))
    }
}

nonisolated private final class LinkPreviewRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, RemoteImageReference.downloadURL(url.absoluteString) != nil,
              response.url?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}
