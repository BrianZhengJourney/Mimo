// Mimo Today Journal — optional AI enrichment boundary.
//
// Raw activity stays local until the user explicitly confirms one request.
// The adapter sends bounded metadata only, scrubs URLs, disables provider
// storage, and rejects every statement that does not cite a supplied event ID.

import Foundation

struct ReflectionModelInput: Equatable {
    var snapshot: DailyActivitySnapshot
    var prompt: String?

    init(snapshot: DailyActivitySnapshot, prompt: String? = nil) {
        self.snapshot = snapshot
        self.prompt = prompt
    }
}

protocol ReflectionModel {
    func synthesize(_ input: ReflectionModelInput) async throws -> DailyReflection
}

struct LocalReflectionModel: ReflectionModel {
    func synthesize(_ input: ReflectionModelInput) async throws -> DailyReflection {
        LocalActivityReflector.build(snapshot: input.snapshot)
    }
}

protocol ReflectionModelTransport {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class EphemeralReflectionModelTransport: ReflectionModelTransport {
    private let session: URLSession

    init(requestTimeout: TimeInterval = 45, resourceTimeout: TimeInterval = 90) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ReflectionModelError.invalidResponse
        }
        return (data, response)
    }
}

enum ReflectionModelError: Error, Equatable, LocalizedError {
    case missingKey
    case noActivity
    case payloadTooLarge
    case network
    case service(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add an OpenAI API key in Settings to enrich the local daily summary."
        case .noActivity: return "There is no activity in this range to summarize."
        case .payloadTooLarge: return "This range is too large. Choose a smaller range."
        case .network: return "Mimo could not reach the model service. Your local trail is unchanged."
        case .service(let status): return "The model service returned HTTP \(status)."
        case .invalidResponse: return "The model response was not grounded in the selected activity."
        }
    }
}

final class OpenAIReflectionModel: ReflectionModel {
    static let defaultModel = "gpt-5.6"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let model: String
    private let keyReader: () -> String?
    private let transport: ReflectionModelTransport
    private let maximumEventCount: Int
    private let maximumBodyBytes: Int
    private let maximumResponseBytes: Int

    init(model: String = OpenAIReflectionModel.defaultModel,
         keyReader: @escaping () -> String?,
         transport: ReflectionModelTransport = EphemeralReflectionModelTransport(),
         maximumEventCount: Int = 240,
         maximumBodyBytes: Int = 128 * 1_024,
         maximumResponseBytes: Int = 512 * 1_024) {
        self.model = model
        self.keyReader = keyReader
        self.transport = transport
        self.maximumEventCount = max(1, maximumEventCount)
        self.maximumBodyBytes = max(4_096, maximumBodyBytes)
        self.maximumResponseBytes = max(4_096, maximumResponseBytes)
    }

    func synthesize(_ input: ReflectionModelInput) async throws -> DailyReflection {
        guard let key = keyReader()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.utf8.count <= 4_096,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ReflectionModelError.missingKey
        }
        guard !input.snapshot.events.isEmpty else { throw ReflectionModelError.noActivity }
        guard input.snapshot.events.count <= maximumEventCount else {
            throw ReflectionModelError.payloadTooLarge
        }

