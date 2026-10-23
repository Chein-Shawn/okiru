import Foundation
import UserNotifications
import AlarmKit
import AppIntents
import SwiftUI
import OkiruCore
import CryptoKit
import OSLog

@available(iOS 26.0, *)
struct OkiruAlarmMetadata: AlarmMetadata { var alarmID: String }

@available(iOS 26.0, *)
struct OpenChallengeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "challenge.start"
    static var supportedModes: IntentModes { [.foreground(.immediate)] }
    static var openAppWhenRun = true
    @Parameter(title:"Alarm") var alarmID: String
    init() {}
    init(alarmID: String) { self.alarmID = alarmID }
    func perform() async throws -> some IntentResult {
        Logger(subsystem:"com.shawn.okiru",category:"wake-delivery")
            .info("AlarmKit action opened challenge alarm=\(alarmID, privacy:.private)")
        UserDefaults.standard.set(alarmID,forKey:"requestedAlarm")
        // If Okiru is already visible, scenePhase doesn't change. Notify the
        // live process so it both routes the challenge and replenishes the
        // rolling AlarmKit window immediately.
        NotificationCenter.default.post(name:.init("OkiruOpenTask"),object:nil)
        return .result()
    }
}

struct SchedulerReport {
    var actualReminders: [PlannedReminder] = []
    var limited = false
    var warning: String?
    var registeredAlarms: Set<UUID> = []
}

@MainActor final class AlarmScheduler {
    private let log = Logger(subsystem:"com.shawn.okiru",category:"wake-scheduler")
    private var observedDeliveredIDs: Set<String> = []
    let notifications = UNUserNotificationCenter.current()
    private var soundDigestCache: [AlarmSound:String] = [:]
    private let escalationRegistryKey = "alarmKitEscalationIDs"
    private let escalationInterval: TimeInterval = 10
    private let escalationWindowCount = 24
    // Kept for one migration cycle so developer test alarms created by older
    // builds are removed instead of occupying AlarmKit capacity indefinitely.
    private let legacyIntervalTestIDsKey = "alarmKitIntervalTestIDs"
    var modern: Bool { if #available(iOS 26.0, *) { return true }; return false }

    func authorize(needsReminders: Bool) async throws {
        if #available(iOS 26.0, *) {
            let state = try await AlarmManager.shared.requestAuthorization()
            guard state == .authorized else { throw DisplayError(key:"error.alarmPermission") }
            if needsReminders,
               !(try await notifications.requestAuthorization(options:[.alert,.sound,.badge,.timeSensitive])) {
                throw DisplayError(key:"error.notificationPermission")
            }
        } else {
            guard try await notifications.requestAuthorization(options:[.alert,.sound,.badge,.timeSensitive]) else {
                throw DisplayError(key:"error.notificationPermission")
            }
        }
    }

    func synchronize(alarms: [AlarmDefinition], occurrences: [AlarmOccurrence], now: Date = Date()) async throws -> SchedulerReport {
        do {
            return try await synchronizeImplementation(alarms:alarms,occurrences:occurrences,now:now)
        } catch {
            log.error("Wake synchronization failed: \(String(describing:type(of:error)), privacy:.public)")
            if #available(iOS 26.0, *),
               let alarmError = error as? AlarmManager.AlarmError,
               alarmError == .maximumLimitReached {
                // AlarmKit localizes its raw error using the device language,
                // which can differ from Okiru's selected language. Never
                // surface the opaque "Alarm error 0" message to the user.
                throw DisplayError(key:"error.alarmLimit")
            }
            throw error
        }
    }

