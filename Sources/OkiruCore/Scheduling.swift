import Foundation

public enum EmergencyHoldPolicy {
    /// Releasing an active Screen Time restriction takes longer than ending
    /// a wake task that has no active restriction.
    public static func duration(hasActiveRestriction: Bool) -> TimeInterval {
        hasActiveRestriction ? 30 : 3
    }
}

public enum ScheduleCalculator {
    public static func dates(for alarm: AlarmDefinition, from start: Date, through end: Date,
                             calendar: Calendar = .current) -> [Date] {
        guard alarm.enabled, end >= start else { return [] }
        if !alarm.isRepeating {
            return alarm.oneShotDate >= start && alarm.oneShotDate <= end && alarm.oneShotDate >= alarm.createdAt ? [alarm.oneShotDate] : []
        }
        var result: [Date] = []
        var day = calendar.startOfDay(for: max(start, alarm.effectiveFrom))
        while day <= end {
            if alarm.weekdays.contains(calendar.component(.weekday, from: day)),
               let time = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0,
                                        of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
               time >= start, time >= alarm.effectiveFrom, time <= end {
                result.append(time)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
    public static func next(for alarm: AlarmDefinition, after now: Date, calendar: Calendar = .current) -> Date? {
        dates(for: alarm, from: now.addingTimeInterval(0.5), through: now.addingTimeInterval(8 * 86_400), calendar: calendar).first
    }
}

/// Cancels only future work for one alarm. An already-fired unfinished wake
/// remains active until completion or emergency release.
public enum AlarmDeactivation {
    @discardableResult public static func apply(alarmID: UUID, to occurrences: inout [AlarmOccurrence], at now: Date) -> [String] {
        var affected: [String] = []
        occurrences.removeAll { event in
            guard event.alarm.id == alarmID else { return false }
            let activeRestriction = event.alarm.restriction.enabled && RestrictionWindow(occurrence:event).isActive(at:now)
            if event.scheduledAt > now && !activeRestriction && !event.resolved {
                affected.append(event.id)
                return true
            }
            return false
        }
        for index in occurrences.indices where occurrences[index].alarm.id == alarmID {
            if !occurrences[index].resolved {
                // Turning off an alarm only prevents future occurrences. Once it
                // has fired, completion or emergency release owns its lifetime.
                if occurrences[index].scheduledAt <= now { continue }
                occurrences[index].cancelledAt = now
                affected.append(occurrences[index].id)
            } else if occurrences[index].completedAt != nil,
                      occurrences[index].alarm.restriction.enabled,
                      RestrictionWindow(occurrence:occurrences[index]).isActive(at:now) {
                occurrences[index].restrictionCancelledAt = now
                affected.append(occurrences[index].id)
            }
        }
        return affected
    }
}

/// Re-enabling an alarm restores only future occurrences cancelled by an
/// earlier deactivation. A fired or completed occurrence remains historical.
public enum AlarmReactivation {
    @discardableResult public static func restoreFuture(
        definitions: [AlarmDefinition],
        occurrences: inout [AlarmOccurrence],
        at now: Date,
        calendar: Calendar = .current
    ) -> Set<String> {
        var enabled: [UUID:AlarmDefinition] = [:]
        for alarm in definitions where alarm.enabled { enabled[alarm.id] = alarm }
        var restored: Set<String> = []
        occurrences.removeAll { event in
            guard event.scheduledAt > now,
                  let cancelledAt = event.cancelledAt,
                  let alarm = enabled[event.alarm.id],
                  alarm.effectiveFrom > cancelledAt,
                  ScheduleCalculator.dates(for:alarm,from:now,through:event.scheduledAt,calendar:calendar).contains(event.scheduledAt)
            else { return false }
            restored.insert(event.id)
            return true
        }
        return restored
    }
}

/// The task to show whenever Okiru becomes visible. The result is independent
/// of how the app was opened (icon, notification, or AlarmKit intent).
public enum WakeTaskPolicy {
    public static func firstUnfinished(_ occurrences: [AlarmOccurrence], at now: Date) -> AlarmOccurrence? {
        occurrences
            .filter { $0.scheduledAt <= now && !$0.resolved }
            .min { lhs, rhs in
                lhs.scheduledAt == rhs.scheduledAt ? lhs.id < rhs.id : lhs.scheduledAt < rhs.scheduledAt
            }
    }

    public static func hasFiredUnfinished(_ occurrences: [AlarmOccurrence], alarmID: UUID, at now: Date) -> Bool {
        occurrences.contains { $0.alarm.id == alarmID && $0.scheduledAt <= now && !$0.resolved }
    }
}

public struct PlannedReminder: Identifiable, Equatable, Sendable {
    public var id: String
    public var occurrenceID: String
    public var at: Date
    public var sound: AlarmSound

    public init(id: String, occurrenceID: String, at: Date, sound: AlarmSound) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.at = at
        self.sound = sound
    }
}

public struct ReminderPlan: Sendable {
    public var reminders: [PlannedReminder]
    public var candidateCount: Int
    public var reservedPrimary: Int
    public var capacityLimited: Bool { reminders.count < candidateCount }
    public var lastReminderAt: Date? { reminders.last?.at }
}

public enum ReminderPlanner {
    public static let budget = 48
    public static let intervalSeconds: TimeInterval = 3
    public static let durationSeconds: TimeInterval = 10_800
    public static func plan(occurrences: [AlarmOccurrence], now: Date, primaryCount: Int,
                            otherPendingCount: Int = 0, capacity: Int = budget) -> ReminderPlan {
        var candidates: [PlannedReminder] = []
        // Follow-up wake alerts are mandatory for every unfinished occurrence.
        // Dismissing one delivered alert never removes the remaining requests.
        for event in occurrences where !event.resolved {
            let firstSlot = max(1,Int(floor(now.timeIntervalSince(event.scheduledAt) / intervalSeconds)) + 1)
            let finalSlot = Int(durationSeconds / intervalSeconds)
            guard firstSlot <= finalSlot, capacity > 0 else { continue }
            // At most `capacity` future candidates from any occurrence can enter
            // the global prefix, so avoid materializing all 3,600 three-second slots.
            let lastCandidate = min(finalSlot,firstSlot + capacity - 1)
            for slot in firstSlot...lastCandidate {
                let date = event.scheduledAt.addingTimeInterval(Double(slot) * intervalSeconds)
                candidates.append(.init(id:"okiru.follow.\(event.id).\(slot)",occurrenceID:event.id,at:date,sound:event.alarm.sound))
            }
        }
        candidates.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        let available = max(0, capacity - max(0, primaryCount) - max(0, otherPendingCount))
        return .init(reminders: Array(candidates.prefix(available)), candidateCount: candidates.count, reservedPrimary: primaryCount)
    }
}

public struct WakeStatistics: Sendable {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        var cal = Calendar(identifier:.gregorian); cal.timeZone = calendar.timeZone
        let parts = cal.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",parts.year ?? 0,parts.month ?? 0,parts.day ?? 0)
    }
    public static func inRecentDays(_ events: [AlarmOccurrence], days: Int, now: Date, calendar: Calendar = .current) -> [AlarmOccurrence] {
        guard days > 0 else { return events }
        let start = calendar.date(byAdding:.day,value:1-days,to:calendar.startOfDay(for:now)) ?? now
        let firstKey = dayKey(start,calendar:calendar), lastKey = dayKey(now,calendar:calendar)
        return events.filter { $0.dayKey >= firstKey && $0.dayKey <= lastKey }
    }
    public var eligibleDays: Int
    public var successfulDays: Int
    public var successRate: Double? { eligibleDays == 0 ? nil : Double(successfulDays) / Double(eligibleDays) }
    public var averageDelaySeconds: Double?
    public var averageCompletionMinute: Double?
    public var currentStreak: Int

    public static func dailyFirst(_ events: [AlarmOccurrence]) -> [AlarmOccurrence] {
        Dictionary(grouping: events.filter { event in event.cancelledAt.map { $0 > event.deadline } ?? true }, by: \.dayKey).values.compactMap { day in
            day.sorted {
                if $0.scheduledAt != $1.scheduledAt { return $0.scheduledAt < $1.scheduledAt }
                if $0.alarm.createdAt != $1.alarm.createdAt { return $0.alarm.createdAt < $1.alarm.createdAt }
                return $0.id < $1.id
            }.first
        }.sorted { $0.scheduledAt < $1.scheduledAt }
    }
    public static func calculate(_ events: [AlarmOccurrence], now: Date) -> WakeStatistics {
        let first = dailyFirst(events).filter { $0.deadline <= now }
        let successes = first.filter { $0.outcome(at: now) == .onTime }
        let completed = first.filter { $0.completedAt != nil && $0.emergencyAt == nil }
        let delays = completed.map { max(0, $0.completedAt!.timeIntervalSince($0.scheduledAt)) }
        // Circular mean handles completion times around midnight correctly.
        let phases = completed.map { event -> Double in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: event.timeZoneID) ?? .current
            let parts = cal.dateComponents([.hour,.minute], from: event.completedAt!)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440 * 2 * .pi
        }
        let x = phases.reduce(0) { $0 + cos($1) }, y = phases.reduce(0) { $0 + sin($1) }
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * .pi }
        var streak = 0
        for event in first.reversed() {
            guard event.outcome(at: now) == .onTime else { break }
            streak += 1
        }
        return .init(eligibleDays: first.count, successfulDays: successes.count,
                     averageDelaySeconds: delays.isEmpty ? nil : delays.reduce(0,+) / Double(delays.count),
                     averageCompletionMinute: phases.isEmpty || hypot(x,y) < 0.0001 ? nil : angle / (2 * .pi) * 1440,
                     currentStreak: streak)
    }
}
