// THROWAWAY PROTOTYPE — pure identity-vector clustering for Photos A/B.
//
// Question: after replacing generic image feature prints with dedicated face
// embeddings, can a conservative core pass plus quality-weighted template
// merging recover the few real people without single-link false merges?

import Foundation

enum PhotosFaceIdentityModel: Int, CaseIterable {
    case vision
    case ir101
    case kprpe

    var shortName: String {
        switch self {
        case .vision: return "Vision"
        case .ir101: return "IR101"
        case .kprpe: return "KP-RPE"
        }
    }
}

struct PhotosFaceIdentityEmbedding {
    let vector: [Float]
    let rawNorm: Float
}

struct PhotosFaceClusterSample {
    let index: Int
    let assetID: String
    let captureQuality: Float
    let embedding: PhotosFaceIdentityEmbedding
}

struct PhotosFaceClusterReport {
    let groups: [[Int]]

    var recurringCount: Int { groups.filter { $0.count >= 2 }.count }
    var singletonCount: Int { groups.filter { $0.count == 1 }.count }
}

struct PhotosFaceClusterPairDiagnostic {
    let firstGroup: Int
    let secondGroup: Int
    let firstSize: Int
    let secondSize: Int
    let centroidDistance: Float
    let nearestDistance: Float
    let tenthPercentileDistance: Float
    let reciprocalNearestMedian: Float
    let medianDistance: Float
    let sharedAssetCount: Int
}

