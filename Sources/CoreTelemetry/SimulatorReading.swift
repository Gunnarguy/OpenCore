import Foundation

public enum SimulatorReading {
    public struct Device: Sendable, Equatable {
        public let name: String
        public let udid: String
        public let runtime: String
    }
    private struct Payload: Decodable { let devices: [String: [Entry]] }
    private struct Entry: Decodable { let name: String; let udid: String; let state: String }

    /// Malformed output throws; it must never masquerade as a successful empty scan.
    public static func decode(_ data: Data) throws -> [Device] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.devices.flatMap { runtime, entries in
            entries.filter { $0.state == "Booted" }.map {
                Device(name: $0.name, udid: $0.udid,
                    runtime: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " "))
            }
        }.sorted { $0.name < $1.name }
    }
}
