import Foundation

extension Notification.Name {
    static let walkJournalDidChange = Notification.Name("walkJournalDidChange")
}

@MainActor
final class WalkJournalStore {
    enum Status: String, Codable {
        case walking, arrived, stopped, interrupted, legacy
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        var placeID: Int
        var name: String
        let isSimulated: Bool
        // 只有到訪地點、沒有逐趟資料時，日期留空。
        var date: String
        var startedAt: Date?
        var endedAt: Date?
        var status: Status
        var latitude: Double?
        var longitude: Double?
        var note = ""
        var favorite = false
        var stop: Int?
        var walked: Double?
    }

    struct Place {
        let name: String
        let latitude: Double?
        let longitude: Double?
    }

    private struct Site: Hashable {
        let placeID: Int
        let simulated: Bool
    }

    private let folder: URL
    private let defaults: UserDefaults
    private let pendingStopsKey = "Walk.journalPendingStops"
    private let manager = FileManager.default
    private let day: DateFormatter
    private var prepared = false
    private var cached: [UUID: Entry] = [:]
    private var damagedFiles: [UUID: URL] = [:]
    private var readFailures: [UUID: (file: URL, error: Error)] = [:]
    var hasUnreadableEntries: Bool { !damagedFiles.isEmpty || !readFailures.isEmpty }
    private var revision: UInt?
    // 兩個畫面或兩個 store 共用同一份日誌時，舊的記憶體清單須重新讀取。
    private static var diskRevision: UInt = 0

