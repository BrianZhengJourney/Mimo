// Mimo Today Journal — local, Graphology-compatible journey snapshots.
//
// Activity events remain the source of truth. This file only persists a
// rebuildable graph projection: chronological edges show what happened next,
// return edges show when attention came back, and clusters group nearby work.

import Foundation

struct JourneyGraphArchive: Codable, Equatable {
    static let schemaVersion = 2

    var schemaVersion = Self.schemaVersion
    var options = JourneyGraphOptions()
    var attributes: JourneyGraphAttributes
    var nodes: [JourneyGraphNode]
    var edges: [JourneyGraphEdge]
    var clusters: [JourneyGraphCluster]

    func jsonObject() -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }
}

struct JourneyGraphOptions: Codable, Equatable {
    var type = "directed"
    var multi = false
    var allowSelfLoops = false
}

struct JourneyGraphAttributes: Codable, Equatable {
    var kind = "mimo-computer-use-journey"
    var rangeStartMS: Double
    var rangeEndMS: Double
    var generatedAtMS: Double
}

struct JourneyGraphNode: Codable, Equatable {
    var key: String
    var attributes: JourneyGraphNodeAttributes
}

struct JourneyGraphNodeAttributes: Codable, Equatable {
    var blockID: String
    var title: String
    var category: String
    var startedAtMS: Double
    var endedAtMS: Double
    var activeDurationMS: Double
    var identityKey: String
    var identityLabel: String
    var occurrence: Int
    var clusterID: String
}

struct JourneyGraphEdge: Codable, Equatable {
    var key: String
    var source: String
    var target: String
    var attributes: JourneyGraphEdgeAttributes
}

struct JourneyGraphEdgeAttributes: Codable, Equatable {
    var kind: String
    var gapMS: Double
}

struct JourneyGraphCluster: Codable, Equatable {
    var id: String
    var category: String
    var label: String
    var nodeKeys: [String]
    var startedAtMS: Double
    var endedAtMS: Double
    var topicKey: String?
    var keywords: [String]?
    var priorDayCount: Int?
    var lastSeenAtMS: Double?
}

/// Sparse user corrections layered over the rebuildable automatic graph.
/// Raw activity and automatic clustering remain untouched, so edits can be
/// reset instantly and survive graph refreshes without copying event data.
struct JourneyGraphCorrections: Codable, Equatable {
    var labels: [String: String] = [:]
    var merges: [String: String] = [:]

    var isEmpty: Bool { labels.isEmpty && merges.isEmpty }

