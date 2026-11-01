/// An empty discovery or failed read is not evidence that hardware control is working.
public struct DisplayControlReadHealth: Sendable, Equatable {
    public let attempted: Int
    public let readable: Int
    public var hasReadings: Bool { readable > 0 }
    public var message: String? {
        if attempted == 0 { return "No hardware control readings are available on this connection. Video and hardware control are separate capabilities." }
        if readable == 0 { return "The monitor did not return usable hardware control values. Previous values are not presented as current." }
        if readable < attempted { return "Some live reads are unavailable. Their previous values are not presented as current." }
        return nil
    }

    public init(values: [Int?]) {
        attempted = values.count
        readable = values.compactMap { $0 }.count
    }
}