    init(folder: URL? = nil, defaults: UserDefaults = .standard) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("Walk/Journal", isDirectory: true)
        self.defaults = defaults
        day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = .autoupdatingCurrent
        day.dateFormat = "yyyy.MM.dd"
        day.isLenient = false
    }

    private var migrationMarker: URL { folder.appendingPathComponent("migrated-v1") }
    var needsMigration: Bool { !manager.fileExists(atPath: migrationMarker.path) }

    func entries() throws -> [Entry] {
        try load()
        return cached.values.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            let left = lhs.endedAt ?? lhs.startedAt
            let right = rhs.endedAt ?? rhs.startedAt
            if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
            return lhs.id < rhs.id
        }
    }

    func entry(id: String) throws -> Entry? {
        guard let key = UUID(uuidString: id) else { return nil }
        try load()
        if let failure = readFailures[key] { throw failure.error }
        return cached[key]
    }

    func begin(id: String, placeID: Int, name: String, isSimulated: Bool, latitude: Double?,
               longitude: Double?, at: Date = Date()) throws {
        try load()
        let coordinates = Self.coordinates(latitude, longitude)
        let key = try Self.key(id)
        var value: Entry
        if let existing = cached[key] {
            guard existing.status == .walking else { return }
            guard existing.isSimulated == isSimulated else { throw CocoaError(.fileReadCorruptFile) }
            value = existing
            value.placeID = placeID
            value.name = name
            if existing.placeID != placeID || coordinates.0 != nil {
                value.latitude = coordinates.0
                value.longitude = coordinates.1
            }
        } else {
            value = Entry(id: id, placeID: placeID, name: name, isSimulated: isSimulated,
                          date: day.string(from: at), startedAt: at, endedAt: nil, status: .walking,
                          latitude: coordinates.0, longitude: coordinates.1)
        }
        if try write(value) { notify() }
    }

    func finish(id: String, status: Status, date: String? = nil, at: Date = Date(),
                stop: Int? = nil, walked: Double? = nil) throws {
        guard status == .arrived || status == .stopped || status == .interrupted else { return }
        guard var value = try entry(id: id) else { throw CocoaError(.fileReadNoSuchFile) }
        guard value.status == .walking || value.status == status ||
                (value.status == .interrupted && status == .arrived) else { return }
        if value.status != status {
            value.status = status
            if status != .interrupted {
                value.endedAt = at
                value.date = knownDay(date) ?? day.string(from: at)
            }
        }
        if value.stop == nil, let stop, stop >= 0 { value.stop = stop }
        if value.walked == nil, let walked, walked.isFinite, walked >= 0 { value.walked = walked }
        if try write(value) { notify() }
    }

    // 按下收工時就記下結束時間。日誌暫時無法寫入時，下次再開啟仍能用原時間補記。
    private var pendingStops: [String: [String: Any]] {
        defaults.dictionary(forKey: pendingStopsKey) as? [String: [String: Any]] ?? [:]
    }

    func stop(id: String, at: Date = Date(), stop: Int? = nil, walked: Double? = nil) throws {
        let key = try Self.key(id).uuidString
        var pending = pendingStops
        if pending[key] == nil {
            var receipt: [String: Any] = ["at": at]
            if let stop, stop >= 0 { receipt["stop"] = stop }
            if let walked, walked.isFinite, walked >= 0 { receipt["walked"] = walked }
            pending[key] = receipt
            defaults.set(pending, forKey: pendingStopsKey)
        }
        if let receipt = pending[key] { try applyStop(id: key, receipt: receipt) }
    }

    private func applyStop(id: String, receipt: [String: Any]) throws {
        guard let at = receipt["at"] as? Date else { throw CocoaError(.fileReadCorruptFile) }
        if try entry(id: id) != nil {
            try finish(id: id, status: .stopped, at: at, stop: receipt["stop"] as? Int,
                       walked: receipt["walked"] as? Double)
        }
        var pending = pendingStops
        pending.removeValue(forKey: id)
        if pending.isEmpty { defaults.removeObject(forKey: pendingStopsKey) }
        else { defaults.set(pending, forKey: pendingStopsKey) }
    }

    func retryPendingStops() {
        for (id, receipt) in pendingStops {
            // 這一筆寫入失敗時保留回條，讓其他行程仍能補記。
            try? applyStop(id: id, receipt: receipt)
        }
    }

    // 舊版抵達回條只有日期。重新開啟 App 的時間不能當成抵達時間。
    func recoverArrival(id: String, placeID: Int, name: String, isSimulated: Bool, date: String?,
                        latitude: Double?, longitude: Double?) throws {
        try load()
        let recovered = arrival(id: id, placeID: placeID, name: name, simulated: isSimulated,
                                date: date, latitude: latitude, longitude: longitude)
        if try mergeArrival(recovered) { notify() }
    }

    func interruptWalking(except id: String? = nil) throws {
        try load()
        retryPendingStops()
        let preserved = id.flatMap(UUID.init(uuidString:))
        let waiting = Set(pendingStops.keys)
        let active = cached.filter { $0.key != preserved && !waiting.contains($0.key.uuidString) && $0.value.status == .walking }
        var changed = false
        defer { if changed { notify() } }
        for (_, var value) in active {
            value.status = .interrupted
            value.endedAt = nil
            if try write(value) { changed = true }
        }
    }

    func setNote(id: String, note: String) throws {
        guard var value = try entry(id: id) else { throw CocoaError(.fileReadNoSuchFile) }
        value.note = note
        if try write(value) { notify() }
    }

    func setFavorite(id: String, favorite: Bool) throws {
        guard var value = try entry(id: id) else { throw CocoaError(.fileReadNoSuchFile) }
        value.favorite = favorite
        if try write(value) { notify() }
    }

    func migrate(photoVisits: [WalkPhotoVisit], seen: [Int], simSeen: [Int],
                 place: (Int) -> Place?) throws {
        guard needsMigration else { return }
        try load()
        var changed = false
        defer { if changed { notify() } }
        for visit in photoVisits where visit.tripID == nil {
            // 新版途中也能留照；已有逐趟紀錄時，以該趟的實際狀態為準。
            let key = try Self.key(visit.id)
            if readFailures[key] != nil { continue }
            if var existing = cached[key] {
                // 舊回條可能沒有日期；同趟同地的到站照片保留了日曆日期。
                if existing.status == .arrived, existing.date.isEmpty,
                   existing.placeID == visit.placeID, existing.isSimulated == visit.isSimulated,
                   let date = knownDay(visit.date) {
                    existing.date = date
                    if try write(existing) { changed = true }
                }
                continue
            }
            let site = place(visit.placeID)
            let record = arrival(id: visit.id, placeID: visit.placeID, name: visit.name,
                                 simulated: visit.isSimulated, date: visit.date,
                                 latitude: site?.latitude, longitude: site?.longitude)
            if try write(record) { changed = true }
        }
        // 尚有舊檔無法讀取時，無法判斷它代表哪一站，稍後再補舊地點並標記遷移完成。
        guard readFailures.isEmpty else { return }
        var represented = Set(cached.values.filter { $0.status == .arrived || $0.status == .legacy }
            .map { Site(placeID: $0.placeID, simulated: $0.isSimulated) })
        for (simulated, ids) in [(false, seen), (true, simSeen)] {
            for placeID in ids where placeID > 0 {
                guard represented.insert(Site(placeID: placeID, simulated: simulated)).inserted else { continue }
                let site = place(placeID)
                let coordinate = Self.coordinates(site?.latitude, site?.longitude)
                let value = Entry(id: UUID().uuidString, placeID: placeID,
                                  name: site?.name ?? "先前造訪的地點（編號 \(placeID)）",
                                  isSimulated: simulated, date: "", startedAt: nil, endedAt: nil,
                                  status: .legacy, latitude: coordinate.0, longitude: coordinate.1)
                if try write(value) { changed = true }
            }
        }
        try prepareFolder()
        try Data([1]).write(to: migrationMarker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func arrival(id: String, placeID: Int, name: String, simulated: Bool, date: String?,
                         latitude: Double?, longitude: Double?) -> Entry {
        let coordinate = Self.coordinates(latitude, longitude)
        return Entry(id: id, placeID: placeID, name: name, isSimulated: simulated,
                     date: knownDay(date) ?? "", startedAt: nil, endedAt: nil, status: .arrived,
                     latitude: coordinate.0, longitude: coordinate.1)
    }

    private func mergeArrival(_ record: Entry) throws -> Bool {
        let key = try Self.key(record.id)
        guard var value = cached[key] else { return try write(record) }
        guard value.isSimulated == record.isSimulated, value.status != .legacy else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // 只有原生回條可補認到站。既有到站時間、筆記、收藏與里程都保留。
        if value.status != .arrived {
            value.endedAt = nil
            value.status = .arrived
            if !record.date.isEmpty { value.date = record.date }
        } else if value.date.isEmpty { value.date = record.date }
        let changedSite = value.placeID != record.placeID
        if changedSite || value.latitude == nil {
            value.latitude = record.latitude
            value.longitude = record.longitude
        }
        value.placeID = record.placeID
        if changedSite || value.name.isEmpty { value.name = record.name }
        return try write(value)
    }

    private func knownDay(_ value: String?) -> String? {
        guard let value, value.utf8.count == 10, let parsed = day.date(from: value),
              day.string(from: parsed) == value else { return nil }
        return value
    }

    private static func coordinates(_ latitude: Double?, _ longitude: Double?) -> (Double?, Double?) {
        guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return (nil, nil) }
        return (latitude, longitude)
    }

    private static func key(_ id: String) throws -> UUID {
        guard let key = UUID(uuidString: id) else { throw CocoaError(.fileWriteInvalidFileName) }
        return key
    }

    private func load() throws {
        let names: [URL]
        if revision == Self.diskRevision {
            guard !readFailures.isEmpty else { return }
            names = readFailures.values.map { $0.file }
        } else {
            do {
                names = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                names = []
            }
            cached.removeAll()
            damagedFiles.removeAll()
            readFailures.removeAll()
        }
        let decoder = JSONDecoder()
        for file in names where file.pathExtension == "json" {
            guard let key = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                readFailures[key] = (file, error)
                continue
            }
            readFailures.removeValue(forKey: key)
            guard let value = try? decoder.decode(Entry.self, from: data), UUID(uuidString: value.id) == key else {
                damagedFiles[key] = file
                continue
            }
            cached[key] = value
        }
        revision = Self.diskRevision
    }

    private func prepareFolder() throws {
        guard !prepared else { return }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try url.setResourceValues(attributes)
        prepared = true
    }

    private func write(_ value: Entry) throws -> Bool {
        let key = try Self.key(value.id)
        if let failure = readFailures[key] { throw failure.error }
        guard cached[key] != value else { return false }
        try prepareFolder()
        let file = folder.appendingPathComponent(key.uuidString).appendingPathExtension("json")
        if let damaged = damagedFiles[key] {
            // 同一筆若能用到站回條重建，先保留損壞的原檔。
            try manager.moveItem(at: damaged, to: damaged.appendingPathExtension(UUID().uuidString + ".damaged"))
            damagedFiles.removeValue(forKey: key)
        }
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cached[key] = value
        Self.diskRevision &+= 1
        revision = Self.diskRevision
        return true
    }

    private func notify() { NotificationCenter.default.post(name: .walkJournalDidChange, object: self) }
}
