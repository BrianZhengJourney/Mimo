// sources: reflection_core.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func utcDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else {
        FileHandle.standardError.write(Data("FAIL: invalid test date \(value)\n".utf8))
        exit(1)
    }
    return date
}

@main
struct ReflectionCoreTests {
    static func main() throws {
        let jsonl = [
            #"{"app":"Arc","kind":"research","detail":"Mimo spec","url":"https://example.com/doc?topic=mimo&token=private#part","canon":"Mimo","t0":1000,"t1":61000}"#,
            #"{"app":"Code","kind":"code","detail":"reflection_core.swift","canon":"Reflection core","t0":61000,"t1":181000}"#,
            #"{"app":"Arc","kind":"research","detail":"Mimo spec","url":"https://example.com/doc?topic=mimo&session_id=private","canon":"Mimo","t0":181000,"t1":241000}"#,
            #"{"app":"Arc","kind":"research","detail":"Mimo spec","url":"https://example.com/doc?topic=mimo","canon":"Mimo","t0":181000,"t1":241000}"#,
            #"{"app":"broken","t0":250000"#,
            "not JSON",
            "",
        ].joined(separator: "\n")

        // Bad JSONL lines are reported and skipped, while every valid event survives.
        let result = ActivityJSONLParser.parse(jsonl, sourceID: "activity-2026-08-02.jsonl")
        expect(result.events.count == 4, "valid lines survive neighboring malformed JSONL")
        expect(result.malformedLineNumbers == [5, 6], "malformed non-empty lines are identified")
        expect(Set(result.events.map(\.id)).count == 4,
               "identical timestamps/content still receive unique deterministic occurrence IDs")
        let again = ActivityJSONLParser.parse(jsonl, sourceID: "activity-2026-08-02.jsonl")
        expect(again.events.map(\.id) == result.events.map(\.id), "event IDs are stable across parses")
        expect(result.events[0].isContextSwitch == false, "first event is not a context switch")
        expect(result.events[1].isContextSwitch, "changing activity is a context switch")
        expect(result.events[2].isRevisit, "returning after another activity is a revisit")

        // Aggregates retain references rather than lossy summaries. Expansion restores
        // exact global order, with no duplicated or omitted event.
        let aggregates = ActivityAggregator.aggregate(result.events)
        let expanded = ActivityAggregator.expandLosslessly(aggregates, events: result.events)
        expect(expanded == result.events, "aggregate expansion is lossless and ordered")
        expect(aggregates.reduce(0) { $0 + $1.rawEventIDs.count } == result.events.count,
               "every raw event appears exactly once across aggregates")
        expect(aggregates.reduce(0) { $0 + $1.durationMS }
               == result.events.reduce(0) { $0 + $1.durationMS },
               "aggregate duration equals raw duration")
        let mimoAggregate = aggregates.first { $0.label == "Mimo" }
        expect(mimoAggregate?.revisitCount == 1, "aggregate exposes revisit count")
        expect((mimoAggregate?.contextSwitchCount ?? 0) >= 1,
               "aggregate exposes context-switch count")

        // Full URL remains on local raw evidence, but model copies and explicit
        // scrubbing remove credentials, sensitive query fields, and fragments.
        let sensitive = "https://alice:pw@example.com/path?topic=mimo&access_token=abc&api_key=def&code=ghi&lang=zh#secret"
        let scrubbed = SensitiveURLScrubber.scrub(sensitive)
        expect(scrubbed.contains("topic=mimo") && scrubbed.contains("lang=zh"),
               "ordinary query context is preserved")
        for forbidden in ["alice", "pw", "token", "key", "code=", "#", "abc", "def", "ghi"] {
            expect(!scrubbed.lowercased().contains(forbidden), "scrubbed URL removes \(forbidden)")
        }
        let local = result.events[0]
        expect(local.fullURL?.contains("token=private") == true,
               "raw local event retains its full URL")
        expect(local.modelSafeCopy().fullURL?.contains("token") == false,
               "model-safe event removes sensitive query data")
        let embedded = "See [draft](https://files.example/x?name=ok&signature=hidden#private), then continue."
        let cleanedText = SensitiveURLScrubber.scrubURLs(in: embedded)
        expect(cleanedText.contains("name=ok") && cleanedText.hasSuffix(", then continue."),
               "embedded URL scrubbing preserves ordinary context and punctuation")
        for forbidden in ["signature", "hidden", "#private"] {
            expect(!cleanedText.contains(forbidden),
                   "embedded model-bound text removes \(forbidden)")
        }

        let malformedEmbedded = "Open https://alice:pw@[::1/path?topic=mimo&token=topsecret#private now."
        let cleanedMalformed = SensitiveURLScrubber.scrubURLs(in: malformedEmbedded)
        expect(cleanedMalformed.hasPrefix("Open ") && cleanedMalformed.hasSuffix(" now."),
               "malformed embedded HTTP URL keeps surrounding model context")
        for forbidden in ["alice", "pw", "token", "topsecret", "#private"] {
            expect(!cleanedMalformed.lowercased().contains(forbidden),
                   "malformed embedded HTTP URL fails closed for \(forbidden)")
        }

        let nestedRedirect = "https://example.com/start?lang=zh"
            + "&next=https%3A%2F%2Falice%3Apw%40target.example%2Fcb%3Fview%3Dok%26access_token%3Dnestedsecret%23private"
            + "&redirect=api_key%3Dsecondsecret%26mode%3Dcontinue"
        let cleanedRedirect = SensitiveURLScrubber.scrub(nestedRedirect)
        let decodedRedirect = cleanedRedirect.removingPercentEncoding ?? cleanedRedirect
        expect(decodedRedirect.contains("lang=zh") && decodedRedirect.contains("target.example")
               && decodedRedirect.contains("view=ok"),
               "nested redirect keeps non-sensitive destination context")
        for forbidden in ["alice", "pw@", "access_token", "nestedsecret",
                          "api_key", "secondsecret", "#private"] {
            expect(!decodedRedirect.lowercased().contains(forbidden),
                   "nested redirect fails closed for \(forbidden)")
        }

        let unreadableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-unreadable-\(UUID().uuidString).jsonl")
        try Data([0xff, 0xfe]).write(to: unreadableURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: unreadableURL) }
        let readResult = ActivityJSONLParser.read(urls: [unreadableURL])
        expect(readResult.events.isEmpty
               && readResult.unreadableSourceIDs == [unreadableURL.lastPathComponent],
               "unreadable activity files are surfaced instead of silently appearing empty")

