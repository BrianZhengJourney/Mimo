// Mimo — a zero-spend OpenAI connection probe.
//
// A stored credential is not the same thing as a usable connection. This GET
// checks authentication and reachability without submitting a generation.

import Foundation

enum OpenAIHealthStatus: String, Equatable {
    case unchecked
    case checking
    case usable
    case authorization
    case quota
    case network
    case service
}

struct OpenAIHealthSnapshot: Equatable {
    var status: OpenAIHealthStatus = .unchecked
    var checkedAt: Date?
    var httpStatus: Int?
}

enum OpenAIHealthClassifier {
    static func status(httpStatus: Int) -> OpenAIHealthStatus {
        switch httpStatus {
        case 200..<300: return .usable
        case 401, 403: return .authorization
        case 429: return .quota
        default: return .service
        }
    }

    static func status(error: Error) -> OpenAIHealthStatus {
        guard let urlError = error as? URLError else { return .service }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .timedOut,
             .internationalRoamingOff, .dataNotAllowed:
            return .network
        case .cancelled: return .unchecked
        default: return .service
        }
    }
}

final class OpenAIHealthProbe {
    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession? = nil,
         endpoint: URL = URL(string: "https://api.openai.com/v1/models")!) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
    }

    func check(apiKey: String,
               completion: @escaping (OpenAIHealthSnapshot) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { _, response, error in
            let now = Date()
            if let error {
                completion(.init(status: OpenAIHealthClassifier.status(error: error),
                                 checkedAt: now, httpStatus: nil))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.init(status: .service, checkedAt: now, httpStatus: nil))
                return
            }
            completion(.init(status: OpenAIHealthClassifier.status(
                httpStatus: response.statusCode), checkedAt: now,
                httpStatus: response.statusCode))
        }.resume()
    }
}
