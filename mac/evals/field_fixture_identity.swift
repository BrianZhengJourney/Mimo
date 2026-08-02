import Foundation

enum DIYFieldFixtureIdentityError: Error {
    case invalidRecord
}

struct DIYFieldFixtureIdentity: Codable, Equatable {
    private struct Record: Decodable {
        let schemaVersion: Int
        let id: String
        let characterID: String
        let actionID: String
        let contractRevision: Int?
        let quality: String
        let estimatedProviderCalls: Int
    }

    let id: String
    let characterID: String
    let actionID: String
    let effectiveContractRevision: Int
    let quality: String
    let estimatedProviderCalls: Int

    init(recordData: Data) throws {
        guard recordData.count <= 64 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: recordData),
              record.schemaVersion == 1,
              UUID(uuidString: record.id)?.uuidString.lowercased() == record.id,
              record.characterID.hasPrefix("custom:"),
              UUID(uuidString: String(record.characterID.dropFirst("custom:".count)))?
                .uuidString.lowercased()
                == String(record.characterID.dropFirst("custom:".count)),
              ["gaze", "sleep", "tennis", "wall"].contains(record.actionID),
              ["low", "medium", "high"].contains(record.quality),
              (1...100).contains(record.contractRevision ?? 1),
              (1...20).contains(record.estimatedProviderCalls) else {
            throw DIYFieldFixtureIdentityError.invalidRecord
        }
        id = record.id
        characterID = record.characterID
        actionID = record.actionID
        effectiveContractRevision = record.contractRevision ?? 1
        quality = record.quality
        estimatedProviderCalls = record.estimatedProviderCalls
    }
}
