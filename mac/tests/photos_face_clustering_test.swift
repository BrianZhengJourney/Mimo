// sources: prototypes/apple-photos-people/photos_face_clustering.swift
import Foundation

@main
struct PhotosFaceClusteringTests {
    static func sample(_ index: Int, _ asset: String, _ angle: Float)
        -> PhotosFaceClusterSample {
        PhotosFaceClusterSample(
            index: index,
            assetID: asset,
            captureQuality: 1,
            embedding: PhotosFaceIdentityEmbedding(
                vector: [cos(angle), sin(angle), 0], rawNorm: 1))
    }

    static func testPoseVerifierBridgesUniquePair() {
        let samples = [
            sample(0, "a0", 0.00), sample(1, "a1", 0.03),
            sample(2, "b0", 0.12), sample(3, "b1", 0.15),
            sample(4, "c0", 1.30), sample(5, "c1", 1.34),
        ]
        let groups = PhotosFaceClusterer.bridgeStableGroups(
            [[0, 1], [2, 3], [4, 5]], verifierSamples: samples)
        precondition(groups.count == 2, "unique pose split should bridge")
        precondition(Set(groups[0]) == Set([0, 1, 2, 3]),
                     "bridge must combine only the matching groups")
    }

    static func testAmbiguousTriangleDoesNotBridge() {
        let samples = [
            sample(0, "a0", 0.00), sample(1, "a1", 0.01),
            sample(2, "b0", 0.08), sample(3, "b1", 0.09),
            sample(4, "c0", 0.16), sample(5, "c1", 0.17),
        ]
        let groups = PhotosFaceClusterer.bridgeStableGroups(
            [[0, 1], [2, 3], [4, 5]], verifierSamples: samples)
        precondition(groups.count == 3,
                     "verifier must abstain without a clear runner-up margin")
    }

    static func testSamePhotoCannotLinkSurvivesVerifier() {
        let samples = [
            sample(0, "shared", 0.00), sample(1, "a1", 0.03),
            sample(2, "shared", 0.04), sample(3, "b1", 0.06),
        ]
        let groups = PhotosFaceClusterer.bridgeStableGroups(
            [[0, 1], [2, 3]], verifierSamples: samples)
        precondition(groups.count == 2,
                     "people appearing in one photo must never be merged")
    }

    static func testFewDuplicateDetectionsDoNotBlockLargeIdentity() {
        var samples: [PhotosFaceClusterSample] = []
        for index in 0..<20 {
            samples.append(sample(
                index, index < 3 ? "duplicate\(index)" : "a\(index)",
                Float(index) * 0.001))
        }
        for index in 20..<40 {
            samples.append(sample(
                index, index < 23 ? "duplicate\(index - 20)" : "b\(index)",
                0.12 + Float(index - 20) * 0.001))
        }
        samples.append(sample(40, "c0", 1.3))
        samples.append(sample(41, "c1", 1.34))
        let groups = PhotosFaceClusterer.bridgeStableGroups(
            [Array(0..<20), Array(20..<40), [40, 41]],
            verifierSamples: samples)
        precondition(groups.count == 2 && groups[0].count == 40,
                     "a few rare duplicate detections should be tolerated")
    }

    static func testFrequentCooccurrenceStillBlocksBridge() {
        var samples: [PhotosFaceClusterSample] = []
        for index in 0..<20 {
            samples.append(sample(
                index, index < 4 ? "shared\(index)" : "a\(index)",
                Float(index) * 0.001))
        }
        for index in 20..<40 {
            samples.append(sample(
                index, index < 24 ? "shared\(index - 20)" : "b\(index)",
                0.12 + Float(index - 20) * 0.001))
        }
        let groups = PhotosFaceClusterer.bridgeStableGroups(
            [Array(0..<20), Array(20..<40)], verifierSamples: samples)
        precondition(groups.count == 2,
                     "frequent co-occurrence must remain a cannot-link")
    }

    static func main() {
        testPoseVerifierBridgesUniquePair()
        testAmbiguousTriangleDoesNotBridge()
        testSamePhotoCannotLinkSurvivesVerifier()
        testFewDuplicateDetectionsDoNotBlockLargeIdentity()
        testFrequentCooccurrenceStillBlocksBridge()
        print("photos face clustering tests passed")
    }
}