        // Today/Week are civil-day ranges in the supplied timezone, including DST.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.locale = Locale(identifier: "en_US_POSIX")
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNoon = utcDate("2026-03-08T19:00:00Z") // noon after spring-forward
        let today = ReflectionDateRange.today(containing: dstNoon, calendar: losAngeles)
        expect(today.end.timeIntervalSince(today.start) == 23 * 3_600,
               "Today follows local DST and is not hard-coded to 24 hours")
        expect(losAngeles.component(.hour, from: today.start) == 0,
               "Today starts at local midnight")
        let week = ReflectionDateRange.week(containing: dstNoon, calendar: losAngeles)
        expect(losAngeles.dateComponents([.day], from: week.start, to: today.start).day == 6,
               "Week includes the six preceding civil days")
        expect(week.end == today.end, "Week includes all of today")

        let reflection = NotionReflection(
            id: "notion-one", title: "Daily reflection", reflectionDate: dstNoon,
            reflectionType: .daily, markdown: "I wanted to finish the Reflection Browser.",
            pageID: "page-one", pageURL: "https://notion.so/page-one",
            lastEditedAt: dstNoon, syncedAt: dstNoon)

        // Resolver covers both source types; missing references fail clearly.
        let activityEvidence = ReflectionEvidence(
            id: "ev-activity", sourceKind: .activity, sourceID: local.id,
            claimKind: .fact, label: "Mimo", excerpt: "Observed Mimo work")
        let notionEvidence = ReflectionEvidence(
            id: "ev-notion", sourceKind: .notion, sourceID: reflection.id,
            claimKind: .quote, label: reflection.title, excerpt: reflection.markdown,
            sourceURL: reflection.pageURL)
        let resolver = EvidenceResolver(activities: result.events, reflections: [reflection])
        expect(resolver.resolve(activityEvidence) == .activity(local),
               "activity evidence resolves to its raw source")
        expect(resolver.resolve(notionEvidence) == .notion(reflection),
               "Notion evidence resolves to its imported source")
        let missing = ReflectionEvidence(id: "missing", sourceKind: .activity,
                                         sourceID: "no-event", claimKind: .fact,
                                         label: "missing", excerpt: "missing")
        expect(resolver.unresolved([activityEvidence, notionEvidence, missing]) == [missing],
               "resolver reports unresolved citations")

