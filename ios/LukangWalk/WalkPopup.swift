import UIKit

/// 跟網頁地點卡一樣的彈窗：底下壓暗，中間浮一張米白圓角卡片，往上浮起出現。
/// 取代 iOS 內建從下往上滑的面板。
@MainActor
final class WalkPopupController: UIViewController, UINavigationControllerDelegate {
    let content: UIViewController
    private let frame = UIView()
    private let card = UIView()

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        (content as? UINavigationController)?.delegate = self
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WalkTheme.veil
        frame.layer.shadowColor = UIColor.black.cgColor
        frame.layer.shadowOpacity = 0.4
        frame.layer.shadowRadius = 25
        frame.layer.shadowOffset = CGSize(width: 0, height: 20)
        card.backgroundColor = WalkTheme.card
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        for item in [frame, card, content.view!] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(frame)
        frame.addSubview(card)
        addChild(content)
        card.addSubview(content.view)
        content.didMove(toParent: self)

        let safe = view.safeAreaLayoutGuide
        let fill = frame.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -32)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            frame.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            frame.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
            frame.widthAnchor.constraint(lessThanOrEqualToConstant: 480), fill,
            frame.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            frame.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: frame.topAnchor),
            card.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: card.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        WalkTheme.rise(frame, alongside: transitionCoordinator, animated: animated && isBeingPresented)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        WalkTheme.flatten(viewController.navigationItem)
    }

    override func accessibilityPerformEscape() -> Bool {
        content.accessibilityPerformEscape()
    }
}

/// 跟網頁一致的確認框，取代 iOS 內建的白色對話框。用法與 UIAlertController 相同。
@MainActor
final class WalkAlert: UIViewController {
    enum Style { case `default`, cancel, destructive }

    struct Action {
        let title: String
        let style: Style
        let handler: ((Action) -> Void)?

        init(title: String, style: Style, handler: ((Action) -> Void)? = nil) {
            self.title = title
            self.style = style
            self.handler = handler
        }
    }

    private let heading: String?
    private let message: String?
    private var actions: [Action] = []
    private let frame = UIView()

    init(title: String?, message: String?) {
        heading = title
        self.message = message
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { return nil }

    func addAction(_ action: Action) { actions.append(action) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WalkTheme.veil
        frame.layer.shadowColor = UIColor.black.cgColor
        frame.layer.shadowOpacity = 0.4
        frame.layer.shadowRadius = 25
        frame.layer.shadowOffset = CGSize(width: 0, height: 20)
        let card = UIView()
        card.backgroundColor = WalkTheme.card
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.accessibilityViewIsModal = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        if let heading {
            let label = UILabel()
            label.text = heading
            label.font = WalkTheme.kai(22, bold: true, style: .title3)
            label.textColor = WalkTheme.cardInk
            label.accessibilityTraits.insert(.header)
            stack.addArrangedSubview(label)
        }
        if let message {
            let label = UILabel()
            label.text = message
            label.font = WalkTheme.kai(17, style: .body)
            label.textColor = WalkTheme.cardSoft
            stack.addArrangedSubview(label)
        }
        for label in stack.arrangedSubviews.compactMap({ $0 as? UILabel }) {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        // 主要動作在上、取消在下，跟網頁地點卡的按鈕順序一樣。
        let ordered = actions.filter { $0.style != .cancel } + actions.filter { $0.style == .cancel }
        for action in ordered {
            let button = UIButton(type: .system)
            let kind: WalkTheme.ButtonKind
            switch action.style {
            case .default: kind = .main
            case .destructive: kind = .alarm
            case .cancel: kind = .outline
            }
            WalkTheme.dress(button, kind, title: action.title)
            button.accessibilityLabel = action.title
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.choose(action) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        for item in [frame, card, stack] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(frame)
        frame.addSubview(card)
        card.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        let width = frame.widthAnchor.constraint(equalToConstant: 340)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            frame.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            frame.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            frame.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 16), width,
            card.topAnchor.constraint(equalTo: frame.topAnchor),
            card.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        WalkTheme.rise(frame, alongside: transitionCoordinator, animated: animated && isBeingPresented)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let cancel = actions.first(where: { $0.style == .cancel }) else { return false }
        choose(cancel)
        return true
    }

    private func choose(_ action: Action) {
        // 與系統對話框相同：先關閉，再執行動作。
        dismiss(animated: true) { action.handler?(action) }
    }
}

extension UIViewController {
    /// 以網頁地點卡的樣式開啟畫面。
    func presentPopup(_ screen: UIViewController, completion: (() -> Void)? = nil) {
        present(WalkPopupController(content: screen), animated: true, completion: completion)
    }
}