    func applying(to input: JourneyGraphArchive) -> JourneyGraphArchive {
        guard !isEmpty, !input.clusters.isEmpty else { return input }
        let knownIDs = Set(input.clusters.map(\.id))

        func resolvedTarget(for source: String) -> String {
            var current = source
            var visited = Set<String>()
            while let next = merges[current], knownIDs.contains(next), next != current {
                guard !visited.contains(next) else { return source }
                visited.insert(current)
                current = next
            }
            return current
        }

        var groupOrder: [String] = []
        var groups: [String: [JourneyGraphCluster]] = [:]
        for cluster in input.clusters {
            let target = resolvedTarget(for: cluster.id)
            if groups[target] == nil { groupOrder.append(target) }
            groups[target, default: []].append(cluster)
        }

        let nodeOrder = Dictionary(uniqueKeysWithValues: input.nodes.enumerated().map {
            ($0.element.key, $0.offset)
        })
        let clusters = groupOrder.compactMap { target -> JourneyGraphCluster? in
            guard let members = groups[target], !members.isEmpty else { return nil }
            let base = members.first(where: { $0.id == target }) ?? members[0]
            let nodeKeys = Array(Set(members.flatMap(\.nodeKeys))).sorted {
                (nodeOrder[$0] ?? .max) < (nodeOrder[$1] ?? .max)
            }
            let keywords = Array(Set(members.flatMap { $0.keywords ?? [] })).sorted()
            return JourneyGraphCluster(
                id: target, category: base.category,
                label: labels[target] ?? base.label,
                nodeKeys: nodeKeys,
                startedAtMS: members.map(\.startedAtMS).min() ?? base.startedAtMS,
                endedAtMS: members.map(\.endedAtMS).max() ?? base.endedAtMS,
                topicKey: base.topicKey, keywords: Array(keywords.prefix(8)),
                priorDayCount: members.compactMap(\.priorDayCount).max(),
                lastSeenAtMS: members.compactMap(\.lastSeenAtMS).max())
        }

        var output = input
        output.clusters = clusters
        let membership = Dictionary(uniqueKeysWithValues: clusters.flatMap { cluster in
            cluster.nodeKeys.map { ($0, cluster.id) }
        })
        for index in output.nodes.indices {
            if let clusterID = membership[output.nodes[index].key] {
                output.nodes[index].attributes.clusterID = clusterID
            }
        }

        // Topic-return edges are a projection of cluster membership. Rebuild
        // them after merges instead of leaving visually plausible but false
        // edges from the previous automatic layout.
        output.edges.removeAll { $0.attributes.kind == "topic-return" }
        let explicitReturns = Set(output.edges.filter {
            $0.attributes.kind == "return"
        }.map { "\($0.source)\u{1f}\($0.target)" })
        for cluster in clusters {
            let indices = cluster.nodeKeys.compactMap { nodeOrder[$0] }.sorted()
            for pair in zip(indices, indices.dropFirst()) where pair.1 != pair.0 + 1 {
                let source = output.nodes[pair.0], target = output.nodes[pair.1]
                guard !explicitReturns.contains("\(source.key)\u{1f}\(target.key)") else {
                    continue
                }
                output.edges.append(.init(
                    key: "topic-return-corrected-\(cluster.id)-\(pair.0)-\(pair.1)",
                    source: source.key, target: target.key,
                    attributes: .init(
                        kind: "topic-return",
                        gapMS: max(0, target.attributes.startedAtMS
                                   - source.attributes.endedAtMS))))
            }
        }
        return output
    }
}

private struct ActivityTopicCluster {
    var id: String
    var category: ActivityCategory
    var label: String
    var blockIDs: [String]
    var startedAtMS: Double
    var endedAtMS: Double
    var topicKey: String
    var keywords: [String]
}

private enum ActivityTopicClusterer {
    private struct Profile {
        var tokens: Set<String>
        var tokenWeights: [String: Double]
        var apps: Set<String>
        var domains: Set<String>
    }

    private struct WorkingCluster {
        var category: ActivityCategory
        var blockIDs: [String]
        var titles: [(String, Double)]
        var tokenWeights: [String: Double]
        var apps: Set<String>
        var domains: Set<String>
        var startedAtMS: Double
        var endedAtMS: Double
    }

    static func build(snapshot: DailyActivitySnapshot,
                      blocks: [ActivityBlock]) -> [ActivityTopicCluster] {
        let events = Dictionary(uniqueKeysWithValues: snapshot.events.map { ($0.id, $0) })
        var working: [WorkingCluster] = []
        for block in blocks {
            let profile = profile(for: block, events: events)
            let best = working.indices.map { index in
                (index, score(profile: profile, block: block, cluster: working[index]))
            }.max { $0.1 < $1.1 }
            let target = best.flatMap { $0.1 >= 0.48 ? $0.0 : nil }
            if let index = target {
                working[index].blockIDs.append(block.id)
                working[index].titles.append((block.title, block.activeDurationMS))
                for (token, weight) in profile.tokenWeights {
                    working[index].tokenWeights[token, default: 0] += weight
                }
                working[index].apps.formUnion(profile.apps)
                working[index].domains.formUnion(profile.domains)
                working[index].startedAtMS = min(
                    working[index].startedAtMS, block.startedAtMS)
                working[index].endedAtMS = max(
                    working[index].endedAtMS, block.endedAtMS)
            } else {
                working.append(.init(
                    category: block.category, blockIDs: [block.id],
                    titles: [(block.title, block.activeDurationMS)],
                    tokenWeights: profile.tokenWeights,
                    apps: profile.apps, domains: profile.domains,
                    startedAtMS: block.startedAtMS, endedAtMS: block.endedAtMS))
            }
        }
        return working.map { cluster in
            let keywords = cluster.tokenWeights.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(5).map(\.key)
            let label = cluster.titles.max {
                $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 < $1.1
            }?.0 ?? keywords.first ?? cluster.category.rawValue
            let identityFallback = cluster.domains.sorted().first
                ?? cluster.apps.sorted().first ?? label.lowercased()
            let keyParts = keywords.prefix(3)
            let keySource = keyParts.isEmpty ? identityFallback
                : keyParts.joined(separator: "|")
            let topicKey = "\(cluster.category.rawValue)|\(keySource)"
            return ActivityTopicCluster(
                id: stableGraphID(prefix: "topic", value: topicKey),
                category: cluster.category, label: String(label.prefix(64)),
                blockIDs: cluster.blockIDs,
                startedAtMS: cluster.startedAtMS, endedAtMS: cluster.endedAtMS,
                topicKey: topicKey, keywords: Array(keywords))
        }.sorted { $0.startedAtMS < $1.startedAtMS }
    }

