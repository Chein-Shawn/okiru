import Foundation
import Combine
import UserNotifications
import OkiruCore

struct ChallengeRoute: Identifiable {
    var id: String
    var occurrenceID: String?
    static var practice: ChallengeRoute { .init(id:UUID().uuidString,occurrenceID:nil) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: AppSnapshot
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var requiresPermissionSetup = false
    @Published var busy = false
    @Published var report = SchedulerReport()
    @Published var challenge: ChallengeRoute?
    @Published var activeWindows: [RestrictionWindow] = []
    @Published var foregroundNow = Date()
    let scheduler = AlarmScheduler()
    let restrictions = RestrictionCoordinator()
    private var repository: HistoryRepository?

    init() {
        snapshot = .init()
        do {
            let store = try HistoryRepository()
            snapshot = try store.load()
            repository = store
#if DEBUG
            if ProcessInfo.processInfo.environment["OKIRU_UI_TEST_DUE_WAKE"] == "1" {
                // An isolated UI-test fixture for icon launch and foreground
                // routing. The four-hour-old event avoids scheduling a real
                // follow-up alarm during the simulator test.
                let now = Date()
                let alarm = AlarmDefinition(createdAt:now.addingTimeInterval(-18_000),enabled:false)
                snapshot = .init()
                snapshot.alarms = [alarm]
                snapshot.occurrences = [AlarmOccurrence(alarm:alarm,scheduledAt:now.addingTimeInterval(-14_400))]
                snapshot.lastReconciledAt = now
            }
#endif
        } catch { errorMessage = tr("error.storage") + "\n" + error.localizedDescription }
    }
    var alarms: [AlarmDefinition] { snapshot.alarms }
    var occurrences: [AlarmOccurrence] { snapshot.occurrences }
    var nextAlarm: AlarmOccurrence? { snapshot.occurrences.filter { event in
        event.scheduledAt > Date() && !event.resolved && snapshot.alarms.contains { $0.id == event.alarm.id && $0.enabled }
    }.min { $0.scheduledAt < $1.scheduledAt } }
    var pending: [AlarmOccurrence] { snapshot.occurrences.filter { $0.scheduledAt <= Date() && !$0.resolved }.sorted { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt } }
    func persist() throws {
        guard let repository else { throw DisplayError(key:"error.storage") }
        try repository.save(snapshot)
    }
    func reconcile(now: Date = Date()) {
        // `remindersEnabled` remains in the Codable model for compatibility with
        // existing installs, but wake reminders are no longer optional.
        for index in snapshot.alarms.indices { snapshot.alarms[index].remindersEnabled = true }
        for index in snapshot.occurrences.indices where !snapshot.occurrences[index].resolved {
            snapshot.occurrences[index].alarm.remindersEnabled = true
        }
        // A completed one-shot has no future schedule to keep enabled. Retire
        // only resolved occurrences; an active challenge must continue even
        // though its original fire date is now in the past.
        for index in snapshot.alarms.indices
            where snapshot.alarms[index].enabled && !snapshot.alarms[index].isRepeating
                && snapshot.alarms[index].oneShotDate <= now {
            let alarmID = snapshot.alarms[index].id
            if snapshot.occurrences.contains(where: { $0.alarm.id == alarmID && $0.resolved }) {
                snapshot.alarms[index].enabled = false
            }
        }
        let start = min(snapshot.lastReconciledAt, now)
        // Recalculate unstarted future events in the current time zone. Preserve
        // past snapshots, terminal events and restrictions that already started.
        snapshot.occurrences.removeAll { $0.scheduledAt > now && !$0.resolved && !($0.alarm.restriction.enabled && RestrictionWindow(occurrence:$0).isActive(at:now)) }
        // A cancelled future event can retain an already-started restriction
        // snapshot. If that alarm was subsequently re-enabled, replace only
        // that future cancellation so its schedule and restriction can resume.
        let restored = AlarmReactivation.restoreFuture(definitions:snapshot.alarms,occurrences:&snapshot.occurrences,at:now)
        if !restored.isEmpty { snapshot.events.removeAll { restored.contains($0.occurrenceID) } }
        var known = Set(snapshot.occurrences.map(\.id)).union(snapshot.clearedOccurrenceIDs ?? [])
        for alarm in snapshot.alarms {
            for date in ScheduleCalculator.dates(for:alarm,from:start,through:now.addingTimeInterval(14*86400)) {
                let e = AlarmOccurrence(alarm:alarm,scheduledAt:date)
                if known.insert(e.id).inserted { snapshot.occurrences.append(e) }
            }
        }
        snapshot.lastReconciledAt = now
        snapshot.occurrences.sort { $0.scheduledAt < $1.scheduledAt }
    }
    private func importShared(_ shared: SharedRestrictionState) {
        for event in shared.occurrences {
            if snapshot.clearedOccurrenceIDs?.contains(event.id) == true { continue }
            if let i = snapshot.occurrences.firstIndex(where: { $0.id == event.id }) {
                if let emergency = event.emergencyAt { snapshot.occurrences[i].emergencyAt = emergency }
                if let released = event.restrictionEmergencyAt { snapshot.occurrences[i].restrictionEmergencyAt = released }
                if let cancelled = event.cancelledAt { snapshot.occurrences[i].cancelledAt = cancelled }
                if let cancelled = event.restrictionCancelledAt { snapshot.occurrences[i].restrictionCancelledAt = cancelled }
                if let complete = event.completedAt { snapshot.occurrences[i].completedAt = complete; snapshot.occurrences[i].reps = event.alarm.targetReps }
            } else { snapshot.occurrences.append(event) }
        }
        activeWindows = shared.active(at:Date())
    }
    func refresh() async {
        guard !busy, repository != nil else { return }
        busy = true; defer { busy = false; routeDueTask() }
        do {
            if let shared = try? SharedRestrictionStore.read() { importShared(shared) }
            reconcile()
            try persist()
            // Present an overdue task before potentially slow system scheduling.
            routeDueTask()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            if let shared = try restrictions.synchronize(definitions:alarms,occurrences:occurrences) {
                importShared(shared)
                try persist()
            }
            requiresPermissionSetup = false
        } catch let error as DisplayError where error.key == "error.restrictionPermission" {
            // Missing Screen Time access is handled by the permission setup UI.
            // Alarm synchronization must still continue independently.
            requiresPermissionSetup = true
        } catch { errorMessage = error.localizedDescription }
        do { report = try await scheduler.synchronize(alarms:alarms,occurrences:occurrences) }
        catch let error as DisplayError where ["error.alarmPermission","error.notificationPermission","error.notificationSounds"].contains(error.key) {
            requiresPermissionSetup = true
        } catch { errorMessage = error.localizedDescription }
        // A repairable scheduling/permission failure must not prevent opening an
        // already persisted task from its notification or AlarmKit action.
        routeRequestedAlarm()
    }

    func saveAlarm(_ value: AlarmDefinition) async -> Bool {
        guard await waitUntilIdle() else {
            errorMessage = tr("error.recovery")
            return false
        }
        busy = true; defer { busy = false }
        let previous = snapshot
        var cancelledIDs: [String] = []
        do {
            reconcile()
            // An AlarmKit repeating primary cannot be changed or cancelled
            // without potentially silencing the occurrence that is ringing.
            // Finish or use emergency release before editing this definition.
            guard !WakeTaskPolicy.hasFiredUnfinished(snapshot.occurrences,alarmID:value.id,at:Date()) else {
                throw DisplayError(key:"task.pending")
            }
            var alarm = value
            alarm.remindersEnabled = true
            guard (0...23).contains(alarm.hour), (0...59).contains(alarm.minute), alarm.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw DisplayError(key:"error.invalidAlarm") }
            guard (5...100).contains(alarm.targetReps), alarm.targetReps.isMultiple(of:5),
                  stride(from:15,through:120,by:15).contains(alarm.restriction.releaseDelayMinutes) else { throw DisplayError(key:"error.invalidAlarm") }
            if alarm.enabled && !alarm.isRepeating && alarm.oneShotDate <= Date() {
                // Editing a completed one-shot is allowed, but its historical
                // date cannot silently become a new active schedule.
                let completed = snapshot.occurrences.contains {
                    $0.alarm.id == alarm.id && $0.resolved && $0.scheduledAt == alarm.oneShotDate
                }
                if completed { alarm.enabled = false }
                else { throw DisplayError(key:"error.pastDate") }
            }
            if alarm.enabled {
                try await scheduler.authorize(needsReminders:true)
                if alarm.restriction.enabled { try await restrictions.authorize() }
            }
            let now = Date()
            let wasEnabled = snapshot.alarms.first(where: { $0.id == alarm.id })?.enabled == true
            if wasEnabled && !alarm.enabled {
                cancelledIDs = AlarmDeactivation.apply(alarmID:alarm.id,to:&snapshot.occurrences,at:now)
                for id in cancelledIDs where snapshot.occurrences.contains(where: { $0.id == id && $0.cancelledAt != nil }) {
                    snapshot.events.append(.init(occurrenceID:id,at:now,kind:.cancelled))
                }
            }
            if snapshot.alarms.contains(where: { $0.id == alarm.id }) { alarm.effectiveFrom = now }
            snapshot.occurrences.removeAll {
                $0.alarm.id == alarm.id && $0.scheduledAt > now && !$0.resolved && !($0.alarm.restriction.enabled && RestrictionWindow(occurrence:$0).isActive(at:now))
            }
            if let i = snapshot.alarms.firstIndex(where: { $0.id == alarm.id }) { snapshot.alarms[i] = alarm }
            else { snapshot.alarms.append(alarm) }
            reconcile()
            report = try await scheduler.synchronize(alarms:alarms,occurrences:occurrences)
            if let shared = try restrictions.synchronize(definitions:alarms,occurrences:occurrences) { importShared(shared) }
            try persist()
            if wasEnabled && !alarm.enabled {
                scheduler.stopCurrentSound(for:alarm.id)
                for id in cancelledIDs { await scheduler.cancelOccurrence(id) }
                if challenge?.occurrenceID.flatMap({ id in cancelledIDs.contains(id) ? id : nil }) != nil { challenge = nil }
            }
            return true
        } catch {
            snapshot = previous
            do {
                report = try await scheduler.synchronize(alarms:alarms,occurrences:occurrences)
                _ = try restrictions.synchronize(definitions:alarms,occurrences:occurrences)
                try persist()
            } catch { notice = tr("error.recovery") }
            errorMessage = error.localizedDescription
            return false
        }
    }
    func deleteAlarm(_ alarm: AlarmDefinition) async {
        guard await waitUntilIdle() else {
            errorMessage = tr("error.recovery")
            return
        }
        busy = true; defer { busy = false }
        let previous = snapshot
        do {
            reconcile()
            guard !WakeTaskPolicy.hasFiredUnfinished(snapshot.occurrences,alarmID:alarm.id,at:Date()) else {
                throw DisplayError(key:"task.pending")
            }
            snapshot.alarms.removeAll { $0.id == alarm.id }
            let now = Date()
            snapshot.occurrences.removeAll { $0.alarm.id == alarm.id && $0.scheduledAt > now && !$0.resolved && !($0.alarm.restriction.enabled && RestrictionWindow(occurrence:$0).isActive(at:now)) }
            report = try await scheduler.synchronize(alarms:alarms,occurrences:occurrences)
            if let shared = try restrictions.synchronize(definitions:alarms,occurrences:occurrences) { importShared(shared) }
            try persist()
        } catch {
            snapshot = previous
            do { report = try await scheduler.synchronize(alarms:alarms,occurrences:occurrences); _ = try restrictions.synchronize(definitions:alarms,occurrences:occurrences) }
            catch { notice = tr("error.recovery") }
            errorMessage = error.localizedDescription
        }
    }

