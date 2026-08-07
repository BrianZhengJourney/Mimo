// sources: openai_health.swift

import Foundation

@main
struct OpenAIHealthTests {
    static func main() {
        precondition(OpenAIHealthClassifier.status(httpStatus: 200) == .usable)
        precondition(OpenAIHealthClassifier.status(httpStatus: 401) == .authorization)
        precondition(OpenAIHealthClassifier.status(httpStatus: 403) == .authorization)
        precondition(OpenAIHealthClassifier.status(httpStatus: 429) == .quota)
        precondition(OpenAIHealthClassifier.status(httpStatus: 503) == .service)
        precondition(OpenAIHealthClassifier.status(error: URLError(.timedOut)) == .network)
        precondition(OpenAIHealthClassifier.status(error: URLError(.notConnectedToInternet)) == .network)
        print("openai health tests passed")
    }
}