enum PhotosFaceClusterer {
    static func cluster(
        samples: [PhotosFaceClusterSample], distanceThreshold: Float
    ) -> PhotosFaceClusterReport {
        guard !samples.isEmpty else { return PhotosFaceClusterReport(groups: []) }
        let ordered = samples.sorted { $0.index < $1.index }
        let count = ordered.count
        var distances = Array(
            repeating: Array(repeating: Float.greatestFiniteMagnitude, count: count),
            count: count)
        for first in 0..<count {
            distances[first][first] = 0
            guard first + 1 < count else { continue }
            for second in (first + 1)..<count {
                let distance = cosineDistance(
                    ordered[first].embedding.vector,
                    ordered[second].embedding.vector)
                distances[first][second] = distance
                distances[second][first] = distance
            }
        }

        // Phase one only accepts high-confidence evidence. This forms stable
        // identity cores without letting one ambiguous face bridge two people.
        let coreThreshold = max(0.16, distanceThreshold * 0.82)
        var partition = VectorPartition(samples: ordered)
        var edges: [(Float, Int, Int)] = []
        for first in 0..<count where first + 1 < count {
            for second in (first + 1)..<count
            where ordered[first].assetID != ordered[second].assetID
                && distances[first][second] <= coreThreshold {
                edges.append((distances[first][second], first, second))
            }
        }
        edges.sort { $0.0 < $1.0 }
        for (_, first, second) in edges {
            guard partition.canMerge(first, second) else { continue }
            let a = partition.root(of: first), b = partition.root(of: second)
            let evidence = crossDistances(
                partition.members[a], partition.members[b], distances: distances)
            guard median(evidence) <= coreThreshold * 1.06 else { continue }
            partition.merge(a, b)
        }

        var groups = partition.groups()
        let medianNorm = max(0.0001, median(ordered.map { $0.embedding.rawNorm }))

        // Phase two compares quality-weighted templates. Low-quality side
        // views may join an established person, but cannot create a chain.
        while groups.count > 1 {
            var best: (score: Float, first: Int, second: Int)?
            for first in 0..<groups.count where first + 1 < groups.count {
                for second in (first + 1)..<groups.count {
                    guard assetIDs(groups[first], samples: ordered).isDisjoint(
                        with: assetIDs(groups[second], samples: ordered)) else { continue }
                    let centroidA = centroid(
                        groups[first], samples: ordered, medianNorm: medianNorm)
                    let centroidB = centroid(
                        groups[second], samples: ordered, medianNorm: medianNorm)
                    let templateDistance = cosineDistance(centroidA, centroidB)
                    guard templateDistance <= distanceThreshold else { continue }

                    let evidence = crossDistances(
                        groups[first], groups[second], distances: distances).sorted()
                    guard let nearest = evidence.first,
                          nearest <= distanceThreshold * 1.08 else { continue }
                    let smallerCount = min(groups[first].count, groups[second].count)
                    if smallerCount >= 2 {
                        let supported = evidence.filter {
                            $0 <= distanceThreshold * 1.08
                        }.count
                        guard supported >= 2 else { continue }
                    }
                    let score = templateDistance + nearest * 0.15
                    if best == nil || score < best!.score {
                        best = (score, first, second)
                    }
                }
            }
            guard let best else { break }
            groups[best.first].append(contentsOf: groups[best.second])
            groups.remove(at: best.second)
        }

        groups.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            let lhs = $0.reduce(Float.zero) { $0 + ordered[$1].captureQuality }
            let rhs = $1.reduce(Float.zero) { $0 + ordered[$1].captureQuality }
            return lhs > rhs
        }
        return PhotosFaceClusterReport(
            groups: groups.map { group in group.map { ordered[$0].index } })
    }

    // IR101 is the stable primary grouping model. A pose-aware verifier may
    // only join two established groups when they are each other's unique
    // nearest neighbour with a clear margin. It never creates groups, attaches
    // singletons, or overrides repeated same-photo cannot-link evidence.
    static func bridgeStableGroups(
        _ baseGroups: [[Int]], verifierSamples: [PhotosFaceClusterSample],
        maximumDistance: Float = 0.15, minimumMargin: Float = 0.035
    ) -> [[Int]] {
        let ordered = verifierSamples.sorted { $0.index < $1.index }
        let position = Dictionary(uniqueKeysWithValues:
            ordered.indices.map { (ordered[$0].index, $0) })
        var groups = baseGroups

        while groups.count > 1 {
            var pairs: [(distance: Float, first: Int, second: Int)] = []
            for first in groups.indices where first + 1 < groups.count {
                guard groups[first].count >= 2 else { continue }
                for second in (first + 1)..<groups.count {
                    guard groups[second].count >= 2 else { continue }
                    let a = groups[first].compactMap { position[$0] }
                    let b = groups[second].compactMap { position[$0] }
                    guard !a.isEmpty, !b.isEmpty else { continue }
                    let sharedAssets = assetIDs(a, samples: ordered).intersection(
                        assetIDs(b, samples: ordered)).count
                    let smallerGroupCount = min(a.count, b.count)
                    // A few duplicate/reflection detections may put the same
                    // identity on both sides of a cannot-link. Frequent
                    // co-occurrence remains strong evidence of two people.
                    guard sharedAssets == 0 || (
                        sharedAssets <= 3
                            && Float(sharedAssets) / Float(smallerGroupCount) <= 0.15
                    ) else { continue }
                    let nearest = a.flatMap { left in b.map { right in
                        cosineDistance(ordered[left].embedding.vector,
                                       ordered[right].embedding.vector)
                    }}.min() ?? 2
                    pairs.append((nearest, first, second))
                }
            }

            var neighbours: [[(distance: Float, group: Int)]] =
                Array(repeating: [], count: groups.count)
            for pair in pairs {
                neighbours[pair.first].append((pair.distance, pair.second))
                neighbours[pair.second].append((pair.distance, pair.first))
            }
            for index in neighbours.indices {
                neighbours[index].sort { $0.distance < $1.distance }
            }

            let candidates = pairs.filter { pair in
                guard pair.distance <= maximumDistance,
                      neighbours[pair.first].first?.group == pair.second,
                      neighbours[pair.second].first?.group == pair.first else {
                    return false
                }
                let firstRunnerUp = neighbours[pair.first].dropFirst().first?.distance ?? 2
                let secondRunnerUp = neighbours[pair.second].dropFirst().first?.distance ?? 2
                return firstRunnerUp - pair.distance >= minimumMargin
                    && secondRunnerUp - pair.distance >= minimumMargin
            }.sorted { $0.distance < $1.distance }

            guard let best = candidates.first else { break }
            groups[best.first].append(contentsOf: groups[best.second])
            groups.remove(at: best.second)
        }

        let quality = Dictionary(uniqueKeysWithValues:
            ordered.map { ($0.index, $0.captureQuality) })
        return groups.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let lhs = $0.reduce(Float.zero) { $0 + (quality[$1] ?? 0) }
            let rhs = $1.reduce(Float.zero) { $0 + (quality[$1] ?? 0) }
            return lhs > rhs
        }
    }

    // Anonymous geometry only: useful for diagnosing over-split identities
    // without persisting photos, asset identifiers, or biometric vectors.
    static func pairDiagnostics(
        samples: [PhotosFaceClusterSample], groups: [[Int]]
    ) -> [PhotosFaceClusterPairDiagnostic] {
        let ordered = samples.sorted { $0.index < $1.index }
        let position = Dictionary(uniqueKeysWithValues:
            ordered.indices.map { (ordered[$0].index, $0) })
        let positionedGroups = groups.map { group in
            group.compactMap { position[$0] }
        }
        let medianNorm = max(0.0001, median(ordered.map { $0.embedding.rawNorm }))
        var result: [PhotosFaceClusterPairDiagnostic] = []
        for first in positionedGroups.indices where first + 1 < positionedGroups.count {
            for second in (first + 1)..<positionedGroups.count {
                let a = positionedGroups[first], b = positionedGroups[second]
                guard !a.isEmpty, !b.isEmpty else { continue }
                let distances = a.flatMap { left in b.map { right in
                    cosineDistance(ordered[left].embedding.vector,
                                   ordered[right].embedding.vector)
                }}.sorted()
                let reciprocal = (
                    a.map { left in b.map { right in
                        cosineDistance(ordered[left].embedding.vector,
                                       ordered[right].embedding.vector)
                    }.min() ?? 2 }
                    + b.map { right in a.map { left in
                        cosineDistance(ordered[left].embedding.vector,
                                       ordered[right].embedding.vector)
                    }.min() ?? 2 }
                ).sorted()
                let percentileIndex = min(
                    distances.count - 1,
                    Int((Float(distances.count - 1) * 0.10).rounded()))
                result.append(PhotosFaceClusterPairDiagnostic(
                    firstGroup: first + 1,
                    secondGroup: second + 1,
                    firstSize: a.count,
                    secondSize: b.count,
                    centroidDistance: cosineDistance(
                        centroid(a, samples: ordered, medianNorm: medianNorm),
                        centroid(b, samples: ordered, medianNorm: medianNorm)),
                    nearestDistance: distances[0],
                    tenthPercentileDistance: distances[percentileIndex],
                    reciprocalNearestMedian: reciprocal[reciprocal.count / 2],
                    medianDistance: distances[distances.count / 2],
                    sharedAssetCount: assetIDs(a, samples: ordered).intersection(
                        assetIDs(b, samples: ordered)).count))
            }
        }
        return result
    }

    private static func centroid(
        _ group: [Int], samples: [PhotosFaceClusterSample], medianNorm: Float
    ) -> [Float] {
        guard let first = group.first else { return [] }
        var sum = Array(repeating: Float.zero,
                        count: samples[first].embedding.vector.count)
        var totalWeight: Float = 0
        for index in group {
            let sample = samples[index]
            let normWeight = min(1.45, max(0.55,
                sample.embedding.rawNorm / medianNorm))
            let weight = max(0.18, sample.captureQuality) * normWeight
            for dimension in sum.indices {
                sum[dimension] += sample.embedding.vector[dimension] * weight
            }
            totalWeight += weight
        }
        guard totalWeight > 0 else { return sum }
        for index in sum.indices { sum[index] /= totalWeight }
        return normalized(sum)
    }

    private static func assetIDs(
        _ group: [Int], samples: [PhotosFaceClusterSample]
    ) -> Set<String> {
        Set(group.map { samples[$0].assetID })
    }

    private static func crossDistances(
        _ first: [Int], _ second: [Int], distances: [[Float]]
    ) -> [Float] {
        first.flatMap { a in second.map { b in distances[a][b] } }
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func cosineDistance(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return 2 }
        var dot: Float = 0, firstNorm: Float = 0, secondNorm: Float = 0
        for index in first.indices {
            dot += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        let denominator = sqrt(firstNorm * secondNorm)
        guard denominator > 0 else { return 2 }
        return max(0, min(2, 1 - dot / denominator))
    }
}

