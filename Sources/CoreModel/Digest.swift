import CryptoKit
import Foundation

public enum Digest {
    /// SHA-256, truncated to 128 bits of hex. Long enough that a collision across a
    /// personal corpus is not a thing that happens; short enough to read in a terminal.
    public static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