        // Offline synthesis remains useful without model configuration and every
        // emitted statement is evidence-linked and explicitly typed.
        let synthesis = LocalReflectionSynthesizer.build(events: result.events,
                                                         reflections: [reflection])
        expect(synthesis.sections.map(\.kind) == ReflectionSectionKind.allCases,
               "offline synthesis always exposes all six required sections")
        let evidenceIDs = Set(synthesis.evidence.map(\.id))
        let statements = synthesis.sections.flatMap(\.statements)
        expect(!statements.isEmpty, "offline synthesis has deterministic content")
        expect(statements.allSatisfy { !$0.evidenceIDs.isEmpty },
               "every synthesis claim or question has evidence")
        expect(statements.allSatisfy { Set($0.evidenceIDs).isSubset(of: evidenceIDs) },
               "every synthesis citation resolves to emitted evidence")
        expect(statements.contains { $0.claimKind == .fact }
               && statements.contains { $0.claimKind == .quote }
               && statements.contains { $0.claimKind == .inference },
               "facts, quotes, and inferences remain visibly distinct")
        expect(EvidenceResolver(activities: result.events, reflections: [reflection])
            .unresolved(synthesis.evidence).isEmpty,
               "every emitted evidence item resolves to an imported source")

        // Public persistence models retain their complete Codable contract.
        let sync = NotionSyncState(
            sourceID: "source", sourceURL: "https://notion.so/source",
            lastSyncedAt: dstNoon, lastEditedAtByPage: [reflection.pageID: dstNoon],
            cachedPageIDs: [reflection.pageID], nextCursor: "cursor", hasMore: true)
        let draft = SynthesisDraft(
            id: "draft", dateRange: week, title: "Mimo Synthesis",
            markdown: "# Mimo Synthesis", evidenceIDs: synthesis.evidence.map(\.id),
            target: .appendPage, targetPageID: reflection.pageID,
            createdAt: dstNoon, idempotencyKey: "stable-key")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decodedSync = try decoder.decode(NotionSyncState.self, from: encoder.encode(sync))
        let decodedDraft = try decoder.decode(SynthesisDraft.self, from: encoder.encode(draft))
        let mark = ReflectionMark(
            id: "mark-one", conversationID: "conversation-one",
            messageID: "assistant-one", kind: .highlight,
            location: 4, length: 7, text: "selected", evidenceIDs: ["A"],
            createdAt: dstNoon)
        let decodedMark = try decoder.decode(ReflectionMark.self, from: encoder.encode(mark))
        let legacyMark = ReflectionMark(
            id: "legacy", conversationID: "conversation-one",
            messageID: "claim-one", kind: .underline,
            location: 1, length: 3, createdAt: dstNoon)
        let decodedLegacyMark = try decoder.decode(
            ReflectionMark.self, from: encoder.encode(legacyMark))
        expect(decodedSync == sync,
               "Notion sync state Codable round-trips")
        expect(decodedDraft == draft,
               "synthesis draft Codable round-trips")
        expect(decodedMark == mark && decodedLegacyMark.text == nil
               && decodedLegacyMark.evidenceIDs == nil,
               "marks preserve exact source evidence while older state remains decodable")