private struct VectorPartition {
    private(set) var parent: [Int]
    private(set) var members: [[Int]]
    private(set) var assetIDs: [Set<String>]

    init(samples: [PhotosFaceClusterSample]) {
        parent = Array(samples.indices)
        members = samples.indices.map { [$0] }
        assetIDs = samples.map { [$0.assetID] }
    }

    mutating func root(of index: Int) -> Int {
        var cursor = index
        while parent[cursor] != cursor { cursor = parent[cursor] }
        var path = index
        while parent[path] != path {
            let next = parent[path]
            parent[path] = cursor
            path = next
        }
        return cursor
    }

    mutating func canMerge(_ first: Int, _ second: Int) -> Bool {
        let a = root(of: first), b = root(of: second)
        return a != b && assetIDs[a].isDisjoint(with: assetIDs[b])
    }

    mutating func merge(_ first: Int, _ second: Int) {
        var a = root(of: first), b = root(of: second)
        guard a != b else { return }
        if members[a].count < members[b].count { swap(&a, &b) }
        parent[b] = a
        members[a].append(contentsOf: members[b])
        members[b].removeAll(keepingCapacity: false)
        assetIDs[a].formUnion(assetIDs[b])
        assetIDs[b].removeAll(keepingCapacity: false)
    }

    mutating func groups() -> [[Int]] {
        parent.indices.compactMap { root(of: $0) == $0 ? members[$0] : nil }
    }
}
