import Foundation

public enum AlarmSound: String, CaseIterable, Codable, Hashable, Sendable {
    case sunrise, bells, marimba, pulse, orbit, tide
    public var filename: String { rawValue + ".wav" }
}

public struct RestrictionPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var startMinute = 22 * 60
    public var releaseDelayMinutes = 15
    /// Existing installs retain their previously promised minimum end time.
    public var legacyEndMinute: Int?
    // The platform adapter owns opaque FamilyActivitySelection encoding.
    public var selectionData: Data?
    public var blockedSelectionData: Data?
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, startMinute, releaseDelayMinutes, legacyEndMinute, endMinute, selectionData, blockedSelectionData }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
        startMinute = try values.decodeIfPresent(Int.self,forKey:.startMinute) ?? 22 * 60
        releaseDelayMinutes = try values.decodeIfPresent(Int.self,forKey:.releaseDelayMinutes) ?? 15
        legacyEndMinute = try values.decodeIfPresent(Int.self,forKey:.legacyEndMinute)
            ?? values.decodeIfPresent(Int.self,forKey:.endMinute)
        selectionData = try values.decodeIfPresent(Data.self,forKey:.selectionData)
        blockedSelectionData = try values.decodeIfPresent(Data.self,forKey:.blockedSelectionData)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy:CodingKeys.self)
        try values.encode(enabled,forKey:.enabled)
        try values.encode(startMinute,forKey:.startMinute)
        try values.encode(releaseDelayMinutes,forKey:.releaseDelayMinutes)
        try values.encodeIfPresent(legacyEndMinute,forKey:.legacyEndMinute)
        try values.encodeIfPresent(selectionData,forKey:.selectionData)
        try values.encodeIfPresent(blockedSelectionData,forKey:.blockedSelectionData)
    }
}

public struct AlarmDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var effectiveFrom: Date
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    // Calendar weekday: Sunday=1 ... Saturday=7. Empty means one-shot.
    public var weekdays: Set<Int>
    public var oneShotDate: Date
    public var sound: AlarmSound
    public var remindersEnabled: Bool
    public var targetReps: Int
    public var restriction: RestrictionPolicy

    public init(id: UUID = UUID(), name: String = "", createdAt: Date = Date(), enabled: Bool = true,
                hour: Int = 7, minute: Int = 0, weekdays: Set<Int> = [2,3,4,5,6],
                oneShotDate: Date = Date().addingTimeInterval(3600), sound: AlarmSound = .sunrise,
                remindersEnabled: Bool = true, targetReps: Int = 10, restriction: RestrictionPolicy = .init()) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.effectiveFrom = createdAt; self.enabled = enabled
        self.hour = hour; self.minute = minute; self.weekdays = weekdays
        self.oneShotDate = oneShotDate; self.sound = sound
        self.remindersEnabled = remindersEnabled; self.targetReps = targetReps; self.restriction = restriction
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, effectiveFrom, enabled, hour, minute, weekdays, oneShotDate, sound, remindersEnabled, targetReps, restriction
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(UUID.self,forKey:.id)
        name = try values.decode(String.self,forKey:.name)
        createdAt = try values.decode(Date.self,forKey:.createdAt)
        effectiveFrom = try values.decodeIfPresent(Date.self,forKey:.effectiveFrom) ?? createdAt
        enabled = try values.decode(Bool.self,forKey:.enabled)
        hour = try values.decode(Int.self,forKey:.hour)
        minute = try values.decode(Int.self,forKey:.minute)
        weekdays = try values.decode(Set<Int>.self,forKey:.weekdays)
        oneShotDate = try values.decode(Date.self,forKey:.oneShotDate)
        sound = try values.decode(AlarmSound.self,forKey:.sound)
        remindersEnabled = try values.decodeIfPresent(Bool.self,forKey:.remindersEnabled) ?? true
        targetReps = try values.decodeIfPresent(Int.self,forKey:.targetReps) ?? 10
        restriction = try values.decodeIfPresent(RestrictionPolicy.self,forKey:.restriction) ?? .init()
    }

    public var isRepeating: Bool { !weekdays.isEmpty }
    public var legacyNotificationCost: Int { !isRepeating || weekdays.count == 7 ? 1 : weekdays.count }
}

public enum WakeOutcome: String, Codable, CaseIterable, Sendable {
    case upcoming, challenging, onTime, late, missed, emergency, cancelled
}

