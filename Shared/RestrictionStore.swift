import Foundation
import FamilyControls
import ManagedSettings
import OkiruCore

struct SharedRestrictionState: Codable {
    var version = 1
    var definitions: [AlarmDefinition] = []
    var occurrences: [AlarmOccurrence] = []
    var lastError: String?

    mutating func materialize(at now: Date) {
        let cal = Calendar.current
        for alarm in definitions where alarm.enabled && alarm.restriction.enabled {
            let dates = ScheduleCalculator.dates(for: alarm, from: now.addingTimeInterval(-2*86400), through: now.addingTimeInterval(2*86400), calendar: cal)
            for date in dates {
                let occurrence = AlarmOccurrence(alarm: alarm, scheduledAt: date, calendar: cal)
                let window = RestrictionWindow(occurrence: occurrence, calendar: cal)
                if window.start <= now && !occurrences.contains(where: { $0.id == occurrence.id }) { occurrences.append(occurrence) }
            }
        }
    }
    func active(at now: Date) -> [RestrictionWindow] {
        occurrences.filter { $0.alarm.restriction.enabled }.map { RestrictionWindow(occurrence: $0) }.filter { $0.isActive(at:now) }
    }
}

enum SharedRestrictionStore {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "OkiruAppGroup") as? String ?? "group.com.shawn.okiru" }
    static let storeName = ManagedSettingsStore.Name("okiru.restrictions")
    static func location() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw DisplayError(key:"error.appgroup")
        }
        return root.appendingPathComponent("restrictions-v1.json")
    }
    static func update(_ mutate: (inout SharedRestrictionState) throws -> Void) throws -> SharedRestrictionState {
        let url = try location()
        var coordinationError: NSError?
        var result: Result<SharedRestrictionState,Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                var state: SharedRestrictionState
                if FileManager.default.fileExists(atPath:coordinatedURL.path) {
                    state = try JSONDecoder().decode(SharedRestrictionState.self, from:Data(contentsOf:coordinatedURL))
                } else { state = .init() }
                try mutate(&state)
                try JSONEncoder().encode(state).write(to:coordinatedURL, options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                return state
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DisplayError(key:"error.storage") }
        _ = try result.get()
        // The caller must not report a successful restriction update unless
        // the coordinated write is actually visible to other processes.
        return try JSONDecoder().decode(SharedRestrictionState.self,from:Data(contentsOf:url))
    }
    static func read() throws -> SharedRestrictionState {
        let url = try location()
        var error: NSError?
        var result: Result<SharedRestrictionState,Error>?
        NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&error) { item in
            result = Result {
                guard FileManager.default.fileExists(atPath:item.path) else { return .init() }
                return try JSONDecoder().decode(SharedRestrictionState.self, from:Data(contentsOf:item))
            }
        }
        if let error { throw error }
        return try result?.get() ?? .init()
    }
    static func apply(_ state: SharedRestrictionState, at now: Date = Date()) throws {
        let active = state.active(at:now)
        let settings = ManagedSettingsStore(named:storeName)
        guard !active.isEmpty else { settings.clearAllSettings(); return }
        var policies: [Set<ApplicationToken>] = []
        var directlyBlocked: Set<ApplicationToken> = []
        var blockedWebsites: Set<WebDomainToken> = []
        for window in active {
            let selected: Set<ApplicationToken>
            if let data = window.selectionData {
                selected = try JSONDecoder().decode(FamilyActivitySelection.self,from:data).applicationTokens
            } else { selected = [] }
            policies.append(selected)
            if let data = window.blockedSelectionData {
                let blocked = try JSONDecoder().decode(FamilyActivitySelection.self,from:data)
                directlyBlocked.formUnion(blocked.applicationTokens)
                blockedWebsites.formUnion(blocked.webDomainTokens)
            }
        }
        let allowed = RestrictionRules.commonExceptions(policies)
        settings.shield.applicationCategories = .all(except:allowed.subtracting(directlyBlocked))
        settings.shield.applications = directlyBlocked.isEmpty ? nil : directlyBlocked
        settings.shield.webDomainCategories = .all(except:[])
        settings.shield.webDomains = blockedWebsites.isEmpty ? nil : blockedWebsites
    }
    static func handleMonitorCallback() {
        do {
            let state = try update { $0.materialize(at:Date()) }
            try apply(state)
        } catch {
            // Do not clear an existing shield when state cannot be read.
            NSLog("Okiru restriction callback failed: %@", String(describing:error))
        }
    }
}
