import Foundation

struct WalkPhotoVisit: Codable, Sendable {
    let id: String
    let placeID: Int
    let name: String
    let date: String
    let isSimulated: Bool
    var tripID: String? = nil
    var wasEnRoute: Bool? = nil
    var journalID: String { tripID ?? id }

    var shareText: String {
        // 舊相片沒有途中標記。先前版本會把未揭曉地點的照片命名為「散步途中」。
        let enRoute = wasEnRoute ?? (tripID != nil && name == "散步途中")
        if enRoute {
            return isSimulated ? "和小嚮導模擬散步中！#散步吧" : "和小嚮導散步中！#散步吧"
        }
        return isSimulated ? "模擬散步和小嚮導走到了\(name)！#散步吧" : "跟著小嚮導走到了\(name)！#散步吧"
    }
}
