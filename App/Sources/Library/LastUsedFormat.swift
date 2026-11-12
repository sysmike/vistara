import Foundation

/// "Today", "Yesterday", or a date, as the design asks for lists.
enum LastUsedFormat {
    static func string(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Never" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
