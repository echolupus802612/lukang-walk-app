import Foundation

@main
struct WalkPlaceReportTests {
    static func main() throws {
        let recipient = "echolupus802612@gmail.com"
        let message = WalkPlaceReportMessage(placeID: 1012, placeName: "測試地點", reason: "其他",
                                             details: "  入口 A+B & 橋 #2 已封閉 50%。\n請改走？=西側\r\n再往前。  ")
        let body = "地點名稱：測試地點\n地點編號：1012\n回報原因：其他\n補充說明：入口 A+B & 橋 #2 已封閉 50%。\n請改走？=西側\r\n再往前。"
        precondition(message.body == body && WalkPlaceReportMessage.recipient == recipient)
        precondition(message.copyText == "收件人：\(recipient)\n主旨：\(message.subject)\n\n\(body)")
        guard let url = message.mailtoURL, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems else { preconditionFailure("無法建立回報郵件") }
        precondition(parts.scheme == "mailto" && parts.path == recipient && parts.fragment == nil)
        precondition(items.map(\.name) == ["subject", "body"])
        precondition(items[0].value == message.subject && message.subject.contains("1012"))
        precondition(items[1].value == body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n"))
        precondition(url.absoluteString.contains("A%2BB") && url.absoluteString.contains("%26"))
        let noNote = WalkPlaceReportMessage(placeID: 1001, placeName: "測試地點", reason: "無法進入", details: " \n ")
        precondition(noNote.body.components(separatedBy: "\n").count == 3)
        print("Place report recipient, body, copy and mailto encoding passed")
    }
}
