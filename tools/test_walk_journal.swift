import Foundation

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

        func photo(_ id: String, _ site: Int = 2, tripID: String? = nil) -> WalkPhotoVisit {
            .init(id: id, placeID: site, name: "老街", date: "2026.11.25", isSimulated: false, tripID: tripID)
        }
        let walking = UUID().uuidString
        try reopened.begin(id: walking, placeID: 3, name: "巷口", isSimulated: false, latitude: 24, longitude: 120)
        let first = UUID().uuidString, second = UUID().uuidString, extra = UUID().uuidString
        let visits = [photo(first), photo(second), photo(pending, 3), photo(walking, 3), photo(stopped, 3),
                      photo(abandoned, 3), photo(extra, 3, tripID: stopped)]
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
        try check(retry.entry(id: walking)?.status == .walking && retry.entry(id: pending) == recovered, "live walk and receipt retain their own state")
        try checkRepairs(in: folder, start: start, end: end)
        try checkUnreadableEntry(in: folder)
        print("WalkJournalStore persistence and migration tests passed")
    }

    @MainActor static func checkRepairs(in root: URL, start: Date, end: Date) throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("repairs", isDirectory: true)
        let suite = "walk-journal-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WalkJournalStore(folder: folder, defaults: defaults)
        let trip = UUID().uuidString
        try store.begin(id: trip, placeID: 15, name: "公園", isSimulated: false, latitude: 24, longitude: 120, at: start)
        let corrupt = UUID().uuidString
        let corruptFile = folder.appendingPathComponent(corrupt + ".json")
        let original = Data("{".utf8)
        try original.write(to: corruptFile)
        let reopened = WalkJournalStore(folder: folder, defaults: defaults)
        try check(reopened.entries().count == 1 && reopened.hasUnreadableEntries, "one damaged entry leaves other trips available")
        try check(Data(contentsOf: corruptFile) == original, "inspecting the journal preserves damaged bytes")
        try reopened.recoverArrival(id: corrupt, placeID: 2, name: "老街", isSimulated: false,
                                    date: "2026.11.27", latitude: nil, longitude: nil)
        try reopened.finish(id: corrupt, status: .arrived, stop: 1, walked: 180)
        try reopened.finish(id: corrupt, status: .arrived, stop: 1, walked: 0)
        try check(reopened.entry(id: corrupt)?.walked == 180 && !reopened.hasUnreadableEntries,
                  "receipt restores the damaged trip and duplicate acknowledgements preserve known mileage")
        let retained = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "damaged" }
        try check(retained.count == 1 && Data(contentsOf: retained[0]) == original, "recovery kept the original file")

        // 讓這一筆的原子替換失敗，再放回仍標成散步中的舊檔。
        let tripFile = folder.appendingPathComponent(trip + ".json")
        let savedFile = folder.appendingPathComponent("saved-trip")
        try fm.moveItem(at: tripFile, to: savedFile)
        try fm.createDirectory(at: tripFile, withIntermediateDirectories: false)
        do {
            try reopened.stop(id: trip, at: end, walked: 120)
            preconditionFailure("收工寫入應該失敗")
        } catch {}
        try reopened.interruptWalking()
        try check(reopened.entry(id: trip)?.status == .walking, "a pending stop must not become an interruption")
        try fm.removeItem(at: tripFile)
        try fm.moveItem(at: savedFile, to: tripFile)
        let restarted = WalkJournalStore(folder: folder, defaults: defaults)
        try restarted.interruptWalking()
        let stopped = try restarted.entry(id: trip)
        check(stopped?.status == .stopped && stopped?.endedAt == end && stopped?.walked == 120,
              "pending stop restores the original time and distance after relaunch")

        let progressFolder = root.appendingPathComponent("progress", isDirectory: true)
        try fm.createDirectory(at: progressFolder, withIntermediateDirectories: false)
        let old = #"{"ver":2,"voice":true,"drawn":7,"seen":[2],"recent":[2],"sim_drawn":0,"sim_seen":[],"sim_recent":[]}"#
        try Data(old.utf8).write(to: progressFolder.appendingPathComponent("footprints.json"))
        let progress = WalkProgress(folder: progressFolder)
        try progress.save(["theme": "dark"])
        let restored = WalkProgress(folder: progressFolder)
        check(restored.visitedPlaces.real == [2] && restored.initialScript.contains(#""theme":"dark""#),
              "theme survives relaunch without losing existing footprints")
        try restored.save(["theme": ""])
        check(WalkProgress(folder: progressFolder).initialScript.contains(#""theme":"""#), "system theme can be restored")

        let legacyPhoto = #"{"id":"p","placeID":2,"name":"散步途中","date":"","isSimulated":false,"tripID":"t"}"#
        let enRoute = try JSONDecoder().decode(WalkPhotoVisit.self, from: Data(legacyPhoto.utf8))
        check(enRoute.shareText == "和小嚮導散步中！#散步吧", "older en-route photos use an en-route caption")
        let simulated = WalkPhotoVisit(id: "s", placeID: 2, name: "老街", date: "", isSimulated: true, wasEnRoute: false)
        check(simulated.shareText.contains("模擬") && simulated.shareText.contains("老街"), "simulated arrival is identified")
        let real = WalkPhotoVisit(id: "r", placeID: 2, name: "公園", date: "", isSimulated: false, wasEnRoute: false)
        check(real.shareText == "跟著小嚮導走到了公園！#散步吧", "real arrival retains its place caption")
    }

    @MainActor static func checkUnreadableEntry(in root: URL) throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("unavailable", isDirectory: true)
        let blocked = UUID().uuidString, healthy = UUID().uuidString
        let first = WalkJournalStore(folder: folder)
        try first.begin(id: blocked, placeID: 7, name: "原地點", isSimulated: false, latitude: 24, longitude: 120)
        try first.setNote(id: blocked, note: "先前儲存的筆記")
        try first.begin(id: healthy, placeID: 8, name: "公園", isSimulated: false, latitude: 24, longitude: 120)
        // 目錄無法當作一筆 JSON 來讀。這個情境不依賴測試執行帳號的檔案權限。
        let file = folder.appendingPathComponent(blocked + ".json")
        let preserved = folder.appendingPathComponent("preserved")
        let marker = file.appendingPathComponent("untouched")
        try fm.moveItem(at: file, to: preserved)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        try Data([7]).write(to: marker)
        let reopened = WalkJournalStore(folder: folder)
        try check(reopened.entries().map(\.id) == [healthy] && reopened.hasUnreadableEntries,
                  "other records remain readable during an individual file access failure")
        do {
            _ = try reopened.entry(id: blocked)
            preconditionFailure("暫時無法讀取的紀錄應回報錯誤")
        } catch {}
        do {
            try reopened.recoverArrival(id: blocked, placeID: 7, name: "原地點", isSimulated: false,
                                        date: nil, latitude: nil, longitude: nil)
            preconditionFailure("不可覆寫尚未讀取的舊檔")
        } catch {}
        try reopened.finish(id: healthy, status: .arrived, stop: 1)
        let another = UUID().uuidString
        try reopened.recoverArrival(id: another, placeID: 9, name: "老街", isSimulated: false,
                                    date: "2026.11.27", latitude: nil, longitude: nil)
        try check(reopened.entry(id: another)?.status == .arrived && reopened.entry(id: healthy)?.status == .arrived,
                  "a healthy trip and a different pending receipt can both finish")
        let oldPhoto = WalkPhotoVisit(id: blocked, placeID: 7, name: "原地點", date: "", isSimulated: false)
        try reopened.migrate(photoVisits: [oldPhoto], seen: [7], simSeen: []) { _ in nil }
        try check(reopened.needsMigration && Data(contentsOf: marker) == Data([7]),
                  "migration waits without replacing or moving the unreadable record")
        try fm.removeItem(at: file)
        try fm.moveItem(at: preserved, to: file)
        try check(reopened.entry(id: blocked)?.note == "先前儲存的筆記" && !reopened.hasUnreadableEntries,
                  "the same store can retry without dropping the original note")
        try reopened.finish(id: blocked, status: .arrived, stop: 2)
        try reopened.migrate(photoVisits: [oldPhoto], seen: [7], simSeen: []) { _ in nil }
        try check(!reopened.needsMigration && reopened.entries().count == 3,
                  "migration completes on retry without duplicating the previously unreadable place")
    }
}
