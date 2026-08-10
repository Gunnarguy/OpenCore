import Foundation

/// Reduces a SQL statement to a short, stable label like `SELECT object` or `INSERT chunk`.
///
/// Telemetry names statements by shape rather than by text for two reasons. A 400-character
/// `SELECT` makes the tree unreadable, and more importantly the same statement issued 2,000
/// times has to collapse to one row in a summary, which only works if repeated calls produce
/// an identical name.
///
/// Statement text in this project is always a literal — values arrive through `SQLValue`
/// bindings, never interpolation, per `.claude/rules/store.md` — so a label derived from it
/// cannot leak user data. That property is what makes this safe to record at all.
enum SQLShape {
    static func of(_ sql: String) -> String {
        let words = sql
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "();,")) }
            .filter { !$0.isEmpty }

        guard let verb = words.first?.uppercased() else { return "SQL" }

        // The table sits in a different position per verb, so each is read rather than
        // guessed. Anything unrecognised falls back to the bare verb, which is still a more
        // useful grouping than the full text.
        let table: String?
        switch verb {
        case "SELECT":
            table = words.firstIndex { $0.uppercased() == "FROM" }.flatMap { index in
                index + 1 < words.count ? words[index + 1] : nil
            }
        case "INSERT", "REPLACE":
            table = words.firstIndex { $0.uppercased() == "INTO" }.flatMap { index in
                index + 1 < words.count ? words[index + 1] : nil
            }
        case "UPDATE", "PRAGMA":
            table = words.count > 1 ? words[1] : nil
        case "DELETE":
            table = words.firstIndex { $0.uppercased() == "FROM" }.flatMap { index in
                index + 1 < words.count ? words[index + 1] : nil
            }
        default:
            table = nil
        }

        guard let table, !table.isEmpty else { return verb }
        return "\(verb) \(table)"
    }
}
