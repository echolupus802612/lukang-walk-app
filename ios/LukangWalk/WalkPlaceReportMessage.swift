import Foundation

struct WalkPlaceReportMessage {
    static let recipient = "echolupus802612@gmail.com"
    let placeID: Int
    let placeName: String
    let reason: String
    let details: String

    var subject: String { "《散步吧》地點問題回報 #\(placeID)" }

    var body: String {
        var lines = ["地點名稱：\(placeName)", "地點編號：\(placeID)", "回報原因：\(reason)"]
        let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines.append("補充說明：\(note)") }
        return lines.joined(separator: "\n")
    }

    var copyText: String { "收件人：\(Self.recipient)\n主旨：\(subject)\n\n\(body)" }

    var mailtoURL: URL? {
        // 郵件網址的主旨與內文各自編碼，保留玩家輸入的換行、加號與連接號。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let mailBody = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedBody = mailBody.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "mailto:\(Self.recipient)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}
