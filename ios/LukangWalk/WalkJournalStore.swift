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
    private let manager = FileManager.default
    private let day: DateFormatter
    private var prepared = false
    private var cached: [UUID: Entry] = [:]
    private var revision: UInt?
    // 兩個畫面或兩個 store 共用同一份日誌時，舊的記憶體清單須重新讀取。
    private static var diskRevision: UInt = 0

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("Walk/Journal", isDirectory: true)
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
        let preserved = id.flatMap(UUID.init(uuidString:))
        let active = cached.filter { $0.key != preserved && $0.value.status == .walking }
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

    func migrate(photoVisits: [WalkPhotoAlbum.Visit], seen: [Int], simSeen: [Int],
                 place: (Int) -> Place?) throws {
        guard needsMigration else { return }
        try load()
        var changed = false
        defer { if changed { notify() } }
        for visit in photoVisits where visit.tripID == nil {
            // 新版途中也能留照；已有逐趟紀錄時，以該趟的實際狀態為準。
            let key = try Self.key(visit.id)
            guard cached[key] == nil else { continue }
            let site = place(visit.placeID)
            let record = arrival(id: visit.id, placeID: visit.placeID, name: visit.name,
                                 simulated: visit.isSimulated, date: visit.date,
                                 latitude: site?.latitude, longitude: site?.longitude)
            if try write(record) { changed = true }
        }
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
        guard revision != Self.diskRevision else { return }
        let names: [URL]
        do {
            names = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            cached = [:]
            revision = Self.diskRevision
            return
        }
        var loaded: [UUID: Entry] = [:]
        let decoder = JSONDecoder()
        for file in names where file.pathExtension == "json" {
            let value = try decoder.decode(Entry.self, from: Data(contentsOf: file))
            let key = try Self.key(value.id)
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) == key, loaded[key] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            loaded[key] = value
        }
        cached = loaded
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
        guard cached[key] != value else { return false }
        try prepareFolder()
        let file = folder.appendingPathComponent(key.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cached[key] = value
        Self.diskRevision &+= 1
        revision = Self.diskRevision
        return true
    }

    private func notify() { NotificationCenter.default.post(name: .walkJournalDidChange, object: self) }
}
