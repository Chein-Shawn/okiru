import Foundation

/// Practice-only, in-memory pose measurements. No camera frame or image data enters this type.
public struct PracticeDiagnosticLog: Encodable, Sendable {
    public static let schemaVersion = 1
    public static let maximumSeconds: TimeInterval = 20 * 60
    public static let maximumSamples = 18_000
    public let schemaVersion: Int
    public let algorithmVersion: String
    public let appVersion: String
    public let startedAt: Date
    public private(set) var records: [PoseDiagnosticSnapshot]
    public private(set) var finishedReason: String?
    public private(set) var capped = false
    private let startedUptime: TimeInterval
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithmVersion, appVersion, startedAt, records, finishedReason, capped
    }

    public init(startedAt: Date, uptime: TimeInterval, appVersion: String) {
        schemaVersion = Self.schemaVersion
        algorithmVersion = "pose-shoulder-arm-v2"
        self.appVersion = appVersion
        self.startedAt = startedAt
        startedUptime = uptime
        records = []
    }

    @discardableResult public mutating func append(_ snapshot: PoseDiagnosticSnapshot) -> Bool {
        guard !capped else { return false }
        let elapsed = snapshot.timestamp - startedUptime
        guard elapsed >= 0, elapsed <= Self.maximumSeconds, records.count < Self.maximumSamples else {
            capped = true
            finishedReason = "limitReached"
            return false
        }
        var relative = snapshot
        relative.timestamp = elapsed
        records.append(relative)
        return true
    }

    public mutating func finish(_ reason: String) { finishedReason = reason }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(schemaVersion,forKey:.schemaVersion)
        try values.encode(algorithmVersion,forKey:.algorithmVersion)
        try values.encode(appVersion,forKey:.appVersion)
        try values.encode(startedAt,forKey:.startedAt)
        try values.encode(records,forKey:.records)
        try values.encodeIfPresent(finishedReason,forKey:.finishedReason)
        try values.encode(capped,forKey:.capped)
    }
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
