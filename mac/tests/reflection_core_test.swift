// sources: reflection_core.swift journey_graph.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ReflectionCoreTests {
    static func main() throws {
        let jsonl = [
            #"{"app":"Arc","kind":"paper","detail":"Activity Sensemaking — Arc","canon":"Activity Sensemaking","url":"https://example.com/read?topic=mimo&token=secret#private","t0":60000,"t1":180000}"#,
            #"{"app":"Cursor","kind":"code","detail":"Mimo Today Journal","t0":190000,"t1":490000}"#,
            #"{"app":"Claude","kind":"neutral","detail":"Mimo information architecture","t0":500000,"t1":680000}"#,
            #"{"app":"WeChat","bundleID":"com.tencent.xinWeChat","kind":"neutral","detail":"Product discussion","t0":900000,"t1":1020000}"#,
            #"{"app":"Arc","kind":"paper","detail":"Activity Sensemaking — Arc","canon":"Activity Sensemaking","url":"https://example.com/read?topic=mimo&token=secret#private","t0":1100000,"t1":1220000}"#,
            "not json",
        ].joined(separator: "\n")

        let result = ActivityJSONLParser.parse(jsonl, sourceID: "activity-2026-08-04.jsonl")
        expect(result.events.count == 5 && result.malformedLineNumbers == [6],
               "valid activity survives a malformed neighboring line")
        expect(Set(result.events.map(\.id)).count == 5,
               "duplicate event metadata still receives occurrence-stable IDs")
        let again = ActivityJSONLParser.parse(jsonl, sourceID: "activity-2026-08-04.jsonl")
        expect(again.events.map(\.id) == result.events.map(\.id),
               "raw event IDs are stable across parses")
        expect(result.events[4].isRevisit,
               "returning to a prior subject is identified as a revisit")
        expect(result.events.dropFirst().allSatisfy(\.isContextSwitch),
               "subject changes remain visible as raw context switches")

        expect(ActivityCategory.classify(result.events[0]) == .learning,
               "paper activity maps to learning")
        expect(ActivityCategory.classify(result.events[1]) == .building
               && ActivityCategory.classify(result.events[2]) == .building,
               "developer and AI tools map to building")
        expect(ActivityCategory.classify(result.events[3]) == .communication,
               "communication apps map to communication")
        expect(result.events[3].bundleIdentifier == "com.tencent.xinWeChat",
               "native bundle identity survives the local activity parser")
        let legacyEventJSON = #"{"id":"legacy","startedAtMS":1,"endedAtMS":2,"app":"Cursor","category":"code","order":0,"isRevisit":false,"isContextSwitch":false}"#
        let legacyEvent = try JSONDecoder().decode(
            ActivityEvent.self, from: Data(legacyEventJSON.utf8))
        expect(legacyEvent.source == "mimo",
               "pre-adapter activity archives migrate to explicit Mimo provenance")

        let blocks = ActivityBlockBuilder.build(result.events)
        expect(blocks.count == 4,
               "quick Cursor to Claude tool switching becomes one meaningful block")
        expect(blocks[1].eventIDs == [result.events[1].id, result.events[2].id]
               && Set(blocks[1].apps) == Set(["Cursor", "Claude"]),
               "merged blocks preserve ordered raw evidence and contributing apps")
        expect(blocks.flatMap(\.eventIDs) == result.events.map(\.id),
               "meaningful blocks are a lossless view of raw events")

        let range = ReflectionDateRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 2_000))
        let snapshot = DailyActivitySnapshot.build(range: range, events: result.events)
        expect(snapshot.blocks == blocks && snapshot.contextSwitchCount == 4,
               "dashboard metrics derive from the same raw sequence")
        expect(snapshot.materials.count == 1
               && snapshot.materials[0].encounterCount == 2
               && snapshot.materials[0].eventIDs == [result.events[0].id, result.events[4].id],
               "revisited learning material becomes one card with both evidence items")
        expect(abs(snapshot.categories.reduce(0) { $0 + $1.share } - 1) < 0.0001,
               "category shares cover all active duration")

        let graph = JourneyGraphBuilder.build(
            snapshot: snapshot, generatedAt: Date(timeIntervalSince1970: 1_500))
        expect(graph.nodes.map(\.key) == blocks.map(\.id)
               && graph.edges.filter { $0.attributes.kind == "sequence" }.count == 3,
               "the local graph preserves every meaningful block and chronological transition")
        let returnEdge = graph.edges.first { $0.attributes.kind == "return" }
        expect(returnEdge?.source == blocks.first?.id
               && returnEdge?.target == blocks.last?.id,
               "a non-adjacent return to the same place becomes an explicit return edge")
        expect(graph.clusters.count == 3
               && graph.clusters.flatMap(\.nodeKeys).sorted() == blocks.map(\.id).sorted()
               && Set(graph.clusters.flatMap(\.nodeKeys)).count == blocks.count
               && graph.jsonObject()?["nodes"] != nil,
               "semantic topic membership is lossless and exports in Graphology-compatible shape")

        let topicEvents = [
            ActivityEvent(id: "topic-1", startedAtMS: 0, endedAtMS: 60_000,
                          app: "Cursor", title: "Mimo graph renderer",
                          category: "code", order: 0),
            ActivityEvent(id: "topic-2", startedAtMS: 180_000, endedAtMS: 240_000,
                          app: "Arc", title: "Attention research paper",
                          fullURL: "https://arxiv.org/abs/attention",
                          domain: "arxiv.org", category: "paper", order: 1),
            ActivityEvent(id: "topic-3", startedAtMS: 360_000, endedAtMS: 420_000,
                          app: "Figma", title: "Mimo graph interface",
                          category: "design", order: 2),
        ]
        let topicSnapshot = DailyActivitySnapshot.build(range: range, events: topicEvents)
        let topicGraph = JourneyGraphBuilder.build(snapshot: topicSnapshot)
        expect(topicGraph.clusters.count == 2
               && topicGraph.clusters.contains { $0.nodeKeys == [
                    topicSnapshot.blocks[0].id, topicSnapshot.blocks[2].id] }
               && topicGraph.edges.contains { $0.attributes.kind == "topic-return" },
               "a subject resumed in another tool becomes one topic and an explicit return")
        let sourceTopic = topicGraph.clusters.first {
            $0.nodeKeys.count == 2
        }!
        let targetTopic = topicGraph.clusters.first {
            $0.id != sourceTopic.id
        }!
        let corrections = JourneyGraphCorrections(
            labels: [targetTopic.id: "Mimo research"],
            merges: [sourceTopic.id: targetTopic.id])
        let corrected = corrections.applying(to: topicGraph)
        expect(corrected.clusters.count == 1
               && corrected.clusters[0].id == targetTopic.id
               && corrected.clusters[0].label == "Mimo research"
               && corrected.clusters[0].nodeKeys.count == topicGraph.nodes.count
               && corrected.nodes.allSatisfy {
                    $0.attributes.clusterID == targetTopic.id
               },
               "a user merge remaps every node and keeps the chosen human label")
        expect(!corrected.edges.contains { $0.attributes.kind == "topic-return" },
               "merging formerly separated topics removes stale return edges")
        let correctionData = try JSONEncoder().encode(corrections)
        let decodedCorrections = try JSONDecoder().decode(
            JourneyGraphCorrections.self, from: correctionData)
        expect(decodedCorrections == corrections,
               "topic corrections are restart-safe Codable state")
        let cyclic = JourneyGraphCorrections(
            merges: [sourceTopic.id: targetTopic.id, targetTopic.id: sourceTopic.id])
            .applying(to: topicGraph)
        expect(cyclic.clusters.count == topicGraph.clusters.count,
               "a corrupt merge cycle fails closed without losing a topic")
        let graphRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-journey-graph-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: graphRoot) }
        let graphStore = JourneyGraphStore(root: graphRoot)
        try graphStore.save(graph)
        let graphFiles = try FileManager.default.contentsOfDirectory(
            at: graphRoot, includingPropertiesForKeys: nil)
        expect(graphFiles.count == 1
               && graphFiles[0].lastPathComponent.hasPrefix(JourneyGraphStore.filePrefix),
               "journey graph snapshots persist locally with a bounded, date-addressed filename")
        var nextDay = graph
        let dayMS = 24.0 * 60 * 60 * 1_000
        nextDay.attributes.rangeStartMS += dayMS
        nextDay.attributes.rangeEndMS += dayMS
        nextDay.clusters = nextDay.clusters.map { cluster in
            var shifted = cluster
            shifted.startedAtMS += dayMS
            shifted.endedAtMS += dayMS
            return shifted
        }
        let enriched = graphStore.enrichingWithHistory(nextDay)
        expect(enriched.clusters.allSatisfy {
            $0.priorDayCount == 1 && $0.lastSeenAtMS != nil
        }, "today's topic nodes can show honest cross-day recurrence metadata")
        let graphPurged = graphStore.purgeAll()
        let remainingGraphFiles = try FileManager.default.contentsOfDirectory(
            at: graphRoot, includingPropertiesForKeys: nil)
        expect(graphPurged && remainingGraphFiles.isEmpty,
               "privacy reset removes every derived graph snapshot")

        let reflection = LocalActivityReflector.build(snapshot: snapshot)
        expect(reflection.sections.map(\.kind) == DailyReflectionSectionKind.allCases,
               "local reflection always exposes the stable five-section shape")
        let allowed = Set(result.events.map(\.id))
        let statements = reflection.sections.flatMap(\.statements)
        expect(!statements.isEmpty
               && statements.allSatisfy { !$0.evidenceIDs.isEmpty
                    && Set($0.evidenceIDs).isSubset(of: allowed) },
               "every local reflection statement resolves to raw evidence")
        expect(reflection.materialSummaries.count == snapshot.materials.count
               && reflection.materialSummaries.allSatisfy { !$0.isAIEnhanced },
               "local material summaries are honest metadata fallbacks")

        let rawURL = result.events[0].fullURL!
        let scrubbed = SensitiveURLScrubber.scrub(rawURL)
        expect(scrubbed.contains("topic=mimo") && !scrubbed.contains("token")
               && !scrubbed.contains("secret") && !scrubbed.contains("#private"),
               "model-bound URLs retain useful context but remove secrets and fragments")
        expect(result.events[0].fullURL == rawURL,
               "privacy projection never mutates local raw evidence")
        expect(result.events[0].modelSafeCopy().fullURL == scrubbed,
               "explicit model copies use the scrubbed URL")

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNoon = Date(timeIntervalSince1970: 1_741_543_200) // 2025-03-09 local noon
        let today = ReflectionDateRange.today(containing: dstNoon, calendar: losAngeles)
        expect(today.end.timeIntervalSince(today.start) == 23 * 3_600,
               "civil-day ranges remain correct across DST")
        let week = ReflectionDateRange.week(containing: dstNoon, calendar: losAngeles)
        expect(losAngeles.dateComponents([.day], from: week.start, to: today.start).day == 6,
               "week is today plus six preceding local days")

        print("reflection core tests passed")
    }
}
