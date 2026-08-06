// Mimo Today Journal — optional AI enrichment boundary.
//
// Raw activity stays local until the user explicitly confirms one request.
// The adapter sends bounded metadata only, scrubs URLs, disables provider
// storage, and rejects every statement that does not cite a supplied event ID.

import Foundation

struct ReflectionModelInput: Equatable {
    var snapshot: DailyActivitySnapshot
    var prompt: String?
    var focusRange: ReflectionDateRange?

    init(snapshot: DailyActivitySnapshot, prompt: String? = nil,
         focusRange: ReflectionDateRange? = nil) {
        self.snapshot = snapshot
        self.prompt = prompt
        self.focusRange = focusRange
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
    case offline
    case timedOut
    case network
    case authentication
    case accessDenied
    case rateLimited
    case modelUnavailable
    case serviceUnavailable
    case requestRejected(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add an OpenAI API key in Settings to enrich the local daily summary."
        case .noActivity: return "There is no activity in this range to summarize."
        case .payloadTooLarge: return "This range is too large. Choose a smaller range."
        case .offline: return "You appear to be offline. Your local journal is unchanged."
        case .timedOut: return "OpenAI took too long to respond. Try again in a moment."
        case .network: return "Mimo could not reach the model service. Your local trail is unchanged."
        case .authentication: return "OpenAI did not accept this API key. Save it again in Settings."
        case .accessDenied: return "This OpenAI project cannot use the selected model."
        case .rateLimited: return "OpenAI usage or rate limits were reached. Check usage or try later."
        case .modelUnavailable: return "The selected OpenAI model is temporarily unavailable."
        case .serviceUnavailable: return "OpenAI is temporarily unavailable. Try again later."
        case .requestRejected(let status): return "OpenAI rejected this request (HTTP \(status))."
        case .invalidResponse: return "The model response was not grounded in the selected activity."
        }
    }

