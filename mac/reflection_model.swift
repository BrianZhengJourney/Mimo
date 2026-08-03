// Mimo Reflection Browser — optional model boundary.
//
// The raw local timeline stays outside this layer. Callers explicitly choose
// evidence, and this adapter sends only those sources after URL scrubbing and
// size caps. No credential, request, response, or reflection content is logged.

import Foundation

struct ReflectionModelInput: Equatable {
    var dateRange: ReflectionDateRange
    var activities: [ActivityEvent]
    var reflections: [NotionReflection]
    var evidence: [ReflectionEvidence]
    var chosenEvidenceIDs: [String]
    var prompt: String?
    var conversation: [ReflectionMessage]

    init(dateRange: ReflectionDateRange, activities: [ActivityEvent],
         reflections: [NotionReflection], evidence: [ReflectionEvidence],
         chosenEvidenceIDs: [String], prompt: String? = nil,
         conversation: [ReflectionMessage] = []) {
        self.dateRange = dateRange
        self.activities = activities
        self.reflections = reflections
        self.evidence = evidence
        self.chosenEvidenceIDs = chosenEvidenceIDs
        self.prompt = prompt
        self.conversation = conversation
    }
}

protocol ReflectionModel {
    func synthesize(_ input: ReflectionModelInput) async throws -> LocalReflectionSynthesis
}

/// Always-available fallback. It performs no network access and ignores no raw
/// data because the caller is deliberately invoking local analysis.
struct LocalReflectionModel: ReflectionModel {
    func synthesize(_ input: ReflectionModelInput) async throws -> LocalReflectionSynthesis {
        LocalReflectionSynthesizer.build(events: input.activities, reflections: input.reflections)
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
    case noEvidence
    case invalidEvidence
    case payloadTooLarge
    case network
    case service(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add an OpenAI API key to use AI synthesis. Browsing, Notion sync, and search still work."
        case .noEvidence: return "Choose at least one evidence item before synthesis."
        case .invalidEvidence: return "A selected citation no longer resolves to its source."
        case .payloadTooLarge: return "The selected evidence is too large. Choose a smaller scope."
        case .network: return "Mimo could not reach the model service. Your local data is unchanged."
        case .service(let status): return "The model service returned HTTP \(status)."
        case .invalidResponse: return "The model response did not contain a valid evidence-linked synthesis."
        }
    }
}

final class OpenAIReflectionModel: ReflectionModel {
    static let defaultModel = "gpt-5.6"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let model: String
    private let keyReader: () -> String?
    private let transport: ReflectionModelTransport
    private let maximumEvidenceCount: Int
    private let maximumBodyBytes: Int
    private let maximumResponseBytes: Int

    /// The key reader is deliberately required here so this network boundary can
    /// compile and test independently of the app's Keychain implementation.
    /// Production wires it as `{ MimoSecret.openAI.read() }`.
    init(model: String = OpenAIReflectionModel.defaultModel,
         keyReader: @escaping () -> String?,
         transport: ReflectionModelTransport = EphemeralReflectionModelTransport(),
         maximumEvidenceCount: Int = 60,
         maximumBodyBytes: Int = 128 * 1_024,
         maximumResponseBytes: Int = 512 * 1_024) {
        self.model = model
        self.keyReader = keyReader
        self.transport = transport
        self.maximumEvidenceCount = max(1, maximumEvidenceCount)
        self.maximumBodyBytes = max(4_096, maximumBodyBytes)
        self.maximumResponseBytes = max(4_096, maximumResponseBytes)
    }

    func synthesize(_ input: ReflectionModelInput) async throws -> LocalReflectionSynthesis {
        guard let rawKey = keyReader()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKey.isEmpty, rawKey.utf8.count <= 4_096,
              !rawKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ReflectionModelError.missingKey
        }

