// sources: character_sheet.swift action_sheet.swift
// compile-only: local-only postprocess for an already-paid M13...M16 repair
// Run:
//   action_inbetween_repair_finish OUTPUT_DIR OLD_MIDPOINT_STRIP REPAIR_STRIP KEYFRAME_STRIP

import Foundation

private func input(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

@main
struct ActionInbetweenRepairFinish {
    static func main() throws {
        guard CommandLine.arguments.count == 5 else {
            throw NSError(domain: "MimoRepairFinish", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid arguments"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let oldMidpoints = try input(CommandLine.arguments[2])
        let repair = try input(CommandLine.arguments[3])
        let keyframes = try input(CommandLine.arguments[4])
        let repairedMidpoints = try ActionSheetProcessor.replacingFrames(
            in: oldMidpoints, with: repair, at: [12, 13, 14, 15],
            normalizeSmallerRepairs: true)
        try repairedMidpoints.write(
            to: directory.appendingPathComponent("midpoint-strip-repaired.png"), options: [.atomic])
        let combined = try ActionSheetProcessor.interleaveStrips(
            keyframesPNG: keyframes, inbetweensPNG: repairedMidpoints)
        try combined.write(to: directory.appendingPathComponent("walk32-strip.png"), options: [.atomic])
        print("RESULT    locally normalized M13...M16 and rebuilt 32 frames")
    }
}