    func userMessage(isChinese: Bool) -> String {
        guard isChinese else { return errorDescription ?? "Mimo could not build the summary." }
        switch self {
        case .missingKey: return "先在设置里连接 OpenAI；今日手记本身仍可照常使用。"
        case .noActivity: return "这段时间还没有可以整理的活动。"
        case .payloadTooLarge: return "这段记录太丰富，暂时没能整理；原始轨迹不受影响。"
        case .offline: return "现在似乎没有联网。记录都还在，联网后再试就好。"
        case .timedOut: return "OpenAI 响应有点慢，稍后再试一次。"
        case .network: return "暂时没能连到 OpenAI。记录都还在，稍后再试就好。"
        case .authentication: return "OpenAI 没有接受这个 API Key，请在设置里重新保存。"
        case .accessDenied: return "这个 OpenAI 项目暂时没有权限使用当前模型。"
        case .rateLimited: return "OpenAI 的额度或频率已到上限，稍后再试或检查用量。"
        case .modelUnavailable: return "当前 OpenAI 模型暂时不可用，稍后再试。"
        case .serviceUnavailable: return "OpenAI 暂时没有响应，稍后再试。"
        case .requestRejected: return "这次请求没有被 OpenAI 接受，请重试或检查设置。"
        case .invalidResponse: return "这次整理没有足够可靠的证据，所以没有替换本地手记。"
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
        let prepared = try preparedRequest(input)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = prepared.body

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.execute(request) }
        catch let error as ReflectionModelError { throw error }
        catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: throw ReflectionModelError.offline
            case .timedOut: throw ReflectionModelError.timedOut
            default: throw ReflectionModelError.network
            }
        }
        catch { throw ReflectionModelError.network }
        guard (200..<300).contains(response.statusCode) else {
            throw serviceError(status: response.statusCode)
        }
        guard data.count <= maximumResponseBytes else { throw ReflectionModelError.invalidResponse }
        return try parseResponse(data, snapshot: input.snapshot, projection: prepared.projection)
    }

    private struct ModelProjection {
        var events: [ActivityEvent]
        var blocks: [ActivityBlock]
        var materials: [LearningMaterial]

        var evidenceIDs: Set<String> { Set(events.map(\.id)) }
    }

    private struct PreparedRequest {
        var body: Data
        var projection: ModelProjection
    }

    private func preparedRequest(_ input: ReflectionModelInput) throws -> PreparedRequest {
        var eventLimit = min(maximumEventCount, input.snapshot.events.count)
        while true {
            let projection = makeProjection(snapshot: input.snapshot, eventLimit: eventLimit)
            let body = try requestBody(input, projection: projection)
            if body.count <= maximumBodyBytes {
                return .init(body: body, projection: projection)
            }
            guard eventLimit > 24 else { throw ReflectionModelError.payloadTooLarge }
            eventLimit = max(24, eventLimit * 3 / 4)
        }
    }

    private func makeProjection(snapshot: DailyActivitySnapshot,
                                eventLimit: Int) -> ModelProjection {
        let ordered = snapshot.events.sorted {
            $0.startedAtMS == $1.startedAtMS ? $0.order < $1.order : $0.startedAtMS < $1.startedAtMS
        }
        let limit = min(max(1, eventLimit), ordered.count)
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var selected = Set<String>()
        func include(_ event: ActivityEvent?) {
            guard selected.count < limit, let event else { return }
            selected.insert(event.id)
        }

        include(ordered.first)
        include(ordered.last)
        for category in ActivityCategory.allCases {
            include(ordered.filter { ActivityCategory.classify($0) == category }
                .max { $0.durationMS < $1.durationMS })
        }
        let materialLimit = min(24, max(3, limit / 6))
        for material in snapshot.materials.prefix(materialLimit) {
            include(material.eventIDs.compactMap { byID[$0] }.max { $0.durationMS < $1.durationMS })
        }
        if selected.count < limit {
            for slot in 0..<limit {
                let index = min(ordered.count - 1,
                    Int((Double(slot) + 0.5) * Double(ordered.count) / Double(limit)))
                include(ordered[index])
            }
        }
        if selected.count < limit {
            for event in ordered.sorted(by: { $0.durationMS > $1.durationMS }) { include(event) }
        }

        let events = ordered.filter { selected.contains($0.id) }
        let intersectingBlocks = snapshot.blocks.filter {
            !$0.eventIDs.allSatisfy { !selected.contains($0) }
        }
        let blockLimit = min(72, max(12, limit / 2))
        let blocks = sampledBlocks(intersectingBlocks, limit: blockLimit)
        let materials = snapshot.materials.filter {
            !$0.eventIDs.allSatisfy { !selected.contains($0) }
        }.prefix(materialLimit)
        return .init(events: events, blocks: blocks, materials: Array(materials))
    }

    private func sampledBlocks(_ blocks: [ActivityBlock], limit: Int) -> [ActivityBlock] {
        guard blocks.count > limit else { return blocks }
        var selected = Set<String>()
        func include(_ block: ActivityBlock?) {
            guard selected.count < limit, let block else { return }
            selected.insert(block.id)
        }
        include(blocks.first)
        include(blocks.last)
        for block in blocks.sorted(by: { $0.activeDurationMS > $1.activeDurationMS }) {
            if selected.count >= max(2, limit / 2) { break }
            include(block)
        }
        for slot in 0..<limit {
            let index = min(blocks.count - 1,
                Int((Double(slot) + 0.5) * Double(blocks.count) / Double(limit)))
            include(blocks[index])
        }
        return blocks.filter { selected.contains($0.id) }
    }

    private func requestBody(_ input: ReflectionModelInput,
                             projection: ModelProjection) throws -> Data {
        let sectionKinds = DailyReflectionSectionKind.allCases.map(\.rawValue).joined(separator: ", ")
        let systemPrompt = """
        You are the quiet editor of a personal day journal. Return one JSON object only, with no Markdown fences. Use this exact schema:
        {"headline":string,"summary":string,"sections":[{"kind":string,"statements":[{"text":string,"claimKind":"fact"|"inference","evidenceIDs":[string,...]}]}],"materialSummaries":[{"materialID":string,"overview":string,"keyIdeas":[string,...],"relevance":string|null,"evidenceIDs":[string,...]}]}

        Include exactly these section kinds, once each and in order: \(sectionKinds).
        Every statement must cite one or more supplied raw event IDs. Facts describe only observed metadata. Inferences must be phrased with appropriate uncertainty. Never claim a task was completed merely because an app or page was open. For every supplied learning material, return exactly one material summary with the same materialID. Summarize only what the supplied title, source, URL metadata, and activity context support; if content is insufficient, say so instead of inventing key ideas. Match the language of the user's question. Write like a thoughtful human looking back at a day: warm, plain, specific, and concise. Avoid productivity-dashboard jargon, generic coaching, slogans, and repeated statistics.
        """
        let snapshot = input.snapshot
        var object: [String: Any] = [
            "range": [
                "startMS": snapshot.range.start.timeIntervalSince1970 * 1_000,
                "endMS": snapshot.range.end.timeIntervalSince1970 * 1_000,
            ],
            "metrics": [
                "activeMinutes": Int((snapshot.activeDurationMS / 60_000).rounded()),
                "focusMinutes": Int((snapshot.focusDurationMS / 60_000).rounded()),
                "contextSwitches": snapshot.contextSwitchCount,
            ],
            "events": projection.events.map(eventObject),
            "activityBlocks": projection.blocks.map {
                blockObject($0, evidenceIDs: projection.evidenceIDs)
            },
            "learningMaterials": projection.materials.map {
                materialObject($0, evidenceIDs: projection.evidenceIDs)
            },
            "question": bounded(SensitiveURLScrubber.scrubURLs(
                in: input.prompt ?? "Summarize this activity range."), count: 2_000),
        ]
        if let focus = input.focusRange {
            object["focusWindow"] = [
                "startMS": focus.start.timeIntervalSince1970 * 1_000,
                "endMS": focus.end.timeIntervalSince1970 * 1_000,
            ]
        }
        let userData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let userText = String(data: userData, encoding: .utf8) else {
            throw ReflectionModelError.invalidResponse
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 6_000,
            "reasoning": ["effort": "low"],
            "text": ["format": structuredOutputFormat()],
            "input": [
                ["role": "system", "content": [["type": "input_text", "text": systemPrompt]]],
                ["role": "user", "content": [["type": "input_text", "text": userText]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func structuredOutputFormat() -> [String: Any] {
        let statement: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "claimKind": ["type": "string", "enum": ["fact", "inference"]],
                "evidenceIDs": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["text", "claimKind", "evidenceIDs"],
            "additionalProperties": false,
        ]
        let section: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string",
                         "enum": DailyReflectionSectionKind.allCases.map(\.rawValue)],
                "statements": ["type": "array", "items": statement],
            ],
            "required": ["kind", "statements"],
            "additionalProperties": false,
        ]
        let material: [String: Any] = [
            "type": "object",
            "properties": [
                "materialID": ["type": "string"],
                "overview": ["type": "string"],
                "keyIdeas": ["type": "array", "items": ["type": "string"]],
                "relevance": ["type": ["string", "null"]],
                "evidenceIDs": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["materialID", "overview", "keyIdeas", "relevance", "evidenceIDs"],
            "additionalProperties": false,
        ]
        return [
            "type": "json_schema",
            "name": "mimo_daily_reflection",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "headline": ["type": "string"],
                    "summary": ["type": "string"],
                    "sections": ["type": "array", "items": section],
                    "materialSummaries": ["type": "array", "items": material],
                ],
                "required": ["headline", "summary", "sections", "materialSummaries"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
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

    private func parseResponse(_ data: Data, snapshot: DailyActivitySnapshot,
                               projection: ModelProjection) throws -> DailyReflection {
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
                  valid(decoded, snapshot: snapshot, projection: projection) else { continue }
            let decodedMaterials = Dictionary(uniqueKeysWithValues:
                decoded.materialSummaries.map { ($0.materialID, $0) })
            let localMaterials = Dictionary(uniqueKeysWithValues:
                LocalActivityReflector.build(snapshot: snapshot).materialSummaries.map {
                    ($0.materialID, $0)
                })
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
                materialSummaries: snapshot.materials.compactMap { source in
                    if let material = decodedMaterials[source.id] {
                        return .init(materialID: material.materialID,
                                     overview: bounded(material.overview, count: 1_500),
                                     keyIdeas: material.keyIdeas.prefix(5).map {
                                         bounded($0, count: 500)
                                     },
                                     relevance: material.relevance.map { bounded($0, count: 800) },
                                     evidenceIDs: unique(material.evidenceIDs), isAIEnhanced: true)
                    }
                    return localMaterials[source.id]
                }, isAIEnhanced: true)
        }
        throw ReflectionModelError.invalidResponse
    }

    private func valid(_ output: ModelOutput, snapshot: DailyActivitySnapshot,
                       projection: ModelProjection) -> Bool {
        guard !output.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !output.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.sections.map(\.kind) == DailyReflectionSectionKind.allCases else { return false }
        let allowed = projection.evidenceIDs
        for section in output.sections {
            for statement in section.statements {
                guard !statement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !statement.evidenceIDs.isEmpty,
                      statement.evidenceIDs.allSatisfy(allowed.contains) else { return false }
            }
        }
        let expectedMaterials = Set(projection.materials.map(\.id))
        guard Set(output.materialSummaries.map(\.materialID)) == expectedMaterials,
              output.materialSummaries.count == expectedMaterials.count else { return false }
        let materials = Dictionary(uniqueKeysWithValues: snapshot.materials.map { ($0.id, $0) })
        for summary in output.materialSummaries {
            guard let material = materials[summary.materialID],
                  !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !summary.evidenceIDs.isEmpty,
                  Set(summary.evidenceIDs).isSubset(of: Set(material.eventIDs)),
                  summary.evidenceIDs.allSatisfy(allowed.contains) else { return false }
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
        if let url = event.fullURL { output["url"] = bounded(SensitiveURLScrubber.scrub(url), count: 700) }
        return output
    }

    private func blockObject(_ block: ActivityBlock,
                             evidenceIDs: Set<String>) -> [String: Any] {
        ["id": block.id, "title": bounded(block.title, count: 500),
         "category": block.category.rawValue, "startMS": block.startedAtMS,
         "endMS": block.endedAtMS, "activeMinutes": Int((block.activeDurationMS / 60_000).rounded()),
         "apps": block.apps.prefix(12).map { bounded($0, count: 200) },
         "eventIDs": block.eventIDs.filter(evidenceIDs.contains)]
    }

    private func materialObject(_ material: LearningMaterial,
                                evidenceIDs: Set<String>) -> [String: Any] {
        var output: [String: Any] = [
            "id": material.id, "title": bounded(material.title, count: 700),
            "kind": material.kind.rawValue,
            "activeMinutes": Int((material.durationMS / 60_000).rounded()),
            "visits": material.encounterCount,
            "eventIDs": material.eventIDs.filter(evidenceIDs.contains),
        ]
        if let domain = material.domain { output["domain"] = bounded(domain, count: 300) }
        if let url = material.url { output["url"] = bounded(SensitiveURLScrubber.scrub(url), count: 700) }
        return output
    }

    private func serviceError(status: Int) -> ReflectionModelError {
        switch status {
        case 401: return .authentication
        case 403: return .accessDenied
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .requestRejected(status: status)
        }
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
