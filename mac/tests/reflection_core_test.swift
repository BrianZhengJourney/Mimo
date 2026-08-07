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
        expect(graph.clusters.count == 4
               && graph.clusters.flatMap(\.nodeKeys) == blocks.map(\.id)
               && graph.jsonObject()?["nodes"] != nil,
               "cluster membership is lossless and exports in Graphology-compatible shape")
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
