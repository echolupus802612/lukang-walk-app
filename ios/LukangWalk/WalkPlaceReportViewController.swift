import MessageUI
import UIKit

final class WalkPlaceReportViewController: UIViewController, UITextViewDelegate, MFMailComposeViewControllerDelegate {
    private static let reasons = ["無法進入", "位置有誤", "地點已不存在", "其他"]

    private let placeID: Int
    private let placeName: String
    private var draftKey: String { "Walk.placeReportDraft.\(placeID)" }
    private var selectedReason: String?
    private let note = UITextView()
    private let status = UILabel()
    private let compose = UIButton(type: .system)
    private let copyReport = UIButton(type: .system)
    private let discard = UIButton(type: .system)
    private var reasonButtons: [UIButton] = []
    private var openingMail = false

    init(placeID: Int, placeName: String) {
        self.placeID = placeID
        self.placeName = placeName
        super.init(nibName: nil, bundle: nil)
        title = "回報地點"
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        WalkTheme.paint(view)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "關閉", style: .plain,
                                                             target: self, action: #selector(closeForm))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkReportClose"

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        view.addSubview(scroll)
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])

        let place = label("\(placeName)（#\(placeID)）", font: WalkTheme.kai(26, bold: true, style: .title2))
        place.accessibilityIdentifier = "walkReportPlace"
        stack.addArrangedSubview(place)
        let recipient = label("收件人　\(WalkPlaceReportMessage.recipient)",
                              font: WalkTheme.sans(14, weight: .regular, style: .subheadline), color: WalkTheme.soft)
        recipient.accessibilityIdentifier = "walkReportRecipient"
        stack.addArrangedSubview(recipient)
        stack.setCustomSpacing(20, after: recipient)

        stack.addArrangedSubview(label("回報原因", font: WalkTheme.kai(18, bold: true, style: .headline)))
        for (index, reason) in Self.reasons.enumerated() {
            let button = UIButton(type: .system)
            WalkTheme.dress(button, .outline, title: reason)
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityIdentifier = "walkReportReason\(index)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.selectedReason = reason
                self.draftChanged()
            }, for: .touchUpInside)
            reasonButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.setCustomSpacing(18, after: reasonButtons[reasonButtons.count - 1])
        stack.addArrangedSubview(label("補充說明", font: WalkTheme.kai(18, bold: true, style: .headline)))
        note.font = WalkTheme.kai(18, style: .body)
        note.adjustsFontForContentSizeCategory = true
        note.backgroundColor = WalkTheme.card
        note.textColor = WalkTheme.cardInk
        note.tintColor = WalkTheme.accent
        note.layer.cornerRadius = 14
        note.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        note.heightAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        note.accessibilityLabel = "補充說明"
        note.accessibilityIdentifier = "walkReportNote"
        note.delegate = self
        let toolbar = UIToolbar()
        let done = UIBarButtonItem(title: "完成", style: .plain, target: self, action: #selector(finishEditing))
        done.accessibilityIdentifier = "walkReportEndEditing"
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
        toolbar.sizeToFit()
        note.inputAccessoryView = toolbar
        stack.addArrangedSubview(note)
        let hint = label("選擇「其他」時請填寫原因。寄送前可以在郵件裡確認內容。",
                         font: WalkTheme.sans(13, weight: .regular, style: .footnote), color: WalkTheme.soft)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(18, after: hint)

        configure(compose, title: "撰寫回報郵件", id: "walkReportPrepare", style: .main, action: #selector(prepareMail))
        configure(copyReport, title: "複製完整回報", id: "walkReportCopy", style: .outline, action: #selector(copyContent))
        let copyAddress = UIButton(type: .system)
        configure(copyAddress, title: "複製收件地址", id: "walkReportCopyAddress", style: .quiet, action: #selector(copyRecipient))
        configure(discard, title: "清除這份草稿", id: "walkReportDiscard", style: .danger, action: #selector(confirmDiscard))
        stack.setCustomSpacing(16, after: compose)
        status.font = WalkTheme.kai(17, style: .body)
        status.textColor = WalkTheme.ink
        status.textAlignment = .center
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.accessibilityIdentifier = "walkReportStatus"
        let actions: [UIView] = [compose, copyReport, copyAddress, status, discard]
        for item in actions { stack.addArrangedSubview(item) }

        let draft = UserDefaults.standard.dictionary(forKey: draftKey)
        if let reason = draft?["reason"] as? String, Self.reasons.contains(reason) { selectedReason = reason }
        note.text = draft?["note"] as? String ?? ""
        refresh()
    }

    private func label(_ text: String, font: UIFont, color: UIColor = WalkTheme.ink) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func configure(_ button: UIButton, title: String, id: String, style: WalkTheme.ButtonKind, action: Selector) {
        WalkTheme.dress(button, style, title: title)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: style == .main ? 56 : 46).isActive = true
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private var report: WalkPlaceReportMessage? {
        let details = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reason = selectedReason, reason != "其他" || !details.isEmpty else { return nil }
        return WalkPlaceReportMessage(placeID: placeID, placeName: placeName, reason: reason, details: details)
    }

    private func refresh() {
        for (index, reason) in Self.reasons.enumerated() {
            let button = reasonButtons[index]
            let selected = reason == selectedReason
            button.configuration?.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
            // 選到的原因跟網頁的已選按鈕一樣：米白底、紅磚字。
            button.configuration?.baseForegroundColor = selected ? WalkTheme.brickDeep : WalkTheme.ink
            button.configuration?.background.backgroundColor = selected ? WalkTheme.ink : WalkTheme.shade
            if selected { button.accessibilityTraits.insert(.selected) }
            else { button.accessibilityTraits.remove(.selected) }
        }
        compose.isEnabled = report != nil && !openingMail
        copyReport.isEnabled = report != nil
        discard.isHidden = selectedReason == nil && note.text.isEmpty
        status.isHidden = status.text?.isEmpty != false
    }

    func textViewDidChange(_ textView: UITextView) { draftChanged() }

    private func draftChanged() {
        if selectedReason == nil && note.text.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(["reason": selectedReason ?? "", "note": note.text ?? ""], forKey: draftKey)
        }
        status.text = nil
        refresh()
    }

    @objc private func finishEditing() { view.endEditing(true) }
    @objc private func closeForm() { dismiss(animated: true) }

    private func showStatus(_ text: String) {
        status.text = text
        status.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func clearDraft() {
        selectedReason = nil
        note.text = ""
        draftChanged()
    }

    @objc private func confirmDiscard() {
        finishEditing()
        let alert = UIAlertController(title: "清除這份草稿？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "保留", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            self?.clearDraft()
            self?.showStatus("已清除這份草稿。")
        })
        present(alert, animated: true)
    }

    @objc private func copyContent() {
        guard let report else { return }
        finishEditing()
        UIPasteboard.general.string = report.copyText
        showStatus("已複製完整回報。")
    }

    @objc private func copyRecipient() {
        finishEditing()
        UIPasteboard.general.string = WalkPlaceReportMessage.recipient
        showStatus("已複製收件地址。")
    }

    @objc private func prepareMail() {
        guard let report, !openingMail, presentedViewController == nil else { return }
        finishEditing()
        if MFMailComposeViewController.canSendMail() {
            let mail = MFMailComposeViewController()
            mail.mailComposeDelegate = self
            mail.setToRecipients([WalkPlaceReportMessage.recipient])
            mail.setSubject(report.subject)
            mail.setMessageBody(report.body, isHTML: false)
            present(mail, animated: true)
            return
        }

        guard let url = report.mailtoURL else {
            showStatus("無法開啟這封郵件。請複製回報和收件地址。")
            return
        }
        openingMail = true
        refresh()
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            self.openingMail = false
            self.refresh()
            self.showStatus(opened ? "已開啟郵件 App。請在郵件中確認並寄出。" : "找不到可開啟的郵件 App。請複製回報和收件地址。")
        }
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard error == nil else {
                self.showStatus("郵件未能交寄，這份草稿已保留。")
                return
            }
            switch result {
            case .sent:
                self.clearDraft()
                self.showStatus("已交由郵件 App 寄送。")
            case .saved: self.showStatus("已存入郵件草稿。")
            case .cancelled: self.showStatus("已取消寄送，這份草稿已保留。")
            case .failed: self.showStatus("郵件未能交寄，這份草稿已保留。")
            @unknown default: self.showStatus("請到郵件 App 確認寄送狀態。")
            }
        }
    }
}
