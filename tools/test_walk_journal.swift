import Foundation

// The production album uses UIKit. Only its visit metadata is needed by this macOS test.
enum WalkPhotoAlbum {
    struct Visit {
        let id: String
        let placeID: Int
        let name: String
        let date: String
        let isSimulated: Bool
        var tripID: String? = nil
    }
}

@main
struct WalkJournalTests {
    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    @MainActor static func main() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: folder) }
        let store = WalkJournalStore(folder: folder)
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 23))!
        let end = calendar.date(byAdding: .hour, value: 2, to: start)!
        let trip = UUID().uuidString
        try store.begin(id: trip, placeID: 1, name: "出發地", isSimulated: false, latitude: 23, longitude: 120, at: start)
        try store.setNote(id: trip, note: "跨日散步")
        let editor = WalkJournalStore(folder: folder)
        try editor.setFavorite(id: trip, favorite: true)
        try store.begin(id: trip, placeID: 2, name: "老街", isSimulated: false, latitude: 24, longitude: 121, at: end)
        try store.finish(id: trip, status: .arrived, at: end, stop: -1, walked: .infinity)
        try store.finish(id: trip, status: .arrived, at: start, stop: 2, walked: 0)
        try store.finish(id: trip, status: .stopped, at: start)
        let result = try editor.entry(id: trip)!
        check(result.placeID == 2 && result.latitude == 24 && result.startedAt == start, "retarget kept the same trip")
        check(result.status == .arrived && result.endedAt == end && result.date == "2026.11.27", "first finish wins across midnight")
        check(result.note == "跨日散步" && result.favorite && result.stop == 2 && result.walked == 0, "concurrent editors and finish retries")

        let stopped = UUID().uuidString, abandoned = UUID().uuidString, pending = UUID().uuidString
        for id in [stopped, abandoned, pending] {
            try store.begin(id: id, placeID: 3, name: "巷口", isSimulated: false, latitude: 24, longitude: 120, at: start)
        }
        try store.finish(id: stopped, status: .stopped, at: end)
        let reopened = WalkJournalStore(folder: folder)
        try reopened.interruptWalking(except: pending)
        let interrupted = try reopened.entry(id: abandoned)!
        check(interrupted.status == .interrupted && interrupted.endedAt == nil, "cold start has no made-up end time")
        try check(reopened.entry(id: stopped)?.status == .stopped && reopened.entry(id: pending)?.status == .walking, "cold start preserves a stop and pending receipt")
        try reopened.recoverArrival(id: pending, placeID: 3, name: "巷口", isSimulated: false,
                                    date: "2026.11.27", latitude: nil, longitude: nil)
        let recovered = try reopened.entry(id: pending)!
        check(recovered.status == .arrived && recovered.date == "2026.11.27" && recovered.endedAt == nil && recovered.latitude == 24, "receipt preserves known coordinates")

        func photo(_ id: String, _ site: Int = 2, tripID: String? = nil) -> WalkPhotoAlbum.Visit {
            .init(id: id, placeID: site, name: "老街", date: "2026.11.25", isSimulated: false, tripID: tripID)
        }
        let first = UUID().uuidString, second = UUID().uuidString, extra = UUID().uuidString
        let visits = [photo(first), photo(second), photo(stopped, 3), photo(abandoned, 3), photo(extra, 3, tripID: stopped)]
        // Force a real failure on the second entry after the first file is already on disk.
        let obstruction = folder.appendingPathComponent(second + ".json", isDirectory: true)
        try manager.createDirectory(at: obstruction, withIntermediateDirectories: false)
        do {
            try reopened.migrate(photoVisits: visits, seen: [2, 4], simSeen: [2]) { _ in nil }
            preconditionFailure("migration unexpectedly succeeded through an existing directory")
        } catch {
            check(reopened.needsMigration, "a partial migration must be retryable")
        }
        try manager.removeItem(at: obstruction)
        let retry = WalkJournalStore(folder: folder)
        try check(retry.entry(id: first)?.date == "2026.11.25" && retry.entry(id: second) == nil, "only the first photo was migrated")
        try retry.setNote(id: first, note: "第一張照片")
        try retry.migrate(photoVisits: visits, seen: [2, 4, 4], simSeen: [2]) { _ in nil }
        try retry.migrate(photoVisits: [], seen: [8], simSeen: []) { _ in nil }
        let entries = try retry.entries()
        check(!retry.needsMigration && entries.filter { $0.placeID == 2 && $0.status == .arrived }.count == 3, "repeat visits retained and migration runs once")
        let legacy = entries.filter { $0.status == .legacy }
        check(legacy.count == 2 && legacy.contains { $0.isSimulated && $0.placeID == 2 }, "legacy data separates simulated and real locations")
        check(legacy.allSatisfy { $0.date.isEmpty && $0.startedAt == nil && $0.endedAt == nil }, "legacy locations have no trip dates")
        try check(retry.entry(id: first)?.note == "第一張照片" && retry.entry(id: extra) == nil, "migration preserves edits and ignores extra photos")
        try check(retry.entry(id: stopped)?.status == .stopped && retry.entry(id: abandoned)?.status == .interrupted, "photos alone cannot complete an existing trip")
        print("WalkJournalStore persistence and migration tests passed")
    }
}
