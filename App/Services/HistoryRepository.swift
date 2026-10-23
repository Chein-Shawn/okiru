import Foundation
import SwiftData
import OkiruCore

struct AppSnapshot: Codable {
    var version = 1
    var alarms: [AlarmDefinition] = []
    var occurrences: [AlarmOccurrence] = []
    var events: [WakeEvent] = []
    var lastReconciledAt = Date()
    var clearedOccurrenceIDs: Set<String>? = []
}

@Model final class StoreBlob {
    @Attribute(.unique) var key: String
    var payload: Data
    init(key: String = "snapshot", payload: Data) { self.key = key; self.payload = payload }
}

@MainActor final class HistoryRepository {
    let container: ModelContainer
    let context: ModelContext
    init() throws {
        container = try ModelContainer(for:StoreBlob.self)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    func load() throws -> AppSnapshot {
        if let blob = try context.fetch(FetchDescriptor<StoreBlob>()).first {
            return try JSONDecoder().decode(AppSnapshot.self,from:blob.payload)
        }
        return .init()
    }
    func save(_ snapshot: AppSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        if let blob = try context.fetch(FetchDescriptor<StoreBlob>()).first { blob.payload = data }
        else { context.insert(StoreBlob(payload:data)) }
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