    private func synchronizeImplementation(alarms: [AlarmDefinition], occurrences: [AlarmOccurrence], now: Date) async throws -> SchedulerReport {
        var report = SchedulerReport()
        var enabled = alarms.filter { $0.enabled && ($0.isRepeating || $0.oneShotDate > now) }
        var retainedRoutes: [String:String] = [:]
        // An active restriction keeps its original wake-up after edits or deletion.
        for event in occurrences where !event.resolved && event.scheduledAt > now && event.alarm.restriction.enabled && RestrictionWindow(occurrence:event).isActive(at:now) {
            let covered = enabled.contains { $0.id == event.alarm.id && ScheduleCalculator.dates(for:$0,from:event.scheduledAt,through:event.scheduledAt).contains(event.scheduledAt) }
            if !covered {
                var retained = event.alarm
                let b = Array(SHA256.hash(data:Data(event.id.utf8)).prefix(16))
                retained.id = UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
                retained.enabled = true; retained.weekdays = []; retained.oneShotDate = event.scheduledAt
                retainedRoutes[retained.id.uuidString] = event.alarm.id.uuidString
                enabled.append(retained)
            }
        }
        let settings = await notifications.notificationSettings()
        let notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let notificationSoundAllowed = settings.soundSetting == .enabled
        log.info("Notification settings authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue) sounds=\(settings.soundSetting.rawValue) timeSensitive=\(settings.timeSensitiveSetting.rawValue)")
        let existing = await notifications.pendingNotificationRequests()
        let delivered = await notifications.deliveredNotifications()
        for item in delivered where item.request.identifier.hasPrefix("okiru.") && observedDeliveredIDs.insert(item.request.identifier).inserted {
            log.info("Observed delivered notification id=\(item.request.identifier, privacy:.private) at=\(item.date, privacy:.public) soundRequested=\(item.request.content.sound != nil)")
        }
        let otherCount = existing.filter { !$0.identifier.hasPrefix("okiru.primary.") && !$0.identifier.hasPrefix("okiru.follow.") }.count
        let primaryCount = modern ? 0 : enabled.reduce(0) { $0 + $1.legacyNotificationCost }
        guard primaryCount + otherCount <= ReminderPlanner.budget else { throw DisplayError(key:"error.capacity") }
        if !enabled.isEmpty {
            if #available(iOS 26.0, *) {
                guard AlarmManager.shared.authorizationState == .authorized else { throw DisplayError(key:"error.alarmPermission") }
            } else if !notificationAllowed { throw DisplayError(key:"error.notificationPermission") }
        }
        var desiredPrimaryIDs: Set<String> = []
        // Free our old follow-up budget before adding primaries so an edit cannot
        // temporarily exceed capacity and evict a primary or another notification.
        notifications.removePendingNotificationRequests(withIdentifiers:existing.filter { $0.identifier.hasPrefix("okiru.follow.") }.map(\.identifier))
        if !modern {
            let nextIDs = Set(enabled.flatMap { legacyRequests($0).map(\.identifier) })
            notifications.removePendingNotificationRequests(withIdentifiers:existing.filter { $0.identifier.hasPrefix("okiru.primary.") && !nextIDs.contains($0.identifier) }.map(\.identifier))
        }

        if #available(iOS 26.0, *) {
            if !enabled.isEmpty && AlarmManager.shared.authorizationState != .authorized { throw DisplayError(key:"error.alarmPermission") }
            let system = AlarmManager.shared.authorizationState == .authorized ? try AlarmManager.shared.alarms : []
            var systemIDs = Set(system.map(\.id))
            let legacyTestIDs = Set(
                (UserDefaults.standard.stringArray(forKey:legacyIntervalTestIDsKey) ?? [])
                    .compactMap(UUID.init(uuidString:))
            )
            try await cancelModernAlarms(legacyTestIDs)
            systemIDs.subtract(legacyTestIDs)
            UserDefaults.standard.removeObject(forKey:legacyIntervalTestIDsKey)
            var hashes = UserDefaults.standard.dictionary(forKey:"scheduledHashes") as? [String:String] ?? [:]
            let current = occurrences.filter { !$0.resolved && $0.scheduledAt <= now && $0.reminderEnd >= now }
            let oldRoutes = UserDefaults.standard.dictionary(forKey:"retainedAlarmRoutes") as? [String:String] ?? [:]
            var escalationRegistry = loadEscalationRegistry()
            let escalationPlans = makeEscalationPlans(alarms:alarms,occurrences:occurrences,now:now)
            let plannedEscalationIDs = Set(escalationPlans.flatMap { $0.items.map(\.id) })

