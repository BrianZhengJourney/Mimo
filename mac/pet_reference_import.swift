// Mimo — bounded, sequential delivery for multi-photo reference imports.

import Foundation

enum PetReferenceImportPolicy {
    static let maximumReferences = 8

    static func selectionLimit(reportedRemaining: Int?) -> Int {
        max(0, min(maximumReferences,
                   reportedRemaining ?? maximumReferences))
    }
}

/// Runs one asynchronous delivery at a time. WKWebView can drop or reject
/// bursts of large evaluateJavaScript payloads, so reference data URIs must
/// cross the native-to-web bridge sequentially.
final class PetReferenceImportQueue<Item> {
    typealias Delivery = (Item, @escaping () -> Void) -> Void

    private let items: [Item]
    private let delivery: Delivery
    private let completion: () -> Void
    private var index = 0
    private var started = false

    init(items: [Item], delivery: @escaping Delivery,
         completion: @escaping () -> Void = {}) {
        self.items = items
        self.delivery = delivery
        self.completion = completion
    }

    func start() {
        guard !started else { return }
        started = true
        deliverNext()
    }

    private func deliverNext() {
        guard index < items.count else {
            completion()
            return
        }
        let item = items[index]
        index += 1
        delivery(item) { [weak self] in
            self?.deliverNext()
        }
    }
}
