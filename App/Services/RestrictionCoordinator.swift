import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import OkiruCore

@MainActor final class RestrictionCoordinator {
    let center = DeviceActivityCenter()
    var isAuthorized: Bool {
        let value = AuthorizationCenter.shared.authorizationStatus
        if #available(iOS 26.4, *), value == .approvedWithDataAccess { return true }
        return value == .approved
    }
    func authorize() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for:.individual)
        guard isAuthorized else { throw DisplayError(key:"error.restrictionPermission") }
        _ = try SharedRestrictionStore.location()
    }
    func synchronize(definitions: [AlarmDefinition], occurrences: [AlarmOccurrence], now: Date = Date()) throws -> SharedRestrictionState? {
        let wanted = definitions.filter { $0.enabled && $0.restriction.enabled }
        let hasPersisted: Bool
        do { hasPersisted = try !SharedRestrictionStore.read().occurrences.isEmpty }
        catch {
            // A fresh unsigned simulator can lack App Group access. Once there
            // is any restriction intent/authorization, an unreadable store must
            // be reported, not mistaken for an empty restriction policy.
            guard wanted.isEmpty, !isAuthorized,
                  !definitions.contains(where: { $0.restriction.enabled }),
                  !occurrences.contains(where: { $0.alarm.restriction.enabled }),
                  !center.activities.contains(where: { $0.rawValue.hasPrefix("okiru.") }) else { throw error }
            return nil
        }
        guard !wanted.isEmpty || hasPersisted else { return nil }
        guard isAuthorized else { throw DisplayError(key:"error.restrictionPermission") }
        let state = try SharedRestrictionStore.update { shared in
            shared.definitions = definitions
            // Preserve active snapshots. Replace only future, not-yet-active definitions.
            shared.occurrences.removeAll { item in
                if definitions.contains(where: { $0.id == item.alarm.id && !$0.enabled }),
                   !occurrences.contains(where: { $0.id == item.id }) { return true }
                let window = RestrictionWindow(occurrence:item)
                return window.start > now && !occurrences.contains(where: { $0.id == item.id })
            }
            for event in occurrences where event.alarm.restriction.enabled {
                if let i = shared.occurrences.firstIndex(where: { $0.id == event.id }) {
                    if let cancelledAt = shared.occurrences[i].cancelledAt, event.cancelledAt == nil {
                        // A later explicit re-enable may reuse the same stable
                        // occurrence ID. Do not let the old cancellation keep
                        // tomorrow's restriction permanently resolved.
                        let reenabled = event.scheduledAt > now && definitions.contains {
                            $0.id == event.alarm.id && $0.enabled && $0.effectiveFrom > cancelledAt
                        }
                        if !reenabled { continue }
                    }
                    if shared.occurrences[i].restrictionCancelledAt != nil && event.restrictionCancelledAt == nil { continue }
                    if shared.occurrences[i].emergencyAt != nil && event.emergencyAt == nil { continue }
                    if shared.occurrences[i].restrictionEmergencyAt != nil && event.restrictionEmergencyAt == nil { continue }
                    if shared.occurrences[i].completedAt != nil && event.completedAt == nil && event.cancelledAt == nil { continue }
                    shared.occurrences[i] = event
                } else { shared.occurrences.append(event) }
            }
            shared.materialize(at:now)
        }
        var desired: Set<DeviceActivityName> = []
        for alarm in wanted {
            if alarm.isRepeating {
                for weekday in alarm.weekdays.sorted() {
                    let name = DeviceActivityName("okiru.\(alarm.id).\(weekday)")
                    guard let event = occurrences.first(where: { $0.alarm.id == alarm.id && Calendar.current.component(.weekday,from:$0.scheduledAt) == weekday && $0.scheduledAt >= now }) else { continue }
                    let window = RestrictionWindow(occurrence:event)
                    let monitorEnd = max(event.scheduledAt,window.start.addingTimeInterval(900))
                    let start = Calendar.current.dateComponents([.weekday,.hour,.minute],from:window.start)
                    let end = Calendar.current.dateComponents([.weekday,.hour,.minute],from:monitorEnd)
                    desired.insert(name)
                    let schedule = DeviceActivitySchedule(intervalStart:start,intervalEnd:end,repeats:true)
                    if center.schedule(for:name)?.intervalStart != start || center.schedule(for:name)?.intervalEnd != end {
                        try center.startMonitoring(name,during:schedule)
                    }
                }
            } else if let occurrence = occurrences.first(where: { $0.alarm.id == alarm.id && !$0.resolved }) {
                let w = RestrictionWindow(occurrence:occurrence)
                let monitorEnd = max(occurrence.scheduledAt,w.start.addingTimeInterval(900))
                if monitorEnd > now {
                    let name = DeviceActivityName("okiru.\(alarm.id).once")
                    desired.insert(name)
                    let components: Set<Calendar.Component> = [.year,.month,.day,.hour,.minute,.second]
                    let start = Calendar.current.dateComponents(components,from:w.start)
                    let end = Calendar.current.dateComponents(components,from:monitorEnd)
                    if center.schedule(for:name)?.intervalStart != start || center.schedule(for:name)?.intervalEnd != end {
                        try center.startMonitoring(name,during:.init(intervalStart:start,intervalEnd:end,repeats:false))
                    }
                }
            }
        }
        // Completion creates a new one-shot release callback. The monitor
        // extension applies the shared state even when the main app is closed.
        for window in state.active(at:now) {
            guard let releaseAt = window.releaseAt, releaseAt > now else { continue }
            let name = DeviceActivityName("okiru.release.\(window.id)")
            desired.insert(name)
            let fields: Set<Calendar.Component> = [.year,.month,.day,.hour,.minute,.second]
            let startDate = max(now,releaseAt.addingTimeInterval(-900))
            let endDate = max(releaseAt,startDate.addingTimeInterval(900))
            let start = Calendar.current.dateComponents(fields,from:startDate)
            let end = Calendar.current.dateComponents(fields,from:endDate)
            // Keep an already registered callback: recalculating from `now`
            // on every refresh would keep pushing the release into the future.
            if center.schedule(for:name) == nil {
                try center.startMonitoring(name,during:.init(intervalStart:start,intervalEnd:end,repeats:false))
            }
        }
        let obsolete = center.activities.filter { $0.rawValue.hasPrefix("okiru.") && !desired.contains($0) }
        if !obsolete.isEmpty { center.stopMonitoring(obsolete) }
        try SharedRestrictionStore.apply(state,at:now)
        return state
    }
    func emergency(now: Date) throws -> SharedRestrictionState {
        let state = try SharedRestrictionStore.update { shared in
            shared.materialize(at:now)
            let ids = Set(shared.active(at:now).map(\.occurrenceID))
            for i in shared.occurrences.indices where ids.contains(shared.occurrences[i].id) {
                if shared.occurrences[i].completedAt != nil { shared.occurrences[i].restrictionEmergencyAt = now }
                else { shared.occurrences[i].emergencyAt = now }
            }
        }
        try SharedRestrictionStore.apply(state,at:now)
        return state
    }
    func reset() throws {
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix("okiru.") })
        _ = try SharedRestrictionStore.update { $0 = .init() }
        ManagedSettingsStore(named:SharedRestrictionStore.storeName).clearAllSettings()
    }
}