            // Remove alarms that no longer belong to an enabled, unfinished
            // occurrence before building the new rolling window. Confirm the
            // system has actually released each slot before scheduling a
            // replacement; AlarmKit can otherwise report maximumLimitReached
            // immediately after a successful cancel call.
            let obsoleteEscalationIDs = Set(escalationRegistry.values.flatMap { $0 })
                .compactMap(UUID.init(uuidString:))
                .filter { !plannedEscalationIDs.contains($0) }
            try await cancelModernAlarms(Set(obsoleteEscalationIDs))
            systemIDs.subtract(obsoleteEscalationIDs)
            var desired = Set(enabled.map(\.id))
            desired.formUnion(current.map { $0.alarm.id })
            desired.formUnion(retainedRoutes.keys.compactMap(UUID.init(uuidString:)))
            desired.formUnion(plannedEscalationIDs)
            desired.formUnion(oldRoutes.compactMap { id,original in
                current.contains(where: { $0.alarm.id.uuidString == original }) ? UUID(uuidString:id) : nil
            })
            // AlarmManager.alarms only returns this app's alarms. Remove stale
            // registrations before scheduling replacements so they cannot
            // consume the AlarmKit quota indefinitely. Use `systemIDs` rather
            // than the original snapshot so an obsolete escalation is never
            // cancelled a second time in the same synchronization pass.
            let staleIDs = systemIDs.subtracting(desired)
            try await cancelModernAlarms(staleIDs)
            systemIDs.subtract(staleIDs)
            for id in staleIDs { hashes.removeValue(forKey:id.uuidString) }
            for alarm in enabled {
                let hash = [alarm.name,String(alarm.hour),String(alarm.minute),alarm.weekdays.sorted().map(String.init).joined(separator:","),String(alarm.oneShotDate.timeIntervalSince1970),alarm.sound.rawValue,soundDigest(alarm.sound),AppLanguage.effective].joined(separator:"|")
                if hashes[alarm.id.uuidString] != hash || !systemIDs.contains(alarm.id) {
                    if systemIDs.contains(alarm.id) {
                        try await cancelModernAlarms([alarm.id])
                        systemIDs.remove(alarm.id)
                    }
                    do {
                        try await scheduleModern(alarm,routeID:retainedRoutes[alarm.id.uuidString])
                    } catch let error as AlarmManager.AlarmError where error == .maximumLimitReached {
                        // Never let follow-up alarms prevent a user-created
                        // primary alarm. Free them, retry the primary, then
                        // refill only whatever capacity remains.
                        let registeredEscalations = Set(escalationRegistry.values.flatMap { $0 })
                            .compactMap(UUID.init(uuidString:))
                        try await cancelModernAlarms(Set(registeredEscalations))
                        systemIDs.subtract(registeredEscalations)
                        escalationRegistry.removeAll()
                        do {
                            try await scheduleModernWithQuotaRetry(
                                alarm,
                                routeID:retainedRoutes[alarm.id.uuidString]
                            )
                        } catch let retry as AlarmManager.AlarmError where retry == .maximumLimitReached {
                            throw DisplayError(key:"error.alarmLimit")
                        }
                    }
                    systemIDs.insert(alarm.id)
                    hashes[alarm.id.uuidString] = hash
                    log.info("Scheduled AlarmKit primary id=\(alarm.id.uuidString, privacy:.private) sound=\(alarm.sound.filename, privacy:.public)")
                }
                report.registeredAlarms.insert(alarm.id)
            }

