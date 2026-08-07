// Mimo Studio — provider-free local processing checkpoint.

import Foundation

enum StudioLocalRecoveryKind: String, Codable {
    case candidates
    case evolution
    case replacement
}

/// The paid raw PNG lives once in GenerationDrafts. This recipe records how
/// to finish local processing without submitting another provider request.
struct StudioLocalRecoveryCheckpoint: Codable, Equatable {
    var requestID: String
    var kind: StudioLocalRecoveryKind
    var sourceDataURI: String?
    var referenceEvidenceJSON: String?
    var styleTuningNote: String
    var temperamentID: String?
    var likeness: Double?
    var styleProfile: String?
    var providerSeconds: Double
    var usage: [String: Int]
    var styleBoardUsed: Bool
    var mode: String?
    var masterPNG: Data?
    var draftFeedback: String?
    var selectedCandidateIndex: Int?
    var quality: String?
    var candidateDraftID: String?
    var parentDraftID: String?
    var stage: String?
    var createdAt: Date

    var operation: String {
        switch kind {
        case .candidates: return mode == "variations" ? "variations" : "candidates"
        case .evolution: return "evolution"
        case .replacement: return "stage"
        }
    }
}