    private func waitUntilIdle(timeout: TimeInterval = 15) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while busy && Date() < end {
            try? await Task.sleep(nanoseconds:100_000_000)
        }
        return !busy
    }
    func start(_ event: AlarmOccurrence) {
        guard event.scheduledAt <= Date(), !event.resolved else { return }
        guard let i = snapshot.occurrences.firstIndex(where: { $0.id == event.id }) else { return }
        if challenge?.occurrenceID == event.id { return }
        if snapshot.occurrences[i].startedAt == nil {
            snapshot.occurrences[i].startedAt = Date()
            snapshot.events.append(.init(occurrenceID:event.id,kind:.taskOpened))
        }
        challenge = .init(id:event.id,occurrenceID:event.id)
        do {
            try persist()
        } catch { errorMessage = error.localizedDescription }
    }
    func recordReps(_ count: Int, occurrenceID: String) async {
        guard let i = snapshot.occurrences.firstIndex(where: { $0.id == occurrenceID }), !snapshot.occurrences[i].resolved else { return }
        let before = snapshot.occurrences[i]
        snapshot.occurrences[i].confirm(repetitions:count,at:Date())
        do {
            try persist()
            if snapshot.occurrences[i].completedAt != nil {
                if !snapshot.events.contains(where: { $0.occurrenceID == occurrenceID && $0.kind == .completed }) { snapshot.events.append(.init(occurrenceID:occurrenceID,kind:.completed)) }
                scheduler.stopCurrentSound(for:before.alarm.id)
                if let shared = try restrictions.synchronize(definitions:alarms,occurrences:occurrences) { importShared(shared) }
                try persist()
                await scheduler.cancelOccurrence(occurrenceID)
                challenge = nil
                if snapshot.occurrences[i].outcome(at:Date()) == .onTime {
                    notice = tf("result.onTime.target",before.alarm.targetReps,before.alarm.targetReps >= 50 ? 10 : 5)
                } else { notice = tr("result.late.dynamic") }
                await refresh()
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func emergency(reason: String = "") async {
        let now = Date()
        do {
            let routeID = challenge?.occurrenceID
            let activeIDs = Set(activeWindows.map(\.occurrenceID))
            let affected = snapshot.occurrences.filter {
                activeIDs.contains($0.id) || (!$0.resolved && (($0.scheduledAt <= now && now <= $0.reminderEnd) || $0.id == routeID))
            }.map(\.id)
            for i in snapshot.occurrences.indices where affected.contains(snapshot.occurrences[i].id) {
                if snapshot.occurrences[i].completedAt != nil { snapshot.occurrences[i].restrictionEmergencyAt = now }
                else { snapshot.occurrences[i].emergencyAt = now }
                snapshot.occurrences[i].emergencyReason = reason.isEmpty ? nil : String(reason.prefix(400))
                snapshot.events.append(.init(occurrenceID:snapshot.occurrences[i].id,at:now,kind:.emergency))
                scheduler.stopCurrentSound(for:snapshot.occurrences[i].alarm.id)
            }
            try persist()
            for id in affected { await scheduler.cancelOccurrence(id) }
            if !activeWindows.isEmpty || alarms.contains(where: { $0.restriction.enabled }) {
                let shared = try restrictions.emergency(now:now)
                importShared(shared)
                try persist()
            }
            challenge = nil
            notice = tr("result.emergency")
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func routeRequestedAlarm() {
        // A deep link is a wake signal, not permission to skip an older task.
        UserDefaults.standard.removeObject(forKey:"requestedOccurrence")
        UserDefaults.standard.removeObject(forKey:"requestedAlarm")
        routeDueTask()
    }
    func routeDueTask(now: Date = Date()) {
        guard let event = WakeTaskPolicy.firstUnfinished(occurrences,at:now) else { return }
        start(event)
    }
    func clearHistory() {
        guard !busy else { return }
        let previous = snapshot
        let now = Date()
        let ids = Set(snapshot.occurrences.filter { $0.resolved && $0.scheduledAt < now && !($0.alarm.restriction.enabled && RestrictionWindow(occurrence:$0).isActive(at:now)) }.map(\.id))
        snapshot.clearedOccurrenceIDs = (snapshot.clearedOccurrenceIDs ?? []).union(ids)
        snapshot.occurrences.removeAll { ids.contains($0.id) }
        snapshot.events.removeAll { ids.contains($0.occurrenceID) }
        snapshot.lastReconciledAt = now
        do { try persist() } catch { snapshot = previous; errorMessage = error.localizedDescription }
    }
    func reset() async {
        guard !busy else { return }
        guard WakeTaskPolicy.firstUnfinished(occurrences,at:Date()) == nil else {
            errorMessage = tr("challenge.leaveNote")
            routeDueTask()
            return
        }
        busy = true; defer { busy = false }
        do {
            try await scheduler.reset()
            if !activeWindows.isEmpty || alarms.contains(where: { $0.restriction.enabled }) || (try? SharedRestrictionStore.read()) != nil { try restrictions.reset() }
            snapshot = .init(); report = .init(); activeWindows = []; challenge = nil
            try persist()
            for key in ["language","onboarded","permissionSetupVersion","feedback.id","feedback.lastPayload","feedback.category","feedback.summary","feedback.details","feedback.email","feedback.lastSent","requestedAlarm","requestedOccurrence"] { UserDefaults.standard.removeObject(forKey:key) }
            UserDefaults(suiteName:SharedRestrictionStore.groupID)?.removeObject(forKey:"language")
        } catch { errorMessage = error.localizedDescription }
    }
}
