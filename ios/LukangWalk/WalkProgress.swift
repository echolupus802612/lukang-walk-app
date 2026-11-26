import Foundation

final class WalkProgress {
    struct Arrival: Codable {
        let placeID: Int
        let session: Int
        let token: String
        let date: String?
        let distanceIncomplete: Bool?
    }

    private struct Values: Codable {
        var ver = 2
        var voice = true
        var theme: String?
        var drawn = 0
        var seen: [Int] = []
        var recent: [Int] = []
        var sim_drawn = 0
        var sim_seen: [Int] = []
        var sim_recent: [Int] = []
        var pendingArrival: Arrival?
    }

    private let folder: URL
    private let file: URL
    private var values = Values()
    private var loaded = false

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("Walk", isDirectory: true)
        file = self.folder.appendingPathComponent("footprints.json")
        try? ensureLoaded()
    }

    // 只有找不到舊檔案時才從空足跡開始。受保護或讀不到的舊檔案必須留待重試。
    func ensureLoaded() throws {
        guard !loaded else { return }
        do {
            let saved = try JSONDecoder().decode(Values.self, from: Data(contentsOf: file))
            guard saved.ver == 2 else { throw CocoaError(.fileReadCorruptFile) }
            values = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            values = Values()
        }
        loaded = true
    }

    var initialScript: String {
        let data = try? JSONEncoder().encode(values)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ver\":2}"
        return "window.lukangInitialStore = " + json + "; window.lukangBackgroundWalk = true;"
    }

    var pendingArrival: Arrival? { values.pendingArrival }
    var visitedPlaces: (real: [Int], simulated: [Int]) { (values.seen, values.sim_seen) }

    var arrivalEvent: [String: Any]? {
        guard let arrival = pendingArrival else { return nil }
        var event: [String: Any] = ["type": "arrival", "session": arrival.session, "placeID": arrival.placeID,
                                    "token": arrival.token, "seen": values.seen, "recent": values.recent]
        if let date = arrival.date { event["date"] = date }
        if arrival.distanceIncomplete == true { event["distanceIncomplete"] = true }
        return event
    }

    func recordArrival(placeID: Int, session: Int, visitID: String, distanceIncomplete: Bool) throws {
        try ensureLoaded()
        if !values.seen.contains(placeID) { values.seen.append(placeID) }
        values.recent.removeAll { $0 == placeID }
        values.recent.insert(placeID, at: 0)
        values.recent = Array(values.recent.prefix(12))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy.MM.dd"
        values.pendingArrival = Arrival(placeID: placeID, session: session, token: visitID,
                                        date: formatter.string(from: Date()), distanceIncomplete: distanceIncomplete)
        try persist()
    }

    func acknowledgeArrival(_ token: String) throws {
        try ensureLoaded()
        guard pendingArrival?.token == token else { return }
        values.pendingArrival = nil
        try persist()
    }

    func save(_ changes: [String: Any]) throws {
        try ensureLoaded()
        var next = values
        for (key, value) in changes {
            switch (key, value) {
            case ("voice", let enabled as Bool): next.voice = enabled
            case ("theme", let theme as String) where ["", "light", "dark"].contains(theme): next.theme = theme
            case ("drawn", let count as Int) where count >= 0: next.drawn = count
            case ("sim_drawn", let count as Int) where count >= 0: next.sim_drawn = count
            case ("seen", let ids as [Int]): next.seen = ids
            case ("sim_seen", let ids as [Int]): next.sim_seen = ids
            case ("recent", let ids as [Int]): next.recent = Array(ids.prefix(12))
            case ("sim_recent", let ids as [Int]): next.sim_recent = Array(ids.prefix(12))
            default: return
            }
        }
        // Retain the latest state in memory so a later successful write can also save a failed one.
        values = next
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var localFolder = folder
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try localFolder.setResourceValues(attributes)
        try JSONEncoder().encode(values).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
