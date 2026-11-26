import Foundation

final class WalkProgress {
    struct Arrival: Codable {
        let placeID: Int
        let session: Int
        let token: String
    }

    private struct Values: Codable {
        var ver = 2
        var voice = true
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

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Walk", isDirectory: true)
        file = folder.appendingPathComponent("footprints.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Values.self, from: data), saved.ver == 2 {
            values = saved
        }
    }

    var initialScript: String {
        let data = try? JSONEncoder().encode(values)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ver\":2}"
        return "window.lukangInitialStore = " + json + "; window.lukangBackgroundWalk = true;"
    }

    var pendingArrival: Arrival? { values.pendingArrival }

    var arrivalEvent: [String: Any]? {
        guard let arrival = pendingArrival else { return nil }
        return ["type": "arrival", "session": arrival.session, "placeID": arrival.placeID,
                "token": arrival.token, "seen": values.seen, "recent": values.recent]
    }

    func recordArrival(placeID: Int, session: Int) throws {
        if !values.seen.contains(placeID) { values.seen.append(placeID) }
        values.recent.removeAll { $0 == placeID }
        values.recent.insert(placeID, at: 0)
        values.recent = Array(values.recent.prefix(12))
        values.pendingArrival = Arrival(placeID: placeID, session: session, token: UUID().uuidString)
        try persist()
    }

    func acknowledgeArrival(_ token: String) throws {
        guard pendingArrival?.token == token else { return }
        values.pendingArrival = nil
        try persist()
    }

    func save(_ changes: [String: Any]) throws {
        var next = values
        for (key, value) in changes {
            switch (key, value) {
            case ("voice", let enabled as Bool): next.voice = enabled
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
