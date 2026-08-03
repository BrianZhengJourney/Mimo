// sources: reflection_core.swift reflection_model.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class MockReflectionTransport: ReflectionModelTransport {
    var responseData: Data
    var statusCode: Int
    var requests: [URLRequest] = []

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (responseData, response)
    }
}

private func responseData(evidenceIDs: [String], invalidFirst: Bool = false,
                          overrideEvidenceID: String? = nil,
                          overrideClaimKind: String? = nil,
                          quoteText: String = "\"SELECTED_NOTION_MARKDOWN\"",
                          quoteEvidenceID: String? = nil) throws -> Data {
    let kinds = ReflectionSectionKind.allCases.map(\.rawValue)
    let claims = ["fact", "inference", "quote", "inference", "inference", "fact"]
    let sections: [[String: Any]] = kinds.enumerated().map { index, kind in
        let isQuote = claims[index] == "quote"
        return [
            "kind": kind,
            "statements": [[
                "text": isQuote ? quoteText : "Statement \(index)",
                "claimKind": overrideClaimKind ?? claims[index],
                "evidenceIDs": [overrideEvidenceID
                    ?? (isQuote ? (quoteEvidenceID ?? evidenceIDs.last!)
                                : evidenceIDs[index % evidenceIDs.count])],
            ]],
        ]
    }
    let validText = String(data: try JSONSerialization.data(
        withJSONObject: ["sections": sections], options: [.sortedKeys]), encoding: .utf8)!
    var output: [[String: Any]] = [
        // output_text outside a message must not be accepted.
        ["type": "reasoning", "content": [["type": "output_text", "text": "{\"wrong\":true}"]]],
        ["type": "message", "content": [["type": "refusal", "refusal": "none"]]],
    ]
    if invalidFirst {
        output.append(["type": "message", "content": [["type": "output_text", "text": "not json"]]])
    }
    output.append(["type": "message", "content": [["type": "output_text", "text": validText]]])
    return try JSONSerialization.data(withJSONObject: ["output": output])
}

private func makeInput() -> (ReflectionModelInput, ActivityEvent, [ReflectionEvidence]) {
    let range = ReflectionDateRange(
        start: Date(timeIntervalSince1970: 1_780_000_000),
        end: Date(timeIntervalSince1970: 1_780_086_400))
    let chosenActivity = ActivityEvent(
        id: "activity-chosen", startedAtMS: 1_780_000_000_000,
        endedAtMS: 1_780_003_600_000, app: "Arc", title: "Mimo research",
        fullURL: "https://example.com/research?topic=mimo&access_token=TOPSECRET#private",
        domain: "example.com", category: "research", canonicalLabel: "Mimo",
        order: 0)
    let unchosenActivity = ActivityEvent(
        id: "activity-unchosen", startedAtMS: 1_780_003_600_000,
        endedAtMS: 1_780_004_000_000, app: "PRIVATE_UNCHOSEN_APP",
        title: "PRIVATE_UNCHOSEN_TITLE",
        fullURL: "https://private.example/?password=never-send",
        domain: "private.example", category: "private", order: 1)
    let notion = NotionReflection(
        id: "notion-chosen", title: "Daily note", reflectionType: .daily,
        markdown: "SELECTED_NOTION_MARKDOWN https://files.example/art?signature=NOTION_URL_SECRET&size=large",
        pageID: "page-id", pageURL: "https://notion.so/page-id?session=PRIVATE",
        syncedAt: range.start)
    let activityEvidence = ReflectionEvidence(
        id: "evidence-activity", sourceKind: .activity,
        sourceID: chosenActivity.id, claimKind: .fact, label: "Mimo research",
        excerpt: "One hour in Mimo research", timestampMS: chosenActivity.startedAtMS,
        sourceURL: chosenActivity.fullURL)
    let notionEvidence = ReflectionEvidence(
        id: "evidence-notion", sourceKind: .notion, sourceID: notion.id,
        claimKind: .quote, label: "Daily note",
        excerpt: "I wanted to finish Mimo. https://example.com/x?auth=EXCERPT_URL_SECRET",
        sourceURL: notion.pageURL)
    let unchosenEvidence = ReflectionEvidence(
        id: "evidence-unchosen", sourceKind: .activity,
        sourceID: unchosenActivity.id, claimKind: .fact,
        label: "PRIVATE_UNCHOSEN_EVIDENCE", excerpt: "DO_NOT_SEND")
    let evidence = [activityEvidence, notionEvidence, unchosenEvidence]
    let input = ReflectionModelInput(
        dateRange: range, activities: [chosenActivity, unchosenActivity],
        reflections: [notion], evidence: evidence,
        chosenEvidenceIDs: [activityEvidence.id, notionEvidence.id],
        prompt: "Why did progress feel fragmented? https://example.com/q?token=PROMPT_URL_SECRET",
        conversation: [
            .init(id: "allowed-dialogue", role: .assistant,
                  content: "PRIOR_ALLOWED_DIALOGUE https://example.com/prior?key=HISTORY_URL_SECRET",
                  evidenceIDs: [activityEvidence.id]),
            .init(id: "private-dialogue", role: .user,
                  content: "PRIOR_PRIVATE_DIALOGUE",
                  evidenceIDs: [unchosenEvidence.id]),
        ])
    return (input, chosenActivity, evidence)
}

