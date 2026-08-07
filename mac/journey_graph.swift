// Mimo Today Journal — local, Graphology-compatible journey snapshots.
//
// Activity events remain the source of truth. This file only persists a
// rebuildable graph projection: chronological edges show what happened next,
// return edges show when attention came back, and clusters group nearby work.

import Foundation

struct JourneyGraphArchive: Codable, Equatable {
    static let schemaVersion = 1

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

        var clusters: [JourneyGraphCluster] = []
        for index in working.indices {
            let node = working[index]
            let prior = index > 0 ? working[index - 1] : nil
            let gap = prior.map { max(0, node.block.startedAtMS - $0.block.endedAtMS) }
                ?? .infinity
            let continues = prior?.block.category == node.block.category
                && gap <= 12 * 60_000
            if !continues {
                clusters.append(JourneyGraphCluster(
                    id: "cluster-\(clusters.count + 1)",
                    category: node.block.category.rawValue,
                    label: node.identityLabel,
                    nodeKeys: [], startedAtMS: node.block.startedAtMS,
                    endedAtMS: node.block.endedAtMS))
            }
            let clusterIndex = clusters.index(before: clusters.endIndex)
            working[index].clusterID = clusters[clusterIndex].id
            clusters[clusterIndex].nodeKeys.append(node.block.id)
            clusters[clusterIndex].endedAtMS = max(
                clusters[clusterIndex].endedAtMS, node.block.endedAtMS)
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
            }
            lastIdentityIndex[current.identityKey] = index
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
}
