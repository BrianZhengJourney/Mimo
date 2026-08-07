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

        let googleImage = PetReferenceImportPolicy.remoteImageURL(
            from: "https://images.example.com/pets/mimo.png?size=large#preview")
        expect(googleImage?.absoluteString ==
               "https://images.example.com/pets/mimo.png?size=large",
               "a dragged HTTPS image URL should be accepted without its fragment")
        expect(PetReferenceImportPolicy.remoteImageURL(
            from: "http://images.example.com/mimo.png") == nil,
               "web references must use HTTPS")
        expect(PetReferenceImportPolicy.remoteImageURL(
            from: "file:///Users/example/secret.png") == nil,
               "a web drop must never turn a file URL into an arbitrary local read")
        expect(PetReferenceImportPolicy.remoteImageURL(
            from: "https://localhost:8443/mimo.png") == nil,
               "web references must not reach localhost")
        expect(PetReferenceImportPolicy.remoteImageURL(
            from: "https://127.0.0.1/mimo.png") == nil,
               "web references must not reach loopback IPs")
        expect(PetReferenceImportPolicy.acceptsResponseContentType("image/webp"),
               "common browser image content types should be accepted")
        expect(PetReferenceImportPolicy.acceptsResponseContentType("application/octet-stream"),
               "generic CDN responses should be sniffed locally as images")
        expect(!PetReferenceImportPolicy.acceptsResponseContentType("text/html"),
               "an HTML response must not enter image decoding")
        expect(PetReferenceImportPolicy.displayName(
            for: googleImage!) == "mimo",
               "the reference tray should get a readable name from the image URL")

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
