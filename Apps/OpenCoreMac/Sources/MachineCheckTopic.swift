import Foundation

enum MachineCheckTopic: String, CaseIterable, Identifiable {
    case storage = "Storage"
    case duplicates = "Possible duplicates"
    case simulators = "Simulators"
    var id: String { rawValue }
}
