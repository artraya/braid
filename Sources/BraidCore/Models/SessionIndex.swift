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
    public var notePath: String

    public init(id: String, title: String, presetName: String, startedAt: Date,
                recordedDuration: TimeInterval, notePath: String) {
        self.id = id
        self.title = title
        self.presetName = presetName
        self.startedAt = startedAt
        self.recordedDuration = recordedDuration
        self.notePath = notePath
    }

    public init(session: Session, notePath: String) {
        self.init(id: session.id, title: session.title, presetName: session.presetName,
                  startedAt: session.startedAt, recordedDuration: session.recordedDuration,
                  notePath: notePath)
    }
}

/// What this month came to. Minutes only: with the cloud gone nothing the app
/// does has a price, so there is no spend to track and no cap to enforce
/// (R14 retired, R18 amended).
public struct Usage: Sendable, Equatable {
    public let minutesUsed: Double
    public let sessionCount: Int

    public init(minutesUsed: Double, sessionCount: Int) {
        self.minutesUsed = minutesUsed
        self.sessionCount = sessionCount
    }

    public static let empty = Usage(minutesUsed: 0, sessionCount: 0)
}

/// The delivered-Session log, one JSON file, newest first. Both the Job runner
/// and speaker naming write to it, so access is serialised.
public final class SessionIndex: @unchecked Sendable {
    /// Far more than a year of real use. Trimming the tail keeps monthly
    /// figures intact, which is all the usage line reads.
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

    public func usage(now: Date = Date(), calendar: Calendar = .current) -> Usage {
        let month = all().filter {
            calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month)
        }
        return Usage(minutesUsed: month.reduce(0) { $0 + $1.recordedDuration } / 60,
                     sessionCount: month.count)
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
