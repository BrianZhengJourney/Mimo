// Mimo — bounded, sequential delivery for multi-photo reference imports.

import Foundation

enum PetReferenceImportPolicy {
    static let maximumReferences = 8
    static let maximumDownloadBytes = 20 * 1024 * 1024

    static func selectionLimit(reportedRemaining: Int?) -> Int {
        max(0, min(maximumReferences,
                   reportedRemaining ?? maximumReferences))
    }

    /// The Settings page is trusted, but a dragged webpage can put arbitrary
    /// text on the pasteboard. Keep web imports on public HTTPS URLs and never
    /// reinterpret a dropped `file:` URL as permission to read local data.
    static func remoteImageURL(from rawValue: String) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
              components.port == nil || components.port == 443 else { return nil }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let blockedNames = ["localhost", "local", "lan", "internal", "home", "home.arpa"]
        guard !blockedNames.contains(host),
              !blockedNames.contains(where: { host.hasSuffix(".\($0)") }),
              !host.contains(":"), // reject every IPv6 literal, public or private
              !isIPv4Literal(host) else { return nil }

        components.scheme = "https"
        components.host = host
        components.fragment = nil
        return components.url
    }

    static func acceptsResponseContentType(_ value: String?) -> Bool {
        guard let value else { return true }
        let mime = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return mime.hasPrefix("image/")
            || mime == "application/octet-stream"
            || mime == "binary/octet-stream"
    }

    static func displayName(for url: URL) -> String {
        let decoded = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let stem = (decoded as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = String(stem.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        return clean.isEmpty ? "网页图片" : String(clean.prefix(60))
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        return pieces.allSatisfy { piece in
            guard !piece.isEmpty, piece.count <= 3,
                  piece.allSatisfy(\.isNumber), let value = Int(piece) else { return false }
            return (0...255).contains(value)
        }
    }
}

enum PetRemoteReferenceDownloadError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case unsupportedContent
    case tooLarge
    case empty
    case cancelled
    case network
}

/// Downloads one explicitly dropped web image without cookies, cache, or
/// referrer. A data delegate enforces the byte cap while bytes arrive instead
/// of letting URLSession accumulate an unbounded response first.
final class PetRemoteReferenceDownloader: NSObject,
        URLSessionDataDelegate, URLSessionTaskDelegate {
    typealias Completion = (Result<Data, PetRemoteReferenceDownloadError>) -> Void

    private let maximumBytes: Int
    private var completion: Completion?
    private var received = Data()
    private var task: URLSessionDataTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpAdditionalHeaders = [
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"
        ]
        return URLSession(configuration: configuration,
                          delegate: self,
                          delegateQueue: nil)
    }()

    init(maximumBytes: Int = PetReferenceImportPolicy.maximumDownloadBytes,
         completion: @escaping Completion) {
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    func start(_ url: URL) {
        guard task == nil,
              let safeURL = PetReferenceImportPolicy.remoteImageURL(
                from: url.absoluteString) else {
            finish(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: safeURL)
        request.httpMethod = "GET"
        request.setValue(nil, forHTTPHeaderField: "Referer")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        let next = session.dataTask(with: request)
        task = next
        next.resume()
    }

    func cancel() {
        task?.cancel()
        finish(.failure(.cancelled))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              PetReferenceImportPolicy.remoteImageURL(
                from: url.absoluteString) != nil else {
            completionHandler(nil)
            finish(.failure(.invalidURL))
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Referer")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              PetReferenceImportPolicy.remoteImageURL(
                from: finalURL.absoluteString) != nil else {
            completionHandler(.cancel)
            finish(.failure(.invalidResponse))
            return
        }
        guard PetReferenceImportPolicy.acceptsResponseContentType(
                http.value(forHTTPHeaderField: "Content-Type")) else {
            completionHandler(.cancel)
            finish(.failure(.unsupportedContent))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(.tooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard completion != nil else { return }
        guard received.count <= maximumBytes - data.count else {
            dataTask.cancel()
            finish(.failure(.tooLarge))
            return
        }
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard completion != nil else { return }
        if error != nil {
            finish(.failure(.network))
        } else if received.isEmpty {
            finish(.failure(.empty))
        } else {
            finish(.success(received))
        }
    }

    private func finish(_ result: Result<Data, PetRemoteReferenceDownloadError>) {
        guard let completion else { return }
        self.completion = nil
        self.task = nil
        completion(result)
        session.finishTasksAndInvalidate()
    }
}

/// Runs one asynchronous delivery at a time. WKWebView can drop or reject
/// bursts of large evaluateJavaScript payloads, so reference data URIs must
/// cross the native-to-web bridge sequentially.
final class PetReferenceImportQueue<Item> {
    typealias Delivery = (Item, @escaping () -> Void) -> Void

    private let items: [Item]
    private let delivery: Delivery
    private let completion: () -> Void
    private var index = 0
    private var started = false

    init(items: [Item], delivery: @escaping Delivery,
         completion: @escaping () -> Void = {}) {
        self.items = items
        self.delivery = delivery
        self.completion = completion
    }

    func start() {
        guard !started else { return }
        started = true
        deliverNext()
    }

    private func deliverNext() {
        guard index < items.count else {
            completion()
            return
        }
        let item = items[index]
        index += 1
        delivery(item) { [weak self] in
            self?.deliverNext()
        }
    }
}