        let scope = try selectedScope(input)
        let body = try requestBody(input: input, scope: scope)
        guard body.count <= maximumBodyBytes else { throw ReflectionModelError.payloadTooLarge }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(rawKey)", forHTTPHeaderField: "Authorization")
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
        return try parseResponse(data, selectedScope: scope)
    }

    private struct SelectedScope {
        var evidence: [ReflectionEvidence]
        var activities: [ActivityEvent]
        var reflections: [NotionReflection]
    }

    private func selectedScope(_ input: ReflectionModelInput) throws -> SelectedScope {
        let chosen = input.chosenEvidenceIDs.reduce(into: [String]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
        guard !chosen.isEmpty else { throw ReflectionModelError.noEvidence }
        guard chosen.count <= maximumEvidenceCount else { throw ReflectionModelError.payloadTooLarge }

        guard Set(input.evidence.map(\.id)).count == input.evidence.count,
              Set(input.activities.map(\.id)).count == input.activities.count,
              Set(input.reflections.map(\.id)).count == input.reflections.count else {
            throw ReflectionModelError.invalidEvidence
        }
        let evidenceByID = Dictionary(uniqueKeysWithValues: input.evidence.map { ($0.id, $0) })
        guard chosen.allSatisfy({ evidenceByID[$0] != nil }) else {
            throw ReflectionModelError.invalidEvidence
        }
        let selectedEvidence = chosen.compactMap { evidenceByID[$0] }
        let selectedActivityIDs = Set(selectedEvidence
            .filter { $0.sourceKind == .activity }.map(\.sourceID))
        let selectedReflectionIDs = Set(selectedEvidence
            .filter { $0.sourceKind == .notion }.map(\.sourceID))
        let activityByID = Dictionary(uniqueKeysWithValues: input.activities.map { ($0.id, $0) })
        let reflectionByID = Dictionary(uniqueKeysWithValues: input.reflections.map { ($0.id, $0) })
        guard selectedActivityIDs.allSatisfy({ activityByID[$0] != nil }),
              selectedReflectionIDs.allSatisfy({ reflectionByID[$0] != nil }) else {
            throw ReflectionModelError.invalidEvidence
        }
        let activities = input.activities
            .filter { selectedActivityIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
            .map { boundedActivity($0.modelSafeCopy()) }
        let reflections = input.reflections
            .filter { selectedReflectionIDs.contains($0.id) }
            .map(boundedReflection)
        return .init(evidence: selectedEvidence.map(boundedEvidence),
                     activities: activities, reflections: reflections)
    }

    private func requestBody(input: ReflectionModelInput, scope: SelectedScope) throws -> Data {
        let systemPrompt = """
        You are Mimo's evidence-grounded reflection analyst. Return one JSON object only; do not use Markdown fences or prose outside JSON. The object must be {"sections":[...]} with exactly these six section kinds, each exactly once and in this order: Chronology, Themes, Reflection vs Reality, Unresolved Threads, Questions Worth Carrying, Evidence. Every section has "statements". Every statement must be {"text":string,"claimKind":"fact"|"quote"|"inference","evidenceIDs":[string,...]}. Use the bounded conversation only as prior dialogue context. Ground every new statement in the current chosen evidence, use only evidence IDs supplied in the input, cite at least one for every statement, distinguish observed facts, verbatim reflection quotes, and interpretations, and never invent evidence. For every statement whose claimKind is "quote", cite a chosen Notion evidence ID. Its text field must consist only of one exact verbatim excerpt enclosed in straight double quotes, curly double quotes, or Chinese corner quotes. The quoted text must appear exactly in that cited Notion source; never add an assertion outside the quotation or paraphrase text while labeling it as a quote. Do not use those quotation delimiters in fact or inference statements; user wording belongs only in a validated quote statement.
        """
        let userObject: [String: Any] = [
            "dateRange": [
                "startMS": input.dateRange.start.timeIntervalSince1970 * 1_000,
                "endMS": input.dateRange.end.timeIntervalSince1970 * 1_000,
            ],
            "chosenEvidence": scope.evidence.map(evidenceObject),
            "activities": scope.activities.map(activityObject),
            "notionSources": scope.reflections.map(reflectionObject),
            "question": bounded(SensitiveURLScrubber.scrubURLs(
                in: input.prompt ?? "Compare the written reflection with the observed activity."),
                                count: 2_000),
            "conversation": conversationObjects(input.conversation,
                                                 allowedEvidence: Set(scope.evidence.map(\.id))),
        ]
        let userData = try JSONSerialization.data(withJSONObject: userObject, options: [.sortedKeys])
        guard let userText = String(data: userData, encoding: .utf8) else {
            throw ReflectionModelError.invalidEvidence
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 8_000,
            "reasoning": ["effort": "low"],
            "text": ["format": ["type": "json_object"]],
            "input": [
                ["role": "system", "content": [["type": "input_text", "text": systemPrompt]]],
                ["role": "user", "content": [["type": "input_text", "text": userText]]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func parseResponse(_ data: Data,
                               selectedScope: SelectedScope) throws -> LocalReflectionSynthesis {
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
        // Most responses have one output_text item. Concatenation additionally
        // handles a provider splitting a JSON object into multiple text parts.
        let scans = candidates + (candidates.count > 1 ? [candidates.joined()] : [])
        let selectedEvidence = selectedScope.evidence
        let allowed = Set(selectedEvidence.map(\.id))
        for candidate in scans {
            guard candidate.utf8.count <= maximumResponseBytes,
                  let candidateData = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(ResponseEnvelope.self, from: candidateData),
                  validate(decoded.sections, allowedEvidenceIDs: allowed,
                           selectedEvidence: selectedEvidence,
                           selectedReflections: selectedScope.reflections) else { continue }
            return .init(sections: decoded.sections, evidence: selectedEvidence)
        }
        throw ReflectionModelError.invalidResponse
    }

    private struct ResponseEnvelope: Decodable {
        var sections: [ReflectionSynthesisSection]
    }

    private func validate(_ sections: [ReflectionSynthesisSection],
                          allowedEvidenceIDs: Set<String>,
                          selectedEvidence: [ReflectionEvidence],
                          selectedReflections: [NotionReflection]) -> Bool {
        guard sections.count == ReflectionSectionKind.allCases.count,
              sections.map(\.kind) == ReflectionSectionKind.allCases else { return false }
        let evidenceByID = Dictionary(uniqueKeysWithValues: selectedEvidence.map { ($0.id, $0) })
        let notionTextBySourceID = Dictionary(uniqueKeysWithValues: selectedReflections.map {
            ($0.id, normalizedQuoteText($0.markdown))
        })
        for section in sections {
            for statement in section.statements {
                guard !statement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      statement.text.utf8.count <= 20_000,
                      !statement.evidenceIDs.isEmpty,
                      statement.evidenceIDs.allSatisfy(allowedEvidenceIDs.contains) else {
                    return false
                }
                if statement.claimKind == .quote {
                    let citedNotionSources = statement.evidenceIDs.compactMap { evidenceByID[$0] }
                        .filter { $0.sourceKind == .notion }
                        .compactMap { notionTextBySourceID[$0.sourceID] }
                    guard let span = exactQuotedSpan(in: statement.text) else { return false }
                    let exact = normalizedQuoteText(span)
                    guard !citedNotionSources.isEmpty, exact.count >= 2,
                          citedNotionSources.contains(where: { $0.contains(exact) }) else {
                        return false
                    }
                } else if hasPairedQuoteDelimiter(in: statement.text) {
                    return false
                }
            }
        }
        return true
    }

    /// Quote claims are stronger than ordinary citations: the user-visible
    /// excerpt must be recoverable from a selected Notion source. Collapsing
    /// whitespace tolerates Markdown line wrapping without permitting a
    /// paraphrase to masquerade as the user's words.
    private func normalizedQuoteText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func exactQuotedSpan(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] {
            guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
                  trimmed.count >= open.count + close.count else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
            let span = String(trimmed[start..<end])
            guard span.count <= 2_000,
                  !span.contains(open), !span.contains(close) else { return nil }
            return span
        }
        return nil
    }

    private func hasPairedQuoteDelimiter(in value: String) -> Bool {
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] {
            guard let start = value.range(of: open) else { continue }
            if value.range(of: close, range: start.upperBound..<value.endIndex) != nil {
                return true
            }
        }
        return false
    }

    // MARK: Bounded JSON projection

    private func boundedActivity(_ raw: ActivityEvent) -> ActivityEvent {
        var event = raw
        event.app = bounded(SensitiveURLScrubber.scrubURLs(in: event.app), count: 160)
        event.title = event.title.map {
            bounded(SensitiveURLScrubber.scrubURLs(in: $0), count: 500)
        }
        event.fullURL = event.fullURL.map { bounded(SensitiveURLScrubber.scrub($0), count: 2_048) }
        event.domain = event.domain.map { bounded($0, count: 253) }
        event.category = bounded(event.category, count: 100)
        event.canonicalLabel = event.canonicalLabel.map {
            bounded(SensitiveURLScrubber.scrubURLs(in: $0), count: 300)
        }
        return event
    }

    private func boundedReflection(_ raw: NotionReflection) -> NotionReflection {
        var reflection = raw
        reflection.title = bounded(SensitiveURLScrubber.scrubURLs(in: reflection.title),
                                   count: 300)
        // Only explicitly selected Notion sources cross the model boundary.
        // Keep enough of the original writing to compare reflection vs reality,
        // while the request-wide byte cap remains the final privacy/size gate.
        reflection.markdown = bounded(
            SensitiveURLScrubber.scrubURLs(in: reflection.markdown), count: 12_000)
        reflection.pageURL = bounded(SensitiveURLScrubber.scrub(reflection.pageURL), count: 2_048)
        return reflection
    }

    private func boundedEvidence(_ raw: ReflectionEvidence) -> ReflectionEvidence {
        var evidence = raw
        evidence.label = bounded(SensitiveURLScrubber.scrubURLs(in: evidence.label), count: 300)
        evidence.excerpt = bounded(SensitiveURLScrubber.scrubURLs(in: evidence.excerpt),
                                   count: 1_200)
        evidence.sourceURL = evidence.sourceURL.map {
            bounded(SensitiveURLScrubber.scrub($0), count: 2_048)
        }
        return evidence
    }

    private func bounded(_ value: String, count: Int) -> String {
        String(value.prefix(count))
    }

    private func evidenceObject(_ evidence: ReflectionEvidence) -> [String: Any] {
        var object: [String: Any] = [
            "id": evidence.id,
            "sourceKind": evidence.sourceKind.rawValue,
            "sourceID": evidence.sourceID,
            "claimKind": evidence.claimKind.rawValue,
            "label": evidence.label,
            "excerpt": evidence.excerpt,
        ]
        if let timestamp = evidence.timestampMS { object["timestampMS"] = timestamp }
        if let url = evidence.sourceURL { object["sourceURL"] = url }
        return object
    }

    private func activityObject(_ event: ActivityEvent) -> [String: Any] {
        var object: [String: Any] = [
            "id": event.id,
            "startedAtMS": event.startedAtMS,
            "endedAtMS": event.endedAtMS,
            "app": event.app,
            "category": event.category,
            "order": event.order,
            "isRevisit": event.isRevisit,
            "isContextSwitch": event.isContextSwitch,
        ]
        if let title = event.title { object["title"] = title }
        if let url = event.fullURL { object["url"] = url }
        if let domain = event.domain { object["domain"] = domain }
        if let canonical = event.canonicalLabel { object["canonical"] = canonical }
        return object
    }

    private func reflectionObject(_ reflection: NotionReflection) -> [String: Any] {
        var object: [String: Any] = [
            "id": reflection.id,
            "title": reflection.title,
            "type": reflection.reflectionType.rawValue,
            "pageID": reflection.pageID,
            "pageURL": reflection.pageURL,
            "markdown": reflection.markdown,
        ]
        if let date = reflection.reflectionDate {
            object["reflectionDateMS"] = date.timeIntervalSince1970 * 1_000
        }
        return object
    }

    private func conversationObjects(_ messages: [ReflectionMessage],
                                     allowedEvidence: Set<String>) -> [[String: Any]] {
        messages.filter { message in
            message.role != .system && !message.evidenceIDs.isEmpty
                && message.evidenceIDs.allSatisfy(allowedEvidence.contains)
        }.suffix(12).map { message in
            [
                "role": message.role.rawValue,
                "content": bounded(SensitiveURLScrubber.scrubURLs(in: message.content),
                                   count: 4_000),
                "evidenceIDs": Array(message.evidenceIDs.prefix(60)),
            ] as [String: Any]
        }
    }
}