    private static func profile(for block: ActivityBlock,
                                events: [String: ActivityEvent]) -> Profile {
        var weights: [String: Double] = [:]
        let evidence = block.eventIDs.compactMap { events[$0] }
        let titles = evidence.map(\.displayTitle) + [block.title]
        for title in titles {
            for token in tokens(title) { weights[token, default: 0] += 1 }
        }
        if weights.isEmpty {
            for app in block.apps {
                for token in tokens(app) { weights[token, default: 0] += 0.7 }
            }
        }
        return Profile(
            tokens: Set(weights.keys), tokenWeights: weights,
            apps: Set(block.apps.map(normalizeIdentity)),
            domains: Set(block.domains.map(normalizeIdentity)))
    }

    private static func score(profile: Profile, block: ActivityBlock,
                              cluster: WorkingCluster) -> Double {
        let known = Set(cluster.tokenWeights.keys)
        let shared = profile.tokens.intersection(known)
        let denominator = max(1, min(profile.tokens.count, known.count))
        var value = 0.62 * Double(shared.count) / Double(denominator)
        if shared.contains(where: highSignal) { value += 0.34 }
        if !profile.domains.isDisjoint(with: cluster.domains) { value += 0.22 }
        if !profile.apps.isDisjoint(with: cluster.apps) { value += 0.12 }
        if block.category == cluster.category { value += 0.07 }
        if block.startedAtMS - cluster.endedAtMS <= 90 * 60_000 { value += 0.05 }
        return value
    }

    private static func tokens(_ value: String) -> Set<String> {
        let normalized = value.lowercased().folding(
            options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let pieces = normalized.components(separatedBy:
            CharacterSet.alphanumerics.union(.letters).inverted)
        var output = Set(pieces.filter { token in
            token.count >= 2 && !stopWords.contains(token)
        })
        let cjkRuns = normalized.unicodeScalars.split { scalar in
            !(0x3400...0x9fff).contains(Int(scalar.value))
        }
        for run in cjkRuns {
            let values = Array(run)
            if values.count <= 4, values.count >= 2 {
                output.insert(String(String.UnicodeScalarView(values)))
            }
            if values.count >= 2 {
                for index in 0..<(values.count - 1) {
                    output.insert(String(String.UnicodeScalarView(values[index...index + 1])))
                }
            }
        }
        return output
    }

    private static func normalizeIdentity(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "www.", with: "")
    }

    private static func highSignal(_ token: String) -> Bool {
        token.count >= 4 && !genericWords.contains(token)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "your", "this", "that",
        "google", "search", "chrome", "safari", "browser", "window", "home",
        "page", "new", "tab", "www", "com", "today", "untitled", "document",
    ]
    private static let genericWords: Set<String> = stopWords.union([
        "project", "design", "notes", "work", "activity", "discussion",
    ])
}

enum JourneyGraphBuilder {
    private struct WorkingNode {
        var block: ActivityBlock
        var identityKey: String
        var identityLabel: String
        var occurrence: Int
        var clusterID = ""
    }

