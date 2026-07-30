// sources: pet_reference_import.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct PetReferenceImportTests {
    static func main() {
        expect(PetReferenceImportPolicy.selectionLimit(reportedRemaining: nil) == 8,
               "legacy callers should retain the eight-photo limit")
        expect(PetReferenceImportPolicy.selectionLimit(reportedRemaining: 6) == 6,
               "the file panel should respect six remaining slots")
        expect(PetReferenceImportPolicy.selectionLimit(reportedRemaining: 99) == 8,
               "reported remaining slots must stay bounded")
        expect(PetReferenceImportPolicy.selectionLimit(reportedRemaining: -1) == 0,
               "negative remaining slots must not open the panel")

        var delivered: [Int] = []
        var completions: [() -> Void] = []
        var finished = false
        let queue = PetReferenceImportQueue(
            items: Array(0..<6),
            delivery: { item, completion in
                delivered.append(item)
                completions.append(completion)
            },
            completion: { finished = true })

        queue.start()
        queue.start()
        expect(delivered == [0], "only the first large payload should be in flight")
        for expected in 1..<6 {
            let completion = completions.removeFirst()
            completion()
            expect(delivered == Array(0...expected),
                   "delivery \(expected) should begin only after its predecessor")
        }
        expect(!finished, "the queue should wait for the final bridge receipt")
        completions.removeFirst()()
        expect(finished && delivered == Array(0..<6),
               "all six selected photos should reach the bridge in order")
        print("pet reference import tests passed")
    }
}