public struct AlarmOccurrence: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var alarm: AlarmDefinition
    public var scheduledAt: Date
    public var timeZoneID: String
    public var dayKey: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var emergencyAt: Date?
    public var emergencyReason: String?
    /// A restriction-only emergency release must not erase an already completed task.
    public var restrictionEmergencyAt: Date?
    /// Turning off this alarm ends its unfinished mission without claiming success.
    public var cancelledAt: Date?
    /// A completed mission keeps its result when its delayed restriction is cancelled.
    public var restrictionCancelledAt: Date?
    public var reps: Int

    public init(alarm: AlarmDefinition, scheduledAt: Date, calendar: Calendar = .current) {
        self.id = "\(alarm.id.uuidString).\(Int(scheduledAt.timeIntervalSince1970))"
        self.alarm = alarm; self.scheduledAt = scheduledAt
        self.timeZoneID = calendar.timeZone.identifier
        self.dayKey = WakeStatistics.dayKey(scheduledAt,calendar:calendar)
        self.reps = 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, alarm, scheduledAt, timeZoneID, dayKey, startedAt, completedAt,
             emergencyAt, emergencyReason, restrictionEmergencyAt, cancelledAt,
             restrictionCancelledAt, reps
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(String.self,forKey:.id)
        alarm = try values.decode(AlarmDefinition.self,forKey:.alarm)
        scheduledAt = try values.decode(Date.self,forKey:.scheduledAt)
        timeZoneID = try values.decode(String.self,forKey:.timeZoneID)
        dayKey = try values.decode(String.self,forKey:.dayKey)
        startedAt = try values.decodeIfPresent(Date.self,forKey:.startedAt)
        completedAt = try values.decodeIfPresent(Date.self,forKey:.completedAt)
        emergencyAt = try values.decodeIfPresent(Date.self,forKey:.emergencyAt)
        emergencyReason = try values.decodeIfPresent(String.self,forKey:.emergencyReason)
        restrictionEmergencyAt = try values.decodeIfPresent(Date.self,forKey:.restrictionEmergencyAt)
        cancelledAt = try values.decodeIfPresent(Date.self,forKey:.cancelledAt)
        restrictionCancelledAt = try values.decodeIfPresent(Date.self,forKey:.restrictionCancelledAt)
        reps = try values.decodeIfPresent(Int.self,forKey:.reps) ?? 0
    }

    public var deadline: Date { scheduledAt.addingTimeInterval(alarm.targetReps >= 50 ? 600 : 300) }
    public var reminderEnd: Date { scheduledAt.addingTimeInterval(10_800) }
    public var resolved: Bool { completedAt != nil || emergencyAt != nil || cancelledAt != nil }
    public func outcome(at now: Date) -> WakeOutcome {
        if emergencyAt != nil { return .emergency }
        if let completedAt { return completedAt <= deadline ? .onTime : .late }
        if let cancelledAt { return cancelledAt > deadline ? .missed : .cancelled }
        if now > deadline { return .missed }
        if startedAt != nil { return .challenging }
        return .upcoming
    }
    public mutating func confirm(repetitions: Int, at now: Date) {
        guard !resolved, now >= scheduledAt else { return }
        startedAt = startedAt ?? now
        reps = min(alarm.targetReps, max(reps, repetitions))
        if reps == alarm.targetReps { completedAt = now }
    }
}

public struct WakeEvent: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case taskOpened, countChanged, completed, emergency, cancelled, notificationOpened, schedulingFailed }
    public var id: UUID
    public var occurrenceID: String
    public var at: Date
    public var kind: Kind
    public init(occurrenceID: String, at: Date = Date(), kind: Kind) {
        id = UUID(); self.occurrenceID = occurrenceID; self.at = at; self.kind = kind
    }
}

public struct RestrictionWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var occurrenceID: String
    public var start: Date
    public var releaseAt: Date?
    public var completedAt: Date?
    public var emergencyAt: Date?
    public var selectionData: Data?
    public var blockedSelectionData: Data?
    public init(occurrence: AlarmOccurrence, calendar source: Calendar = .current) {
        id = occurrence.id; occurrenceID = occurrence.id
        var cal = source
        cal.timeZone = TimeZone(identifier: occurrence.timeZoneID) ?? source.timeZone
        let day = cal.startOfDay(for: occurrence.scheduledAt)
        let policy = occurrence.alarm.restriction
        let alarmMinute = cal.component(.hour,from:occurrence.scheduledAt) * 60 + cal.component(.minute,from:occurrence.scheduledAt)
        let beginsPreviousDay = policy.legacyEndMinute.map { policy.startMinute >= $0 }
            ?? (policy.startMinute > alarmMinute)
        let startDay = beginsPreviousDay ? cal.date(byAdding: .day, value: -1, to: day)! : day
        start = cal.date(bySettingHour: policy.startMinute / 60, minute: policy.startMinute % 60, second: 0, of: startDay) ?? startDay
        completedAt = occurrence.completedAt
        emergencyAt = occurrence.restrictionCancelledAt ?? occurrence.cancelledAt
            ?? occurrence.restrictionEmergencyAt ?? occurrence.emergencyAt
        if let completedAt = occurrence.completedAt {
            var end = completedAt.addingTimeInterval(TimeInterval(policy.releaseDelayMinutes * 60))
            if let legacy = policy.legacyEndMinute,
               let oldEnd = cal.date(bySettingHour:legacy / 60,minute:legacy % 60,second:0,of:day) {
                end = max(end,oldEnd)
            }
            releaseAt = end
        }
        selectionData = policy.selectionData
        blockedSelectionData = policy.blockedSelectionData
    }
    public func isActive(at now: Date) -> Bool {
        guard emergencyAt == nil, now >= start else { return false }
        return releaseAt.map { now < $0 } ?? true
    }
}
