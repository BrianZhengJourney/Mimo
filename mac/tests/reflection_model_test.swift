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

private func modelResponse(snapshot: DailyActivitySnapshot,
                           evidenceID: String? = nil,
                           materialID: String? = nil) throws -> Data {
    let chosenEvidence = evidenceID ?? snapshot.events[0].id
    let sections: [[String: Any]] = DailyReflectionSectionKind.allCases.map { kind in
        ["kind": kind.rawValue,
         "statements": [["text": "Grounded \(kind.rawValue)",
                          "claimKind": kind == .whatIDid ? "fact" : "inference",
                          "evidenceIDs": [chosenEvidence]]]]
    }
    let materials: [[String: Any]] = snapshot.materials.map { material in
        ["materialID": materialID ?? material.id,
         "overview": "A title-grounded overview.",
         "keyIdeas": ["One supported idea"],
         "relevance": "Relevant to the current activity.",
         "evidenceIDs": [material.eventIDs[0]]]
    }
    let object: [String: Any] = [
        "headline": "A building-led day",
        "summary": "Work and learning were connected.",
        "sections": sections,
        "materialSummaries": materials,
    ]
    let text = String(data: try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    return try JSONSerialization.data(withJSONObject: [
        "output": [
            ["type": "reasoning", "content": [["type": "output_text", "text": "{\"wrong\":true}"]]],
            ["type": "message", "content": [["type": "output_text", "text": text]]],
        ],
    ])
}

private func makeSnapshot() -> DailyActivitySnapshot {
    let range = ReflectionDateRange(
        start: Date(timeIntervalSince1970: 1_780_000_000),
        end: Date(timeIntervalSince1970: 1_780_086_400))
    let learning = ActivityEvent(
        id: "activity-learning", startedAtMS: 1_780_000_000_000,
        endedAtMS: 1_780_001_200_000, app: "Arc", title: "Activity Sensemaking",
        fullURL: "https://example.com/read?topic=mimo&access_token=TOPSECRET#private",
        domain: "example.com", category: "paper", canonicalLabel: "Activity Sensemaking",
        order: 0)
    let building = ActivityEvent(
        id: "activity-building", startedAtMS: 1_780_001_260_000,
        endedAtMS: 1_780_003_600_000, app: "Cursor", title: "Mimo Today Journal",
        fullURL: "file:///Users/example/Mimo?session=PRIVATE", domain: nil,
        category: "code", order: 1, isContextSwitch: true)
    return .build(range: range, events: [learning, building])
}

private func makeLongDaySnapshot(eventCount: Int = 465) -> DailyActivitySnapshot {
    let range = ReflectionDateRange(
        start: Date(timeIntervalSince1970: 1_780_000_000),
        end: Date(timeIntervalSince1970: 1_780_086_400))
    let events = (0..<eventCount).map { index in
        let startedAtMS = 1_780_000_000_000 + Double(index * 90_000)
        return ActivityEvent(
            id: "long-day-\(index)", startedAtMS: startedAtMS,
            endedAtMS: startedAtMS + 60_000,
            app: index.isMultiple(of: 2) ? "Cursor" : "Terminal",
            title: index.isMultiple(of: 2) ? "Mimo Today Journal" : "Build and test",
            category: "code",
            order: index, isContextSwitch: index > 0)
    }
    return .build(range: range, events: events)
}

@main
struct ReflectionModelTests {
    static func main() async throws {
        let snapshot = makeSnapshot()
        let transport = MockReflectionTransport(responseData: try modelResponse(snapshot: snapshot))
        var keyReads = 0
        let model = OpenAIReflectionModel(keyReader: {
            keyReads += 1
            return "test-key-never-log"
        }, transport: transport)

        let output = try await model.synthesize(.init(
            snapshot: snapshot,
            prompt: "What mattered? https://example.com/q?token=PROMPT_SECRET",
            focusRange: .init(
                start: snapshot.range.start.addingTimeInterval(30 * 60),
                end: snapshot.range.start.addingTimeInterval(60 * 60))))
        expect(keyReads == 1 && transport.requests.count == 1,
               "AI enrichment reads the credential once and makes one request")
        let request = transport.requests[0]
        expect(request.url == OpenAIReflectionModel.endpoint && request.httpMethod == "POST",
               "adapter uses the Responses endpoint")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-never-log",
               "the injected key stays in Authorization")

        guard let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let messages = body["input"] as? [[String: Any]], messages.count == 2,
              let systemContent = messages[0]["content"] as? [[String: Any]],
              let systemPrompt = systemContent.first?["text"] as? String,
              let userContent = messages[1]["content"] as? [[String: Any]],
              let userText = userContent.first?["text"] as? String else {
            throw ReflectionModelError.invalidResponse
        }
        expect(body["model"] as? String == "gpt-5.6"
               && body["store"] as? Bool == false,
               "the request uses the configured bounded no-store contract")
        let textConfig = body["text"] as? [String: Any]
        let outputFormat = textConfig?["format"] as? [String: Any]
        expect(outputFormat?["type"] as? String == "json_schema"
               && outputFormat?["strict"] as? Bool == true,
               "the response uses the current strict structured-output contract")
        expect(systemPrompt.contains("Every statement must cite")
               && systemPrompt.contains("Never claim a task was completed")
               && systemPrompt.contains("For every supplied learning material"),
               "the prompt requires honest evidence-grounded daily and material summaries")
        expect(userText.contains("activity-learning")
               && userText.contains("Activity Sensemaking")
               && userText.contains("topic=mimo"),
               "activity and useful URL context reach the confirmed request")
        expect(userText.contains("focusWindow")
               && userText.contains("startMS") && userText.contains("endMS"),
               "a selected half-hour is explicit in the model's grounded context")
        for forbidden in ["TOPSECRET", "access_token", "#private", "PROMPT_SECRET", "token="] {
            expect(!userText.contains(forbidden), "model payload removes \(forbidden)")
        }
        expect(!systemPrompt.lowercased().contains("notion")
               && !userText.lowercased().contains("notion"),
               "Today Journal has no remote-notes dependency")

        expect(output.isAIEnhanced
               && output.sections.map(\.kind) == DailyReflectionSectionKind.allCases,
               "valid grounded output becomes an AI-enhanced reflection")
        expect(output.materialSummaries.count == snapshot.materials.count
               && output.materialSummaries.allSatisfy(\.isAIEnhanced),
               "every learning material receives one enriched summary")

        let longDay = makeLongDaySnapshot()
        let longDayTransport = MockReflectionTransport(
            responseData: try modelResponse(snapshot: longDay))
        let longDayModel = OpenAIReflectionModel(
            keyReader: { "key" }, transport: longDayTransport)
        do {
            _ = try await longDayModel.synthesize(.init(snapshot: longDay))
            expect(longDayTransport.requests.count == 1,
                   "a long real-world day still reaches the model service")
            guard let bodyData = longDayTransport.requests[0].httpBody,
                  let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let input = body["input"] as? [[String: Any]],
                  let content = input.last?["content"] as? [[String: Any]],
                  let userText = content.first?["text"] as? String,
                  let userData = userText.data(using: .utf8),
                  let projection = try JSONSerialization.jsonObject(with: userData) as? [String: Any],
                  let events = projection["events"] as? [[String: Any]] else {
                throw ReflectionModelError.invalidResponse
            }
            expect(events.count <= 240 && events.count >= 24,
                   "a long day is represented by bounded evidence instead of being dropped")
        } catch {
            expect(false, "a long real-world day should be compacted, not rejected: \(error)")
        }

        let invalidEvidenceTransport = MockReflectionTransport(
            responseData: try modelResponse(snapshot: snapshot, evidenceID: "unknown-event"))
        let invalidEvidenceModel = OpenAIReflectionModel(
            keyReader: { "key" }, transport: invalidEvidenceTransport)
        do {
            _ = try await invalidEvidenceModel.synthesize(.init(snapshot: snapshot))
            expect(false, "unknown evidence must be rejected")
        } catch {
            expect(error as? ReflectionModelError == .invalidResponse,
                   "unknown evidence fails the full response")
        }

        let invalidMaterialTransport = MockReflectionTransport(
            responseData: try modelResponse(snapshot: snapshot, materialID: "unknown-material"))
        let invalidMaterialModel = OpenAIReflectionModel(
            keyReader: { "key" }, transport: invalidMaterialTransport)
        do {
            _ = try await invalidMaterialModel.synthesize(.init(snapshot: snapshot))
            expect(false, "unknown material must be rejected")
        } catch {
            expect(error as? ReflectionModelError == .invalidResponse,
                   "material summaries cannot detach from local material evidence")
        }

        let missingKeyModel = OpenAIReflectionModel(
            keyReader: { nil }, transport: transport)
        do {
            _ = try await missingKeyModel.synthesize(.init(snapshot: snapshot))
            expect(false, "missing credentials cannot issue a model request")
        } catch {
            expect(error as? ReflectionModelError == .missingKey,
                   "missing key remains an explicit optional-provider state")
        }

        for (status, expected) in [
            (401, ReflectionModelError.authentication),
            (403, ReflectionModelError.accessDenied),
            (429, ReflectionModelError.rateLimited),
            (503, ReflectionModelError.serviceUnavailable),
        ] {
            let failureTransport = MockReflectionTransport(
                responseData: Data(#"{"error":{"message":"provider detail stays private"}}"#.utf8),
                statusCode: status)
            let failureModel = OpenAIReflectionModel(
                keyReader: { "key" }, transport: failureTransport)
            do {
                _ = try await failureModel.synthesize(.init(snapshot: snapshot))
                expect(false, "HTTP \(status) must remain actionable")
            } catch {
                expect(error as? ReflectionModelError == expected,
                       "HTTP \(status) maps to a safe actionable error")
            }
        }

        let local = try await LocalReflectionModel().synthesize(.init(snapshot: snapshot))
        expect(!local.isAIEnhanced
               && local.sections.flatMap(\.statements).allSatisfy { !$0.evidenceIDs.isEmpty },
               "local reflection works without network access and stays grounded")

        print("reflection model tests passed")
    }
}
