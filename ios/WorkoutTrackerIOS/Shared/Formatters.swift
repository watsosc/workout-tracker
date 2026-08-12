import Foundation

enum Formatters {
    static func dateTime(_ value: String?) -> String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func shortDate(_ value: String?) -> String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        let mins = seconds / 60
        let secs = seconds % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
