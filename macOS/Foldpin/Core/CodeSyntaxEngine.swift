import Foundation
import JavaScriptCore
import OSLog

nonisolated struct CodeSyntaxSpan: Sendable {
    let range: NSRange
    let scope: String
    let language: CodeLanguage
}

nonisolated struct CodeSyntaxAnalysis: Sendable {
    var language: CodeLanguage = .plain
    var spans: [CodeSyntaxSpan] = []
}

/// One lazy JavaScriptCore context for the application. All JS access is confined
/// to `queue`; NSCache is thread-safe. Neither JS objects nor AppKit objects cross
/// that queue. The editor uses cached results and asynchronous requests only.
nonisolated final class CodeSyntaxEngine: @unchecked Sendable {
    static let shared = CodeSyntaxEngine()
    static let maximumSourceLength = 24_000
    static let maximumSampleLength = 8_192
    private final class Cached: NSObject {
        let analysis: CodeSyntaxAnalysis
        init(_ analysis: CodeSyntaxAnalysis) { self.analysis = analysis }
    }
    private final class Detected: NSObject {
        let language: CodeLanguage
        init(_ language: CodeLanguage) { self.language = language }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    private let queue = DispatchQueue(label: "dev.jasonyu.foldpin.syntax", qos: .userInitiated)
    private let cache = NSCache<NSString, Cached>()
    private let detections = NSCache<NSString, Detected>()
    private var context: JSContext?
    private var didLoad = false
    private let logger = Logger(subsystem: "dev.jasonyu.Foldpin", category: "Syntax")

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1_024 * 1_024
        detections.countLimit = 128
        detections.totalCostLimit = 2 * 1_024 * 1_024
    }

    func cached(_ source: String, language: CodeLanguage) -> CodeSyntaxAnalysis? {
        guard language != .plain, !source.isEmpty else { return CodeSyntaxAnalysis() }
        // The drawing budget must not disable language detection. Avoid caching
        // entire oversized blocks when only their bounded sample is needed.
        if source.utf16.count >= Self.maximumSourceLength {
            let detected = language == .automatic ? cachedLanguage(source) : language
            return detected.map { CodeSyntaxAnalysis(language: $0) }
        }
        return cache.object(forKey: key(source, language))?.analysis
    }

    func analyze(_ source: String, language: CodeLanguage) async -> CodeSyntaxAnalysis {
        if let value = cached(source, language: language) { return value }
        return await enqueue(cancelledValue: CodeSyntaxAnalysis()) { cancellation in
            self.parse(source, language: language, cancellation: cancellation)
        }
    }

    func cachedLanguage(_ source: String) -> CodeLanguage? {
        if source.isEmpty { return .plain }
        if source.utf16.count < Self.maximumSourceLength,
           let analysis = cache.object(forKey: key(source, .automatic))?.analysis { return analysis.language }
        return detections.object(forKey: sample(source))?.language
    }

    func detectLanguage(_ source: String) async -> CodeLanguage {
        if let language = cachedLanguage(source) { return language }
        return await enqueue(cancelledValue: CodeLanguage.plain) { _ in self.detect(source) }
    }

    func detectLanguageSynchronously(_ source: String) -> CodeLanguage {
        if let language = cachedLanguage(source) { return language }
        return queue.sync { detect(source) }
    }

    private func enqueue<Value: Sendable>(cancelledValue: Value,
                                         operation: @escaping @Sendable (Cancellation) -> Value) async -> Value {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    // Cancelling a Swift Task does not cancel a Dispatch job.
                    // Drop obsolete queued work before entering JavaScriptCore.
                    let value = cancellation.isCancelled ? cancelledValue : operation(cancellation)
                    continuation.resume(returning: value)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    // For noninteractive codec clients. Never
    // call from a live editor or hover/scroll callback; use cached/analyze there.
    func analyzeSynchronously(_ source: String, language: CodeLanguage) -> CodeSyntaxAnalysis {
        if let value = cached(source, language: language) { return value }
        return queue.sync { parse(source, language: language) }
    }

    private func sample(_ source: String) -> NSString {
        let text = source as NSString
        return text.substring(to: min(text.length, Self.maximumSampleLength)) as NSString
    }

    private func key(_ source: String, _ language: CodeLanguage) -> NSString {
        (language.rawValue + ":" + source) as NSString
    }

    private func load() -> JSContext? {
        if didLoad { return context }
        didLoad = true
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let runtime = JSContext() else { return nil }
        // Some upstream recovery paths log diagnostics. Do not export a native
        // logger that could accidentally log the user's source text.
        runtime.evaluateScript("var console = {log:function(){},warn:function(){},error:function(){}};")
        for name in ["highlight", "foldpin-highlight-bridge"] {
            // Xcode's synchronized source group may flatten resource files.
            let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "SyntaxResources")
                ?? bundle.url(forResource: name, withExtension: "js")
            guard let url, let script = try? String(contentsOf: url, encoding: .utf8) else {
                logger.error("Bundled syntax engine resource is missing.")
                return nil
            }
            runtime.evaluateScript(script, withSourceURL: url)
            guard runtime.exception == nil else {
                logger.error("Bundled syntax engine could not initialize.")
                return nil
            }
        }
        context = runtime
        return runtime
    }

    private func detect(_ source: String) -> CodeLanguage {
        if let language = cachedLanguage(source) { return language }
        let sample = sample(source)
        var language = CodeLanguage.plain
        if let runtime = load() {
            runtime.exception = nil
            let result = runtime.objectForKeyedSubscript("foldpinDetect")?.call(withArguments: [
                sample, CodeLanguage.detectionCandidates.map(\.grammarName)
            ])
            if runtime.exception == nil, let name = result?.toString() {
                language = CodeLanguage(grammarName: name) ?? .plain
            } else {
                logger.error("Language detection failed; preserving uncolored source.")
                runtime.exception = nil
            }
        }
        detections.setObject(Detected(language), forKey: sample, cost: sample.length * 2)
        return language
    }

    private func parse(_ source: String, language: CodeLanguage, cancellation: Cancellation? = nil) -> CodeSyntaxAnalysis {
        if let value = cached(source, language: language) { return value }
        let detected = language == .automatic ? detect(source) : language
        var analysis = CodeSyntaxAnalysis(language: detected)
        guard cancellation?.isCancelled != true else { return analysis }
        guard source.utf16.count < Self.maximumSourceLength else { return analysis }
        if let runtime = load() {
            runtime.exception = nil
            let result = runtime.objectForKeyedSubscript("foldpinAnalyze")?.call(withArguments: [
                source, detected.grammarName
            ])
            if runtime.exception == nil, let dictionary = result?.toDictionary(),
               let detected = dictionary["language"] as? String,
               let spans = dictionary["spans"] as? [[Any]] {
                analysis.language = CodeLanguage(grammarName: detected) ?? .plain
                let length = source.utf16.count
                analysis.spans = spans.compactMap { values in
                    guard values.count == 4, let location = values[0] as? Int, let count = values[1] as? Int,
                          let scope = values[2] as? String, let embedded = values[3] as? String,
                          location >= 0, count > 0, location <= length, count <= length - location else { return nil }
                    return CodeSyntaxSpan(range: NSRange(location: location, length: count), scope: scope,
                                          language: CodeLanguage(grammarName: embedded) ?? analysis.language)
                }
            } else {
                logger.error("Syntax analysis failed; preserving uncolored source.")
                runtime.exception = nil
            }
        }
        cache.setObject(Cached(analysis), forKey: key(source, language),
                        cost: source.utf16.count * 2 + analysis.spans.count * 64)
        return analysis
    }
}
