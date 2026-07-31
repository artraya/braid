import Foundation

/// Display formatting for domain values. Lives in Core with the values it
/// formats, and so that it can be tested.
public enum Format {
    /// "4:12", or "1:02:03" once past an hour. Matches the durations in the
    /// session list rather than the transcript's padded HH:MM:SS.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total / 60) % 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "00:12:16" for the HUD clock, which should not change width as it runs.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// "Today 09:14", "Tue", "3 Jun" — enough to place a session without
    /// spelling out a full date for something that happened this morning.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_AU")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today \(time.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time.string(from: date))"
        }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = days < 7 ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }

    public static func money(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }
}
