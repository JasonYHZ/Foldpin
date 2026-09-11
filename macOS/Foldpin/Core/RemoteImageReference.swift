import Foundation

nonisolated enum RemoteImageState: String, Codable, Sendable { case pending, failed }

nonisolated enum RemoteImageReference {
    static func downloadURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func linkURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        if let url = downloadURL(value) { return url }
        if let url = URL(string: value), url.scheme?.lowercased() == "mailto", !url.path.isEmpty { return url }
        return nil
    }
}
