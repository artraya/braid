import Foundation

/// A delivered Session, kept so the app can show what it has produced. Job
/// state files are deleted on success and the Note lives in the Vault, so
/// without this the app has no memory of its own work.
public struct SessionRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var presetName: String
    public var startedAt: Date
    /// Recorded audio only, pauses excluded.
    public var recordedDuration: TimeInterval
    public var costUSD: Double
    public var notePath: String

    public init(id: String, title: String, presetName: String, startedAt: Date,
                recordedDuration: TimeInterval, costUSD: Double, notePath: String) {
        self.id = id
        self.title = title
        self.presetName = presetName
        self.startedAt = startedAt
        self.recordedDuration = recordedDuration
        self.costUSD = costUSD
        self.notePath = notePath
    }

    public init(session: Session, costUSD: Double, notePath: String) {
        self.init(id: session.id, title: session.title, presetName: session.presetName,
                  startedAt: session.startedAt, recordedDuration: session.recordedDuration,
                  costUSD: costUSD, notePath: notePath)
    }
}

/// This month's recording against the cap the user set.
public struct Usage: Sendable, Equatable {
    public let minutesUsed: Double
    public let minuteCap: Int
    public let costUSD: Double
    public let daysLeftInMonth: Int

    public init(minutesUsed: Double, minuteCap: Int, costUSD: Double, daysLeftInMonth: Int) {
        self.minutesUsed = minutesUsed
        self.minuteCap = minuteCap
        self.costUSD = costUSD
        self.daysLeftInMonth = daysLeftInMonth
    }

    /// Before anything has been recorded or loaded.
    public static let empty = Usage(minutesUsed: 0, minuteCap: 0, costUSD: 0, daysLeftInMonth: 0)

    /// 0…1, clamped, so the progress bar can be drawn straight from it.
    public var fraction: Double {
        guard minuteCap > 0 else { return 0 }
        return min(1, max(0, minutesUsed / Double(minuteCap)))
    }

    public var isNearCap: Bool { fraction >= 0.8 }
    public var isOverCap: Bool { minuteCap > 0 && minutesUsed >= Double(minuteCap) }
}

/// The delivered-Session log, one JSON file, newest first. Both the Job runner
/// and speaker naming write to it, so access is serialised.
public final class SessionIndex: @unchecked Sendable {
    /// Far more than a year of real use. Trimming the tail keeps monthly
    /// figures intact, which is all the usage card reads.
    public static let limit = 200

    private let url: URL
    private let lock = NSLock()

    public init(url: URL = JobQueue.appSupportURL.appendingPathComponent("sessions.json")) {
        self.url = url
    }

    /// Newest first.
    public func all() -> [SessionRecord] {
        lock.withLock { load() }
    }

    public func recent(_ count: Int) -> [SessionRecord] {
        Array(all().prefix(count))
    }

    public func add(_ record: SessionRecord) {
        lock.withLock {
            var records = load().filter { $0.id != record.id }
            records.insert(record, at: 0)
            save(Array(records.prefix(Self.limit)))
        }
    }

    /// Naming a Session's speakers re-runs the Summariser, so its cost grows
    /// after delivery.
    public func addCost(_ usd: Double, toSessionID id: String) {
        lock.withLock {
            var records = load()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].costUSD += usd
            save(records)
        }
    }

    public func usage(minuteCap: Int, now: Date = Date(),
                      calendar: Calendar = .current) -> Usage {
        let month = all().filter {
            calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month)
        }
        let minutes = month.reduce(0) { $0 + $1.recordedDuration } / 60
        let cost = month.reduce(0) { $0 + $1.costUSD }
        return Usage(minutesUsed: minutes, minuteCap: minuteCap, costUSD: cost,
                     daysLeftInMonth: Self.daysLeftInMonth(now: now, calendar: calendar))
    }

    /// Whole days from now to the first of next month, when the cap resets.
    /// Today counts, so the last day of the month reads "1 day left".
    public static func daysLeftInMonth(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: now) else { return 0 }
        let today = calendar.component(.day, from: now)
        return max(0, range.count - today + 1)
    }

    // MARK: - Storage (callers hold the lock)

    private func load() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([SessionRecord].self, from: data)
        else { return [] }
        return records
    }

    private func save(_ records: [SessionRecord]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
