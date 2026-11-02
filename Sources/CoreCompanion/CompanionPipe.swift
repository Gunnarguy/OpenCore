import Foundation
import Network

/// A transport seam lets lifecycle tests suspend a handshake without opening a socket.
public protocol CompanionTransport: Sendable {
    func secure(_ keys: CompanionSessionKeys) async
    func close() async
    func send<T: Encodable & Sendable>(_ value: T) async throws
    func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T
}

/// One reader and one writer per connection, owned by the client/server session actor.
/// Length limits are checked before allocation, including before authentication.
public actor CompanionPipe: CompanionTransport {
    public let connection: NWConnection
    private var sending: CompanionCipher?
    private var receiving: CompanionCipher?
    private var sendingMessage = false
    private var receivingMessage = false
    public init(_ connection: NWConnection) { self.connection = connection }
    public func secure(_ keys: CompanionSessionKeys) {
        sending = CompanionCipher(key: keys.sending); receiving = CompanionCipher(key: keys.receiving)
    }
    public func close() { connection.cancel() }
    public func send<T: Encodable & Sendable>(_ value: T) async throws {
        guard !sendingMessage else { throw CompanionError.busy }
        sendingMessage = true; defer { sendingMessage = false }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8_000_000 else { throw CompanionError.tooLarge } // Chosen memory ceiling, not a measurement.
        if var cipher = sending {
            for offset in stride(from: 0, to: max(1, data.count), by: 600) {
                try Task.checkCancellation()
                let end = min(offset + 600, data.count)
                let chunk = Data([end == data.count ? 1 : 0]) + data.subdata(in: offset..<end)
                try await writeFrame(cipher.seal(chunk))
            }
            sending = cipher
        } else {
            guard data.count <= 4096 else { throw CompanionError.tooLarge }
            try await writeFrame(data)
        }
    }
    public func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T {
        guard !receivingMessage else { throw CompanionError.busy }
        receivingMessage = true; defer { receivingMessage = false }
        var result = Data()
        if var cipher = receiving {
            var fragments = 0
            while true {
                fragments += 1
                guard fragments <= 14_000 else { throw CompanionError.tooLarge }
                let fragment = try cipher.open(await readFrame(maximum: 637))
                guard let last = fragment.first, last <= 1 else { throw CompanionError.invalidFrame }
                guard last == 1 || fragment.count > 1 else { throw CompanionError.invalidFrame }
                result.append(fragment.dropFirst())
                guard result.count <= 8_000_000 else { throw CompanionError.tooLarge }
                if last == 1 { break }
            }
            receiving = cipher
        } else { result = try await readFrame(maximum: 4096) }
        return try JSONDecoder().decode(type, from: result)
    }
    private func writeFrame(_ data: Data) async throws {
        let header = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: header + data, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: CompanionError.disconnected) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }
    private func readFrame(maximum: Int) async throws -> Data {
        let header = try await readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximum else { throw CompanionError.invalidFrame }
        return try await readExactly(Int(length))
    }
    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let connection = connection
            let remaining = count - result.count
            let piece: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        // A refused, reset or cancelled socket reads as the named failure. The phone
                        // otherwise shows a bare NWError number to someone standing at their Mac.
                        if error != nil { continuation.resume(throwing: CompanionError.disconnected) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: CompanionError.disconnected) }
                    }
                }
            } onCancel: { connection.cancel() }
            result.append(piece)
        }
        return result
    }
}