        let body = try requestBody(input)
        guard body.count <= maximumBodyBytes else { throw ReflectionModelError.payloadTooLarge }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.execute(request) }
        catch let error as ReflectionModelError { throw error }
        catch { throw ReflectionModelError.network }
        guard (200..<300).contains(response.statusCode) else {
            throw ReflectionModelError.service(status: response.statusCode)
        }
        guard data.count <= maximumResponseBytes else { throw ReflectionModelError.invalidResponse }
        return try parseResponse(data, snapshot: input.snapshot)
    }

    private func requestBody(_ input: ReflectionModelInput) throws -> Data {
        let sectionKinds = DailyReflectionSectionKind.allCases.map(\.rawValue).joined(separator: ", ")
        let systemPrompt = """
        You are Mimo's evidence-grounded daily activity analyst. Return one JSON object only, with no Markdown fences. Use this exact schema:
        {"headline":string,"summary":string,"sections":[{"kind":string,"statements":[{"text":string,"claimKind":"fact"|"inference","evidenceIDs":[string,...]}]}],"materialSummaries":[{"materialID":string,"overview":string,"keyIdeas":[string,...],"relevance":string|null,"evidenceIDs":[string,...]}]}

        Include exactly these section kinds, once each and in order: \(sectionKinds).
        Every statement must cite one or more supplied raw event IDs. Facts describe only observed metadata. Inferences must be phrased with appropriate uncertainty. Never claim a task was completed merely because an app or page was open. For every supplied learning material, return exactly one material summary with the same materialID. Summarize only what the supplied title, source, URL metadata, and activity context support; if content is insufficient, say so instead of inventing key ideas. Keep the result concise and useful for end-of-day review.
        """
        let snapshot = input.snapshot
        let object: [String: Any] = [
            "range": [
                "startMS": snapshot.range.start.timeIntervalSince1970 * 1_000,
                "endMS": snapshot.range.end.timeIntervalSince1970 * 1_000,
            ],
            "metrics": [
                "activeMinutes": Int((snapshot.activeDurationMS / 60_000).rounded()),
                "focusMinutes": Int((snapshot.focusDurationMS / 60_000).rounded()),
                "contextSwitches": snapshot.contextSwitchCount,
            ],
            "events": snapshot.events.map(eventObject),
            "activityBlocks": snapshot.blocks.map(blockObject),
            "learningMaterials": snapshot.materials.map(materialObject),
            "question": bounded(SensitiveURLScrubber.scrubURLs(
                in: input.prompt ?? "Summarize this activity range."), count: 2_000),
        ]
        let userData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let userText = String(data: userData, encoding: .utf8) else {
            throw ReflectionModelError.invalidResponse
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 6_000,
            "reasoning": ["effort": "low"],
            "text": ["format": ["type": "json_object"]],
            "input": [
                ["role": "system", "content": [["type": "input_text", "text": systemPrompt]]],
                ["role": "user", "content": [["type": "input_text", "text": userText]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private struct ModelOutput: Decodable {
        var headline: String
        var summary: String
        var sections: [ModelSection]
        var materialSummaries: [ModelMaterial]
    }

    private struct ModelSection: Decodable {
        var kind: DailyReflectionSectionKind
        var statements: [GroundedReflectionStatement]
    }

    private struct ModelMaterial: Decodable {
        var materialID: String
        var overview: String
        var keyIdeas: [String]
        var relevance: String?
        var evidenceIDs: [String]
    }

    private func parseResponse(_ data: Data, snapshot: DailyActivitySnapshot) throws -> DailyReflection {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw ReflectionModelError.invalidResponse
        }
        var candidates: [String] = []
        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { candidates.append(text) }
            }
        }
        let scans = candidates + (candidates.count > 1 ? [candidates.joined()] : [])
        let decoder = JSONDecoder()
        for candidate in scans where candidate.utf8.count <= maximumResponseBytes {
            guard let candidateData = candidate.data(using: .utf8),
                  let decoded = try? decoder.decode(ModelOutput.self, from: candidateData),
                  valid(decoded, snapshot: snapshot) else { continue }
            return .init(
                headline: bounded(decoded.headline, count: 180),
                summary: bounded(decoded.summary, count: 1_000),
                sections: decoded.sections.map { section in
                    .init(kind: section.kind, statements: section.statements.map { statement in
                        .init(text: bounded(statement.text, count: 1_200),
                              claimKind: statement.claimKind,
                              evidenceIDs: unique(statement.evidenceIDs))
                    })
                },
                materialSummaries: decoded.materialSummaries.map { material in
                    .init(materialID: material.materialID,
                          overview: bounded(material.overview, count: 1_500),
                          keyIdeas: material.keyIdeas.prefix(5).map { bounded($0, count: 500) },
                          relevance: material.relevance.map { bounded($0, count: 800) },
                          evidenceIDs: unique(material.evidenceIDs), isAIEnhanced: true)
                }, isAIEnhanced: true)
        }
        throw ReflectionModelError.invalidResponse
    }

    private func valid(_ output: ModelOutput, snapshot: DailyActivitySnapshot) -> Bool {
        guard !output.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !output.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.sections.map(\.kind) == DailyReflectionSectionKind.allCases else { return false }
        let allowed = Set(snapshot.events.map(\.id))
        for section in output.sections {
            for statement in section.statements {
                guard !statement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !statement.evidenceIDs.isEmpty,
                      statement.evidenceIDs.allSatisfy(allowed.contains) else { return false }
            }
        }
        let expectedMaterials = Set(snapshot.materials.map(\.id))
        guard Set(output.materialSummaries.map(\.materialID)) == expectedMaterials,
              output.materialSummaries.count == expectedMaterials.count else { return false }
        let materials = Dictionary(uniqueKeysWithValues: snapshot.materials.map { ($0.id, $0) })
        for summary in output.materialSummaries {
            guard let material = materials[summary.materialID],
                  !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !summary.evidenceIDs.isEmpty,
                  Set(summary.evidenceIDs).isSubset(of: Set(material.eventIDs)) else { return false }
        }
        return true
    }

    private func eventObject(_ event: ActivityEvent) -> [String: Any] {
        var output: [String: Any] = [
            "id": event.id, "startMS": event.startedAtMS, "endMS": event.endedAtMS,
            "durationSeconds": event.durationMS / 1_000, "app": bounded(event.app, count: 200),
            "title": bounded(event.displayTitle, count: 500),
            "category": ActivityCategory.classify(event).rawValue,
            "rawCategory": bounded(event.category, count: 100),
            "revisit": event.isRevisit, "contextSwitch": event.isContextSwitch,
        ]
        if let domain = event.domain { output["domain"] = bounded(domain, count: 300) }
        if let url = event.fullURL { output["url"] = bounded(SensitiveURLScrubber.scrub(url), count: 2_000) }
        return output
    }

    private func blockObject(_ block: ActivityBlock) -> [String: Any] {
        ["id": block.id, "title": bounded(block.title, count: 500),
         "category": block.category.rawValue, "startMS": block.startedAtMS,
         "endMS": block.endedAtMS, "activeMinutes": Int((block.activeDurationMS / 60_000).rounded()),
         "apps": block.apps.prefix(12).map { bounded($0, count: 200) },
         "eventIDs": block.eventIDs]
    }

    private func materialObject(_ material: LearningMaterial) -> [String: Any] {
        var output: [String: Any] = [
            "id": material.id, "title": bounded(material.title, count: 700),
            "kind": material.kind.rawValue,
            "activeMinutes": Int((material.durationMS / 60_000).rounded()),
            "visits": material.encounterCount, "eventIDs": material.eventIDs,
        ]
        if let domain = material.domain { output["domain"] = bounded(domain, count: 300) }
        if let url = material.url { output["url"] = bounded(SensitiveURLScrubber.scrub(url), count: 2_000) }
        return output
    }

    private func bounded(_ value: String, count: Int) -> String {
        String(value.prefix(max(0, count)))
    }

    private func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { output, value in
            if !value.isEmpty && !output.contains(value) { output.append(value) }
        }
    }
}