@main
struct ReflectionModelTests {
    static func main() async throws {
        let (input, originalActivity, evidence) = makeInput()
        let chosenIDs = Array(input.chosenEvidenceIDs)
        let transport = MockReflectionTransport(
            responseData: try responseData(evidenceIDs: chosenIDs, invalidFirst: true))
        var keyReads = 0
        let model = OpenAIReflectionModel(keyReader: {
            keyReads += 1
            return "test-key-never-log"
        }, transport: transport)

        let synthesis = try await model.synthesize(input)
        expect(keyReads == 1, "credential is read only when a synthesis is requested")
        expect(transport.requests.count == 1, "one Responses API call is made")
        let request = transport.requests[0]
        expect(request.url?.absoluteString == "https://api.openai.com/v1/responses",
               "adapter posts to the Responses API")
        expect(request.httpMethod == "POST", "Responses API uses POST")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-never-log",
               "injected key is used only in Authorization")

        guard let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            FileHandle.standardError.write(Data("FAIL: request JSON was not readable\n".utf8))
            exit(1)
        }
        expect(body["model"] as? String == "gpt-5.6", "default reflection model is gpt-5.6")
        expect(body["store"] as? Bool == false, "Responses storage is explicitly disabled")
        expect(body["max_output_tokens"] as? Int == 8_000,
               "model response spend is explicitly bounded")
        expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low",
               "reasoning effort is low")
        let text = body["text"] as? [String: Any]
        let format = text?["format"] as? [String: Any]
        expect(format?["type"] as? String == "json_object", "JSON object output is required")

        guard let messages = body["input"] as? [[String: Any]], messages.count == 2,
              let systemContent = messages[0]["content"] as? [[String: Any]],
              let systemPrompt = systemContent.first?["text"] as? String,
              let userContent = messages[1]["content"] as? [[String: Any]],
              let userText = userContent.first?["text"] as? String else {
            FileHandle.standardError.write(Data("FAIL: request input messages missing\n".utf8))
            exit(1)
        }
        expect(systemPrompt.contains("Return one JSON object only")
               && systemPrompt.contains("exactly these six section kinds")
               && systemPrompt.contains("quoted text must appear exactly"),
               "prompt explicitly requests the strict JSON contract")
        expect(userText.contains("evidence-activity") && userText.contains("evidence-notion"),
               "chosen evidence is sent")
        expect(userText.contains("SELECTED_NOTION_MARKDOWN")
               && userText.contains("Why did progress feel fragmented?"),
               "explicitly selected writing and the user's question are sent")
        expect(userText.contains("PRIOR_ALLOWED_DIALOGUE")
               && !userText.contains("PRIOR_PRIVATE_DIALOGUE"),
               "only same-scope evidence-linked dialogue is sent on follow-up")
        expect(!userText.contains("evidence-unchosen")
               && !userText.contains("PRIVATE_UNCHOSEN")
               && !userText.contains("DO_NOT_SEND"),
               "unchosen evidence and its source are excluded")
        expect(userText.contains("topic=mimo"), "ordinary URL context survives model projection")
        for forbidden in ["TOPSECRET", "access_token", "#private", "session=PRIVATE",
                          "NOTION_URL_SECRET", "EXCERPT_URL_SECRET",
                          "PROMPT_URL_SECRET", "HISTORY_URL_SECRET",
                          "signature", "auth=", "token="] {
            expect(!userText.contains(forbidden), "model request removes \(forbidden)")
        }
        expect(input.activities[0] == originalActivity
               && input.activities[0].fullURL?.contains("TOPSECRET") == true,
               "privacy projection never mutates the local raw event")

        expect(synthesis.sections.map(\.kind) == ReflectionSectionKind.allCases,
               "parser scanned past earlier output and accepted the complete message")
        expect(Set(synthesis.evidence.map(\.id)) == Set(chosenIDs),
               "result carries exactly the chosen resolvable evidence")

        // Any model citation outside the chosen evidence set invalidates the
        // entire response rather than displaying an unresolvable claim.
        let invalidTransport = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs, overrideEvidenceID: "invented-evidence"))
        let invalidModel = OpenAIReflectionModel(keyReader: { "key" },
                                                 transport: invalidTransport)
        do {
            _ = try await invalidModel.synthesize(input)
            expect(false, "invented evidence ID must be rejected")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "invented evidence produces invalidResponse")
        }

        // Unknown claim kinds fail Decodable enum validation.
        let claimTransport = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs, overrideClaimKind: "opinion"))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: claimTransport).synthesize(input)
            expect(false, "unknown claim kind must be rejected")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "unknown claim kind produces invalidResponse")
        }

        // A quote is accepted only when its cited selected Notion source
        // contains every excerpt verbatim. Activity-only and fabricated
        // quotations fail closed rather than appearing as the user's words.
        let fabricatedQuote = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs, quoteText: "User wrote \"NEVER_WRITTEN_WORDS\"."))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: fabricatedQuote).synthesize(input)
            expect(false, "fabricated quote must be rejected")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "fabricated quote produces invalidResponse")
        }
        let activityQuote = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs, quoteEvidenceID: chosenIDs[0]))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: activityQuote).synthesize(input)
            expect(false, "quote citing activity instead of Notion must be rejected")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "activity-only quote produces invalidResponse")
        }
        let quoteWithAssertion = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs,
            quoteText: "User shipped everything \"SELECTED_NOTION_MARKDOWN\""))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: quoteWithAssertion).synthesize(input)
            expect(false, "quote text must not carry an ungrounded assertion outside the excerpt")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "quote with external assertion produces invalidResponse")
        }
        let mislabeledQuote = MockReflectionTransport(responseData: try responseData(
            evidenceIDs: chosenIDs, overrideClaimKind: "fact",
            quoteText: "\"SELECTED_NOTION_MARKDOWN\""))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: mislabeledQuote).synthesize(input)
            expect(false, "quoted wording cannot bypass grounding by using a non-quote claim kind")
        } catch let error as ReflectionModelError {
            expect(error == .invalidResponse, "mislabeled quoted wording produces invalidResponse")
        }

        // Missing credentials terminate before transport and expose a setup
        // state, while local browsing/synthesis remains available separately.
        let missingTransport = MockReflectionTransport(
            responseData: try responseData(evidenceIDs: chosenIDs))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { nil },
                                                transport: missingTransport).synthesize(input)
            expect(false, "missing key must fail")
        } catch let error as ReflectionModelError {
            expect(error == .missingKey, "missing key has a dedicated setup error")
        }
        expect(missingTransport.requests.isEmpty, "missing key never attempts network access")

        // A selected ID must exist and resolve before request construction.
        var badInput = input
        badInput.chosenEvidenceIDs = ["not-in-evidence"]
        let badTransport = MockReflectionTransport(
            responseData: try responseData(evidenceIDs: chosenIDs))
        do {
            _ = try await OpenAIReflectionModel(keyReader: { "key" },
                                                transport: badTransport).synthesize(badInput)
            expect(false, "unknown selected evidence must fail")
        } catch let error as ReflectionModelError {
            expect(error == .invalidEvidence, "unknown selection produces invalidEvidence")
        }
        expect(badTransport.requests.isEmpty, "invalid selection never reaches network")

        // Local fallback has no credential or transport dependency.
        let local = try await LocalReflectionModel().synthesize(input)
        expect(local.sections.map(\.kind) == ReflectionSectionKind.allCases,
               "local fallback remains available without model configuration")
        expect(evidence.count == 3, "test fixture sanity")

        print("reflection model tests passed")
    }
}