        let scopeCandidates = [
            ReflectionMarkedExcerpt(text: "from A", evidenceIDs: ["A"]),
            ReflectionMarkedExcerpt(text: "from B", evidenceIDs: ["B"]),
            ReflectionMarkedExcerpt(text: "shared", evidenceIDs: ["A"]),
            ReflectionMarkedExcerpt(text: "shared", evidenceIDs: ["B"]),
            ReflectionMarkedExcerpt(text: "ungrounded", evidenceIDs: []),
        ]
        expect(ReflectionMarkScope.retained(
            scopeCandidates, allowedEvidenceIDs: ["B"])
            == [ReflectionMarkedExcerpt(text: "from B", evidenceIDs: ["B"]),
                ReflectionMarkedExcerpt(text: "shared", evidenceIDs: ["B"])],
            "marks from evidence A cannot cross a newly confirmed B-only scope")
        expect(ReflectionMarkScope.retained(
            scopeCandidates, allowedEvidenceIDs: ["A", "B"])
            .first(where: { $0.text == "shared" })?.evidenceIDs == ["A", "B"],
            "same-text marks merge all grounded sources when both are selected")
        expect(ReflectionMarkScope.retained(
            scopeCandidates, allowedEvidenceIDs: []).isEmpty,
            "marks fail closed when there is no confirmed evidence scope")

        var legacyMarks = [mark]
        var legacyConversation = ReflectionConversation(
            id: "reflection-main", title: "Mimo Reflection Browser",
            messages: [.init(
                id: "polluted-v1", role: .assistant,
                content: "A-derived highlight mislabeled as B", evidenceIDs: ["B"])])
        var legacySynthesis: LocalReflectionSynthesis? = synthesis
        var legacyDraft: SynthesisDraft? = draft
        expect(ReflectionPersistedStateSchema.currentVersion == 2
               && ReflectionPersistedStateSchema.requiresDerivedReset(from: 1),
               "v1 state requires a fail-closed derived-data migration")
        ReflectionPersistedStateSchema.resetDerivedState(
            marks: &legacyMarks, conversation: &legacyConversation,
            synthesis: &legacySynthesis, draft: &legacyDraft)
        expect(legacyMarks.isEmpty && legacyConversation.messages.isEmpty
               && legacySynthesis == nil && legacyDraft == nil,
               "v1 contaminated dialogue and derived drafts cannot enter v2 model history")
        expect(!ReflectionPersistedStateSchema.requiresDerivedReset(from: 2),
               "current v2 state remains intact")

        let repeated = "🌱 carry this thought, then carry this thought"
        let repeatedNSString = repeated as NSString
        let secondUTF16 = repeatedNSString.range(
            of: "carry this thought", options: .backwards)
        let exact = ReflectionTextRangeResolver.characterOffsets(
            in: repeated, selectedText: "carry this thought",
            utf16Location: secondUTF16.location,
            utf16Length: secondUTF16.length)
        expect(exact != nil,
               "WebKit UTF-16 coordinates resolve a repeated selection exactly")
        expect(exact.flatMap {
            ReflectionTextRangeResolver.utf16Range(
                in: repeated, location: $0.location, length: $0.length)
        } == secondUTF16,
        "persisted character offsets round-trip to the selected repeated phrase")
        expect(ReflectionTextRangeResolver.characterOffsets(
            in: repeated, selectedText: "carry this thought",
            utf16Location: nil, utf16Length: nil) == nil,
        "text-only duplicate selections fail closed instead of moving to the first phrase")
        expect(ReflectionTextRangeResolver.characterOffsets(
            in: "哈哈哈", selectedText: "哈哈",
            utf16Location: nil, utf16Length: nil) == nil,
        "text-only fallback also rejects overlapping repeated phrases")
        expect(ReflectionTextRangeResolver.characterOffsets(
            in: repeated, selectedText: "🌱",
            utf16Location: nil, utf16Length: nil)?.location == 0,
        "legacy unique text marks remain recoverable")

        print("reflection core tests passed")
    }
}