            var actualEscalations: [PlannedReminder] = []
            var nextEscalationRegistry: [String:[String]] = [:]
            var capacityReached = false
            for plan in escalationPlans {
                guard !capacityReached else { break }
                for item in plan.items {
                    do {
                        if !systemIDs.contains(item.id) {
                            try await scheduleEscalation(
                                occurrence:plan.occurrence,
                                id:item.id,
                                at:item.at
                            )
                            systemIDs.insert(item.id)
                            log.info("Scheduled AlarmKit follow-up id=\(item.id.uuidString, privacy:.private) at=\(item.at, privacy:.public) sound=\(plan.occurrence.alarm.sound.filename, privacy:.public)")
                        }
                        nextEscalationRegistry[plan.occurrence.id,default:[]].append(item.id.uuidString)
                        actualEscalations.append(.init(
                            id:"okiru.alarmkit.\(item.id.uuidString)",
                            occurrenceID:plan.occurrence.id,
                            at:item.at,
                            sound:plan.occurrence.alarm.sound
                        ))
                    } catch let error as AlarmManager.AlarmError where error == .maximumLimitReached {
                        report.limited = true
                        capacityReached = true
                        break
                    }
                }
            }
            escalationRegistry = nextEscalationRegistry
            saveEscalationRegistry(escalationRegistry)
            report.actualReminders.append(contentsOf:actualEscalations)
            UserDefaults.standard.set(hashes,forKey:"scheduledHashes")
            var routes = UserDefaults.standard.dictionary(forKey:"retainedAlarmRoutes") as? [String:String] ?? [:]
            routes.merge(retainedRoutes) { _,new in new }
            routes = routes.filter { id,_ in UUID(uuidString:id).map(desired.contains) == true }
            UserDefaults.standard.set(routes,forKey:"retainedAlarmRoutes")
            if !report.registeredAlarms.isEmpty {
                let confirmed = Set(try AlarmManager.shared.alarms.map(\.id))
                guard report.registeredAlarms.isSubset(of:confirmed) else { throw DisplayError(key:"error.scheduleVerification") }
            }
        } else {
            if !enabled.isEmpty && !notificationAllowed { throw DisplayError(key:"error.notificationPermission") }
            for alarm in enabled {
                for request in legacyRequests(alarm,routeID:retainedRoutes[alarm.id.uuidString]) {
                    desiredPrimaryIDs.insert(request.identifier)
                    try await notifications.add(request)
                    log.info("Scheduled local primary id=\(request.identifier, privacy:.private) sound=\(alarm.sound.filename, privacy:.public)")
                }
                report.registeredAlarms.insert(alarm.id)
            }
        }
        let oldPrimary = existing.filter { $0.identifier.hasPrefix("okiru.primary.") && !desiredPrimaryIDs.contains($0.identifier) }.map(\.identifier)
        notifications.removePendingNotificationRequests(withIdentifiers:oldPrimary)

        let plan = ReminderPlanner.plan(occurrences:occurrences,now:now,primaryCount:primaryCount,otherPendingCount:otherCount)
        report.limited = report.limited || plan.capacityLimited
        let wantedReminders = notificationAllowed ? plan.reminders : []
        let wantedIDs = Set(wantedReminders.map(\.id))
        let obsolete = existing.filter { $0.identifier.hasPrefix("okiru.follow.") && !wantedIDs.contains($0.identifier) }.map(\.identifier)
        notifications.removePendingNotificationRequests(withIdentifiers:obsolete)
        for reminder in wantedReminders {
            let content = UNMutableNotificationContent()
            content.title = "Okiru"
            content.body = tf("notification.body.target",occurrences.first(where: { $0.id == reminder.occurrenceID })?.alarm.targetReps ?? 10)
            content.sound = UNNotificationSound(named:.init(rawValue:reminder.sound.filename))
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = reminder.occurrenceID
            content.userInfo = ["occurrenceID":reminder.occurrenceID]
            content.categoryIdentifier = "OKIRU_WAKE"
            var components = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from:reminder.at)
            components.timeZone = Calendar.current.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching:components,repeats:false)
            try await notifications.add(.init(identifier:reminder.id,content:content,trigger:trigger))
            log.info("Scheduled local follow-up id=\(reminder.id, privacy:.private) at=\(reminder.at, privacy:.public) sound=\(reminder.sound.filename, privacy:.public)")
        }
        let actual = await notifications.pendingNotificationRequests()
        let actualIDs = Set(actual.map(\.identifier))
        guard desiredPrimaryIDs.isSubset(of:actualIDs) else { throw DisplayError(key:"error.scheduleVerification") }
        let actualNotificationReminders = wantedReminders.filter { actualIDs.contains($0.id) }
        if actualNotificationReminders.count != wantedReminders.count { throw DisplayError(key:"error.scheduleVerification") }
        report.actualReminders.append(contentsOf:actualNotificationReminders)
        report.actualReminders.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        if !notificationAllowed && occurrences.contains(where: { !$0.resolved }) {
            report.warning = tr("error.notificationPermission")
        } else if !notificationSoundAllowed && occurrences.contains(where: { !$0.resolved }) {
            report.warning = tr("error.notificationSounds")
        }
        return report
    }

    private func soundDigest(_ sound: AlarmSound) -> String {
        if let cached = soundDigestCache[sound] { return cached }
        guard let url = Bundle.main.url(forResource:sound.rawValue,withExtension:"wav"),
              let data = try? Data(contentsOf:url) else { return "missing" }
        let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        soundDigestCache[sound] = digest
        return digest
    }

    private func legacyRequests(_ alarm: AlarmDefinition, routeID: String? = nil) -> [UNNotificationRequest] {
        let days: [Int?] = !alarm.isRepeating || alarm.weekdays.count == 7 ? [nil] : alarm.weekdays.sorted().map(Optional.some)
        return days.map { day in
            let content = UNMutableNotificationContent()
            content.title = alarm.name.isEmpty ? "Okiru" : alarm.name
            content.body = tf("notification.body.target",alarm.targetReps)
            content.sound = UNNotificationSound(named:.init(rawValue:alarm.sound.filename))
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["alarmID":routeID ?? alarm.id.uuidString]
            content.categoryIdentifier = "OKIRU_WAKE"
            let components: DateComponents
            if alarm.isRepeating {
                components = DateComponents(hour:alarm.hour,minute:alarm.minute,second:0,weekday:day)
            } else {
                var fixed = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from:alarm.oneShotDate)
                fixed.timeZone = Calendar.current.timeZone
                components = fixed
            }
            return .init(identifier:"okiru.primary.\(alarm.id).\(day ?? 0)",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:components,repeats:alarm.isRepeating))
        }
    }

    private func loadEscalationRegistry() -> [String:[String]] {
        let raw = UserDefaults.standard.dictionary(forKey:escalationRegistryKey) ?? [:]
        return raw.reduce(into:[:]) { result, pair in
            if let ids = pair.value as? [String] { result[pair.key] = ids }
        }
    }

    private func saveEscalationRegistry(_ value: [String:[String]]) {
        if value.isEmpty { UserDefaults.standard.removeObject(forKey:escalationRegistryKey) }
        else { UserDefaults.standard.set(value,forKey:escalationRegistryKey) }
    }

    @available(iOS 26.0, *)
    private struct EscalationPlan {
        var occurrence: AlarmOccurrence
        var items: [(id: UUID, at: Date)]
    }

    @available(iOS 26.0, *)
    private func makeEscalationPlans(
        alarms: [AlarmDefinition],
        occurrences: [AlarmOccurrence],
        now: Date
    ) -> [EscalationPlan] {
        let enabledIDs = Set(alarms.filter(\.enabled).map(\.id))
        let eligible = occurrences.filter {
            !$0.resolved && $0.reminderEnd > now
                && ($0.scheduledAt <= now || enabledIDs.contains($0.alarm.id))
        }
        var selected: [AlarmOccurrence] = eligible.filter { $0.scheduledAt <= now }
        for alarmID in enabledIDs {
            if let next = eligible
                .filter({ $0.alarm.id == alarmID && $0.scheduledAt > now })
                .min(by:{ $0.scheduledAt < $1.scheduledAt }) {
                selected.append(next)
            }
        }

        var seen: Set<String> = []
        return selected
            .sorted { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt }
            .filter { seen.insert($0.id).inserted }
            .compactMap { occurrence in
                let firstSlot = max(
                    1,
                    Int(floor(now.timeIntervalSince(occurrence.scheduledAt) / escalationInterval)) + 1
                )
                let finalSlot = Int(occurrence.reminderEnd.timeIntervalSince(occurrence.scheduledAt) / escalationInterval)
                guard firstSlot <= finalSlot else { return nil }
                let lastSlot = min(finalSlot,firstSlot + escalationWindowCount - 1)
                let items = (firstSlot...lastSlot).map { slot in
                    let date = occurrence.scheduledAt.addingTimeInterval(Double(slot) * escalationInterval)
                    return (id:stableEscalationID(occurrenceID:occurrence.id,slot:slot),at:date)
                }
                return EscalationPlan(occurrence:occurrence,items:items)
            }
    }

    private func stableEscalationID(occurrenceID: String, slot: Int) -> UUID {
        let bytes = Array(SHA256.hash(data:Data("alarmkit|\(occurrenceID)|\(slot)".utf8)).prefix(16))
        return UUID(uuid:(
            bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
            bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]
        ))
    }

    @available(iOS 26.0, *)
    private func cancelModernAlarms(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        var remaining = ids

        // Treat cancellation as idempotent. The same alarm can disappear
        // between the registry snapshot and this call after firing or after a
        // previous reconciliation.
        for attempt in 0..<6 {
            let registered = Set(try AlarmManager.shared.alarms.map(\.id))
            remaining.formIntersection(registered)
            if remaining.isEmpty { return }
            for id in remaining { try? AlarmManager.shared.cancel(id:id) }
            if attempt < 5 {
                try await Task.sleep(nanoseconds:200_000_000)
            }
        }

        let registered = Set(try AlarmManager.shared.alarms.map(\.id))
        guard remaining.isDisjoint(with:registered) else {
            throw DisplayError(key:"error.scheduleVerification")
        }
    }

    @available(iOS 26.0, *)
    private func scheduleModernWithQuotaRetry(_ alarm: AlarmDefinition, routeID: String?) async throws {
        for attempt in 0..<4 {
            do {
                try await scheduleModern(alarm,routeID:routeID)
                return
            } catch let error as AlarmManager.AlarmError where error == .maximumLimitReached {
                guard attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds:250_000_000)
            }
        }
    }

    @available(iOS 26.0, *)
    private func scheduleEscalation(occurrence: AlarmOccurrence, id: UUID, at date: Date) async throws {
        let alarm = occurrence.alarm
        let button = AlarmButton(
            text:LocalizedStringResource(stringLiteral:tr("challenge.start")),
            textColor:.white,
            systemImageName:"figure.strengthtraining.traditional"
        )
        let title = LocalizedStringResource(stringLiteral:alarm.name.isEmpty ? "Okiru" : alarm.name)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title:title,secondaryButton:button,secondaryButtonBehavior:.custom)
        } else {
            alert = .init(
                title:title,
                stopButton:.init(
                    text:LocalizedStringResource(stringLiteral:tr("stop")),
                    textColor:.white,
                    systemImageName:"stop.fill"
                ),
                secondaryButton:button,
                secondaryButtonBehavior:.custom
            )
        }
        let attributes = AlarmAttributes(
            presentation:AlarmPresentation(alert:alert),
            metadata:OkiruAlarmMetadata(alarmID:alarm.id.uuidString),
            tintColor:.orange
        )
        let challengeIntent = OpenChallengeIntent(alarmID:alarm.id.uuidString)
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule:.fixed(date),
            attributes:attributes,
            stopIntent:challengeIntent,
            secondaryIntent:challengeIntent,
            sound:.named(alarm.sound.filename)
        )
        _ = try await AlarmManager.shared.schedule(id:id,configuration:configuration)
    }

    @available(iOS 26.0, *)
    private func scheduleModern(_ alarm: AlarmDefinition, routeID: String? = nil) async throws {
        let weekdays: [Locale.Weekday] = [.sunday,.monday,.tuesday,.wednesday,.thursday,.friday,.saturday]
        let schedule: Alarm.Schedule = alarm.isRepeating
            ? .relative(.init(time:.init(hour:alarm.hour,minute:alarm.minute),repeats:.weekly(alarm.weekdays.sorted().map { weekdays[$0-1] })))
            : .fixed(alarm.oneShotDate)
        let button = AlarmButton(text:LocalizedStringResource(stringLiteral:tr("challenge.start")),textColor:.white,systemImageName:"figure.strengthtraining.traditional")
        let title = LocalizedStringResource(stringLiteral:alarm.name.isEmpty ? "Okiru" : alarm.name)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title:title,secondaryButton:button,secondaryButtonBehavior:.custom)
        } else {
            alert = .init(title:title,stopButton:.init(text:LocalizedStringResource(stringLiteral:tr("stop")),textColor:.white,systemImageName:"stop.fill"),secondaryButton:button,secondaryButtonBehavior:.custom)
        }
        let attributes = AlarmAttributes(presentation:AlarmPresentation(alert:alert),metadata:OkiruAlarmMetadata(alarmID:alarm.id.uuidString),tintColor:.orange)
        // AlarmKit always supplies a system Stop control. We cannot remove or
        // override that control, but both system actions can route directly to
        // the unfinished challenge. Stopping the system alert never marks the
        // occurrence complete and never cancels its follow-up reminders.
        let challengeIntent = OpenChallengeIntent(alarmID:routeID ?? alarm.id.uuidString)
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule:schedule,
            attributes:attributes,
            stopIntent:challengeIntent,
            secondaryIntent:challengeIntent,
            sound:.named(alarm.sound.filename)
        )
        _ = try await AlarmManager.shared.schedule(id:alarm.id,configuration:configuration)
    }

    func stopCurrentSound(for alarmID: UUID) {
        if #available(iOS 26.0, *) {
            try? AlarmManager.shared.stop(id:alarmID)
            let routes = UserDefaults.standard.dictionary(forKey:"retainedAlarmRoutes") as? [String:String] ?? [:]
            for (id,original) in routes where original == alarmID.uuidString {
                if let uuid = UUID(uuidString:id) { try? AlarmManager.shared.stop(id:uuid) }
            }
        }
    }
    func cancelOccurrence(_ id: String) async {
        if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized {
            var registry = loadEscalationRegistry()
            for value in registry.removeValue(forKey:id) ?? [] {
                if let alarmID = UUID(uuidString:value) { try? AlarmManager.shared.cancel(id:alarmID) }
            }
            saveEscalationRegistry(registry)
        }
        let requests = await notifications.pendingNotificationRequests()
        notifications.removePendingNotificationRequests(withIdentifiers:requests.filter { ($0.content.userInfo["occurrenceID"] as? String) == id }.map(\.identifier))
        let delivered = await notifications.deliveredNotifications()
        notifications.removeDeliveredNotifications(withIdentifiers:delivered.filter { ($0.request.content.userInfo["occurrenceID"] as? String) == id }.map { $0.request.identifier })
    }
    func testSound(_ sound: AlarmSound) async throws {
        let settings = await notifications.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw DisplayError(key:"error.notificationPermission") }
        guard settings.alertSetting == .enabled else { throw DisplayError(key:"error.notificationAlerts") }
        guard settings.soundSetting == .enabled else { throw DisplayError(key:"error.notificationSounds") }
        let pending = await notifications.pendingNotificationRequests()
        guard pending.filter({ $0.identifier != "okiru.test" }).count < ReminderPlanner.budget else { throw DisplayError(key:"error.capacity") }
        notifications.removePendingNotificationRequests(withIdentifiers:["okiru.test"])
        notifications.removeDeliveredNotifications(withIdentifiers:["okiru.test"])
        let content = UNMutableNotificationContent(); content.title = "Okiru"; content.body = tr("test.alarm")
        content.sound = UNNotificationSound(named:.init(rawValue:sound.filename))
        content.interruptionLevel = .timeSensitive
        try await notifications.add(.init(identifier:"okiru.test",content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:5,repeats:false)))
    }

    func reset() async throws {
        if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized {
            let hashes = UserDefaults.standard.dictionary(forKey:"scheduledHashes") ?? [:]
            for alarm in try AlarmManager.shared.alarms where hashes[alarm.id.uuidString] != nil { try AlarmManager.shared.cancel(id:alarm.id) }
            for value in loadEscalationRegistry().values.flatMap({ $0 }) {
                if let id = UUID(uuidString:value) { try? AlarmManager.shared.cancel(id:id) }
            }
            for value in UserDefaults.standard.stringArray(forKey:legacyIntervalTestIDsKey) ?? [] {
                if let id = UUID(uuidString:value) { try? AlarmManager.shared.cancel(id:id) }
            }
            UserDefaults.standard.removeObject(forKey:"scheduledHashes")
            UserDefaults.standard.removeObject(forKey:"retainedAlarmRoutes")
            UserDefaults.standard.removeObject(forKey:escalationRegistryKey)
            UserDefaults.standard.removeObject(forKey:legacyIntervalTestIDsKey)
        }
        let pending = await notifications.pendingNotificationRequests()
        notifications.removePendingNotificationRequests(withIdentifiers:pending.filter { $0.identifier.hasPrefix("okiru.") }.map(\.identifier))
        let delivered = await notifications.deliveredNotifications()
        notifications.removeDeliveredNotifications(withIdentifiers:delivered.filter { $0.request.identifier.hasPrefix("okiru.") }.map { $0.request.identifier })
    }
}