    static func build(snapshot: DailyActivitySnapshot,
                      generatedAt: Date = Date()) -> JourneyGraphArchive {
        let blocks = snapshot.blocks.sorted {
            $0.startedAtMS == $1.startedAtMS ? $0.id < $1.id
                : $0.startedAtMS < $1.startedAtMS
        }
        var identityCounts: [String: Int] = [:]
        var working = blocks.map { block -> WorkingNode in
            let identity = identity(for: block)
            let occurrence = identityCounts[identity.key, default: 0] + 1
            identityCounts[identity.key] = occurrence
            return WorkingNode(block: block, identityKey: identity.key,
                               identityLabel: identity.label,
                               occurrence: occurrence)
        }

        let topics = ActivityTopicClusterer.build(snapshot: snapshot, blocks: blocks)
        var topicByBlock: [String: String] = [:]
        for topic in topics {
            for blockID in topic.blockIDs { topicByBlock[blockID] = topic.id }
        }
        for index in working.indices {
            working[index].clusterID = topicByBlock[working[index].block.id] ?? ""
        }
        let clusters = topics.map { topic in
            JourneyGraphCluster(
                id: topic.id, category: topic.category.rawValue,
                label: topic.label, nodeKeys: topic.blockIDs,
                startedAtMS: topic.startedAtMS, endedAtMS: topic.endedAtMS,
                topicKey: topic.topicKey, keywords: topic.keywords,
                priorDayCount: nil, lastSeenAtMS: nil)
        }

        let nodes = working.map { node in
            JourneyGraphNode(key: node.block.id, attributes: .init(
                blockID: node.block.id, title: node.block.title,
                category: node.block.category.rawValue,
                startedAtMS: node.block.startedAtMS,
                endedAtMS: node.block.endedAtMS,
                activeDurationMS: node.block.activeDurationMS,
                identityKey: node.identityKey, identityLabel: node.identityLabel,
                occurrence: node.occurrence, clusterID: node.clusterID))
        }

        var edges: [JourneyGraphEdge] = []
        for index in working.indices.dropFirst() {
            let prior = working[index - 1].block
            let current = working[index].block
            edges.append(.init(
                key: "sequence-\(index)", source: prior.id, target: current.id,
                attributes: .init(kind: "sequence",
                                  gapMS: max(0, current.startedAtMS - prior.endedAtMS))))
        }
        var lastIdentityIndex: [String: Int] = [:]
        var returnPairs = Set<String>()
        for index in working.indices {
            let current = working[index]
            if let priorIndex = lastIdentityIndex[current.identityKey],
               priorIndex != index - 1 {
                let prior = working[priorIndex].block
                edges.append(.init(
                    key: "return-\(priorIndex)-\(index)", source: prior.id,
                    target: current.block.id,
                    attributes: .init(
                        kind: "return",
                        gapMS: max(0, current.block.startedAtMS - prior.endedAtMS))))
                returnPairs.insert("\(priorIndex):\(index)")
            }
            lastIdentityIndex[current.identityKey] = index
        }
        let indexByBlock = Dictionary(uniqueKeysWithValues: working.enumerated().map {
            ($0.element.block.id, $0.offset)
        })
        for topic in topics {
            let indices = topic.blockIDs.compactMap { indexByBlock[$0] }.sorted()
            for pair in zip(indices, indices.dropFirst()) where pair.1 != pair.0 + 1 {
                guard !returnPairs.contains("\(pair.0):\(pair.1)") else { continue }
                let prior = working[pair.0].block, current = working[pair.1].block
                edges.append(.init(
                    key: "topic-return-\(pair.0)-\(pair.1)", source: prior.id,
                    target: current.id, attributes: .init(
                        kind: "topic-return",
                        gapMS: max(0, current.startedAtMS - prior.endedAtMS))))
            }
        }

        return JourneyGraphArchive(
            attributes: .init(
                rangeStartMS: snapshot.range.start.timeIntervalSince1970 * 1_000,
                rangeEndMS: snapshot.range.end.timeIntervalSince1970 * 1_000,
                generatedAtMS: generatedAt.timeIntervalSince1970 * 1_000),
            nodes: nodes, edges: edges, clusters: clusters)
    }

