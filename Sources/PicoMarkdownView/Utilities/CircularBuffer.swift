import Foundation

/// Fixed-size circular buffer storing the most recent scalars for bounded look-behind.
struct CircularBuffer<Element> {
    private var storage: [Element?]
    private var head: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        storage = Array(repeating: nil, count: capacity)
    }

    var capacity: Int { storage.count }

    mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            storage = Array(repeating: nil, count: capacity)
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        count = 0
    }

    func recent(_ limit: Int) -> [Element] {
        guard count > 0 else { return [] }
        let actual = min(limit, count)
        var result: [Element] = []
        result.reserveCapacity(actual)
        for offset in 0..<actual {
            let index = (head - offset - 1 + capacity) % capacity
            if let element = storage[index] {
                result.append(element)
            }
        }
        return result.reversed()
    }
}