    private static func identity(for block: ActivityBlock) -> (key: String, label: String) {
        if let domain = block.domains.first?.lowercased(), !domain.isEmpty {
            return ("site:\(domain)", domain.replacingOccurrences(of: "www.", with: ""))
        }
        if let app = block.apps.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty {
            return ("app:\(app.lowercased())", app)
        }
        let title = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("title:\(title.lowercased())", title)
    }
}

private func stableGraphID(prefix: String, value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 { hash ^= UInt64(byte); hash = hash &* 1_099_511_628_211 }
    return "\(prefix)-\(String(hash, radix: 16))"
}

final class JourneyGraphStore {
    static let filePrefix = "journey-graph-"
    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    func save(_ archive: JourneyGraphArchive) throws {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: fileURL(for: archive), options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL(for: archive).path)
        pruneUnlocked(keeping: 35)
    }

    /// Adds honest cross-day recurrence metadata without copying historical
    /// raw events into today's payload. The graph stays small while still
    /// answering “have I been here before?”.
    func enrichingWithHistory(_ input: JourneyGraphArchive) -> JourneyGraphArchive {
        lock.lock(); defer { lock.unlock() }
        let history = graphURLsUnlocked().compactMap(loadUnlocked).filter {
            $0.attributes.rangeEndMS <= input.attributes.rangeStartMS
        }
        guard !history.isEmpty else { return input }
        var output = input
        for index in output.clusters.indices {
            let current = output.clusters[index]
            var days = Set<String>(), lastSeen: Double?
            for archive in history {
                guard archive.clusters.contains(where: {
                    Self.sameTopic(current, $0)
                }) else { continue }
                days.insert(Self.dayString(archive.attributes.rangeStartMS))
                let candidate = archive.clusters.filter {
                    Self.sameTopic(current, $0)
                }.map(\.endedAtMS).max() ?? archive.attributes.rangeEndMS
                lastSeen = max(lastSeen ?? candidate, candidate)
            }
            output.clusters[index].priorDayCount = days.count
            output.clusters[index].lastSeenAtMS = lastSeen
        }
        return output
    }

    func recentArchives(limit: Int = 35) -> [JourneyGraphArchive] {
        lock.lock(); defer { lock.unlock() }
        return graphURLsUnlocked().suffix(max(0, limit)).compactMap(loadUnlocked)
    }

    @discardableResult
    func purgeAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let urls = graphURLsUnlocked()
        var succeeded = true
        for url in urls {
            do { try fileManager.removeItem(at: url) }
            catch { succeeded = false }
        }
        return succeeded
    }

    private func fileURL(for archive: JourneyGraphArchive) -> URL {
        let start = Self.dayString(archive.attributes.rangeStartMS)
        let end = Self.dayString(max(
            archive.attributes.rangeStartMS,
            archive.attributes.rangeEndMS - 1))
        return root.appendingPathComponent(
            "\(Self.filePrefix)\(start)-\(end).json", isDirectory: false)
    }

    private func graphURLsUnlocked() -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []).filter {
                $0.lastPathComponent.hasPrefix(Self.filePrefix)
                    && $0.pathExtension.lowercased() == "json"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadUnlocked(_ url: URL) -> JourneyGraphArchive? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(JourneyGraphArchive.self, from: data),
              (1...JourneyGraphArchive.schemaVersion).contains(archive.schemaVersion)
        else { return nil }
        return archive
    }

    private func pruneUnlocked(keeping limit: Int) {
        let urls = graphURLsUnlocked()
        guard urls.count > limit else { return }
        for url in urls.prefix(urls.count - limit) { try? fileManager.removeItem(at: url) }
    }

    private static func dayString(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
    }

    private static func sameTopic(_ lhs: JourneyGraphCluster,
                                  _ rhs: JourneyGraphCluster) -> Bool {
        guard lhs.category == rhs.category else { return false }
        if let left = lhs.topicKey, let right = rhs.topicKey, left == right { return true }
        let left = Set(lhs.keywords ?? []), right = Set(rhs.keywords ?? [])
        guard !left.isEmpty, !right.isEmpty else {
            return lhs.label.caseInsensitiveCompare(rhs.label) == .orderedSame
        }
        let shared = left.intersection(right).count
        return Double(shared) / Double(max(1, min(left.count, right.count))) >= 0.6
    }
}
