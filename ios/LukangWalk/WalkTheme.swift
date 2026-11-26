import CoreText
import UIKit

/// 原生畫面沿用網頁的配色與字型。色值與 src/app.html 的 :root 變數一致，深色模式也照網頁的深色版。
/// 彈窗跟網頁地點卡一樣是米白卡片（見 WalkPopup.swift）；回程導航像主畫面，是整頁紅磚。
@MainActor
enum WalkTheme {
    // 主畫面（網頁 --bg / --bg2 / --ink / --soft / --line）
    static let brick = dynamic(0x9a3a27, 0x3b1610)
    static let brickDeep = dynamic(0x82301f, 0x2a0f0a)
    static let ink = UIColor(rgb: 0xfbf3e6)
    static let soft = dynamic(0xf3dccb, 0xd9bfae)
    static let line = UIColor(rgb: 0xfbf3e6, alpha: 0.22)
    static let shade = UIColor(white: 0, alpha: 0.16)
    static let gold = UIColor(rgb: 0xf2c14e)
    static let gold2 = UIColor(rgb: 0xc9922a)
    static let goldInk = UIColor(rgb: 0x3a1a12)
    // 地點卡（網頁 --card / --cardink 與 .veil）
    static let veil = UIColor(red: 20 / 255, green: 6 / 255, blue: 3 / 255, alpha: 0.55)
    static let card = dynamic(0xfbf3e6, 0x241310)
    static let cardInk = dynamic(0x3a1a12, 0xf6e9da)
    static let cardSoft = dynamic(0x7a5a4c, 0xc4a796)
    /// 卡片裡的列表格與輸入框，比卡片略深一階。
    static let well = dynamic(0xf2e3cf, 0x301b15)
    static let wellPressed = dynamic(0xe7d2b7, 0x3d241c)
    static let rule = dynamic(0x3a1a12, 0xf6e9da, alpha: 0.12)
    /// 卡片裡的強調色：淺色用紅磚，深色用金色才看得清楚。
    static let accent = dynamic(0x9a3a27, 0xf2c14e)
    static let accentInk = dynamic(0xfbf3e6, 0x3a1a12)
    static let danger = dynamic(0xb3261e, 0xff9d8a)

    // MARK: 字型

    private static let kaiRegular = "LXGWWenKaiTC-Regular"
    private static let kaiBold = "LXGWWenKaiTC-Bold"

    /// 註冊隨網頁一起打包的文楷子集；讀不到時各處自動退回系統字型。
    static func registerFonts() {
        for name in ["walk-kai", "walk-kai-bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "Web/fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 霞鶩文楷，跟著「文字大小」設定縮放。
    static func kai(_ size: CGFloat, bold: Bool = false, style: UIFont.TextStyle = .body) -> UIFont {
        let base = UIFont(name: bold ? kaiBold : kaiRegular, size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// 數字、日期與小字用系統黑體，對應網頁的思源黑體。
    static func sans(_ size: CGFloat, weight: UIFont.Weight = .medium, style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    // MARK: 全域外觀

    static func apply(to window: UIWindow) {
        registerFonts()
        window.tintColor = accent

        let navigation = UINavigationBar.appearance()
        let bar = barAppearance(background: card, text: cardInk, button: accent)
        navigation.standardAppearance = bar
        navigation.scrollEdgeAppearance = bar
        navigation.compactAppearance = bar
        navigation.compactScrollEdgeAppearance = bar
        navigation.tintColor = accent

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = well
        toolbar.shadowColor = rule
        toolbar.buttonAppearance = buttonAppearance(accent, bold: false)
        toolbar.doneButtonAppearance = buttonAppearance(accent, bold: true)
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().compactAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
        UIToolbar.appearance().tintColor = accent

        UISwitch.appearance().onTintColor = accent

        let segments = UISegmentedControl.appearance()
        segments.backgroundColor = well
        segments.selectedSegmentTintColor = accent
        segments.setTitleTextAttributes([.foregroundColor: cardInk, .font: kai(16, style: .subheadline)], for: .normal)
        segments.setTitleTextAttributes([.foregroundColor: accentInk, .font: kai(16, bold: true, style: .subheadline)],
                                        for: .selected)

        let search = UISearchTextField.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
        search.backgroundColor = well
        search.textColor = cardInk
        search.tintColor = accent
        UISearchBar.appearance().tintColor = accent
    }

    private static func barAppearance(background: UIColor, text: UIColor, button: UIColor) -> UINavigationBarAppearance {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = background
        bar.shadowColor = .clear
        bar.titleTextAttributes = [.foregroundColor: text, .font: kai(19, bold: true, style: .headline)]
        bar.largeTitleTextAttributes = [.foregroundColor: text, .font: kai(32, bold: true, style: .largeTitle)]
        bar.buttonAppearance = buttonAppearance(button, bold: false)
        bar.doneButtonAppearance = buttonAppearance(button, bold: true)
        bar.backButtonAppearance = buttonAppearance(button, bold: false)
        return bar
    }

    private static func buttonAppearance(_ color: UIColor, bold: Bool) -> UIBarButtonItemAppearance {
        let appearance = UIBarButtonItemAppearance()
        appearance.normal.titleTextAttributes = [.foregroundColor: color, .font: kai(17, bold: bold, style: .body)]
        return appearance
    }

    /// iOS 26 會把列按鈕包成玻璃膠囊，看起來就是系統面板；拿掉膠囊，只留文字與圖示。
    static func flatten(_ item: UINavigationItem) {
        guard #available(iOS 26, *) else { return }
        let items = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) + [item.backBarButtonItem].compactMap { $0 }
        for button in items { button.hidesSharedBackground = true }
    }

    /// 回程導航像主畫面：整頁紅磚、米白字。
    static func stage(_ controller: UIViewController) {
        controller.view.backgroundColor = brick
        controller.view.tintColor = gold
        let bar = barAppearance(background: brick, text: ink, button: ink)
        controller.navigationItem.standardAppearance = bar
        controller.navigationItem.scrollEdgeAppearance = bar
        controller.navigationItem.compactAppearance = bar
        controller.navigationItem.compactScrollEdgeAppearance = bar
    }

    /// 彈窗出現時往上浮起，跟網頁地點卡的 rise 動畫一樣。
    static func rise(_ view: UIView, alongside coordinator: UIViewControllerTransitionCoordinator?, animated: Bool) {
        guard animated, !UIAccessibility.isReduceMotionEnabled, let coordinator else { return }
        view.transform = CGAffineTransform(translationX: 0, y: 30).scaledBy(x: 0.96, y: 0.96)
        coordinator.animate(alongsideTransition: { _ in view.transform = .identity },
                            completion: { _ in view.transform = .identity })
    }

    // MARK: 卡片內容

    /// 卡片裡的一般畫面。
    static func paint(_ view: UIView) {
        view.backgroundColor = card
        view.tintColor = accent
    }

    /// 卡片裡的列表：每一格是略深一階的米色圓角格。
    static func paint(_ table: UITableView) {
        table.backgroundColor = card
        table.separatorColor = rule
        table.tintColor = accent
    }

    static func style(_ cell: UITableViewCell, _ content: inout UIListContentConfiguration) {
        content.textProperties.font = kai(18, style: .body)
        content.textProperties.color = content.textProperties.color == .systemRed ? danger : cardInk
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = sans(14, weight: .regular, style: .subheadline)
        content.secondaryTextProperties.color = cardSoft
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.imageProperties.tintColor = accent
        cell.tintColor = accent
        cell.configurationUpdateHandler = { cell, state in
            var background = cell.defaultBackgroundConfiguration().updated(for: state)
            background.backgroundColor = state.isHighlighted || state.isSelected ? wellPressed : well
            cell.backgroundConfiguration = background
        }
    }

    /// 列表的段落標題與說明字。
    static func style(header view: UIView, footer: Bool = false) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        if var content = header.contentConfiguration as? UIListContentConfiguration {
            content.textProperties.color = cardSoft
            content.textProperties.font = footer ? sans(13, weight: .regular, style: .footnote)
                                                 : kai(15, bold: true, style: .subheadline)
            content.textProperties.adjustsFontForContentSizeCategory = true
            header.contentConfiguration = content
        } else {
            header.textLabel?.textColor = cardSoft
        }
    }

    /// 空白或讀取失敗時的置中說明。
    static func message(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = cardSoft
        label.font = kai(18, style: .body)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    // MARK: 按鈕

    /// main／outline／quiet／danger／alarm 用在米白卡片上，對應網頁地點卡的紅磚按鈕與框線按鈕；
    /// stageMain／stageOutline 用在紅磚的回程畫面，對應主畫面的金色主按鈕與半透明按鈕。
    enum ButtonKind { case main, outline, quiet, danger, alarm, stageMain, stageOutline }

    static func buttonStyle(_ kind: ButtonKind, title: String? = nil, image: String? = nil) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch kind {
        case .main, .alarm, .stageMain:
            config = .filled()
            config.baseBackgroundColor = kind == .main ? accent : kind == .alarm ? danger : gold
            config.baseForegroundColor = kind == .stageMain ? goldInk : accentInk
        case .outline:
            config = .plain()
            config.baseForegroundColor = accent
            config.background.strokeColor = accent
            config.background.strokeWidth = 2
        case .quiet:
            config = .plain()
            config.baseForegroundColor = cardSoft
        case .danger:
            config = .plain()
            config.baseForegroundColor = danger
        case .stageOutline:
            config = .plain()
            config.baseForegroundColor = ink
            config.background.backgroundColor = shade
            config.background.strokeColor = line
            config.background.strokeWidth = 1
        }
        config.title = title
        if let image { config.image = UIImage(systemName: image) }
        config.imagePadding = 10
        config.cornerStyle = .fixed
        config.background.cornerRadius = 14
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let font = kind == .stageMain ? kai(20, bold: true, style: .headline)
            : (kind == .main || kind == .alarm) ? kai(18, bold: true, style: .headline) : kai(17, style: .body)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        return config
    }

    /// 套用按鈕樣式；回程畫面的金色主按鈕加上網頁那條金色下緣。
    static func dress(_ button: UIButton, _ kind: ButtonKind, title: String? = nil, image: String? = nil) {
        button.configuration = buttonStyle(kind, title: title, image: image)
        let ledge = kind == .stageMain
        button.layer.shadowColor = ledge ? gold2.cgColor : nil
        button.layer.shadowOpacity = ledge ? 1 : 0
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 5)
        button.configurationUpdateHandler = { button in
            let filled = kind == .main || kind == .alarm || kind == .stageMain
            button.alpha = button.isEnabled || !filled ? 1 : 0.45
            guard ledge else { return }
            button.layer.shadowOpacity = button.isEnabled ? 1 : 0
            button.transform = button.isHighlighted ? CGAffineTransform(translationX: 0, y: 3) : .identity
        }
    }

    // MARK: -

    private static func dynamic(_ light: Int, _ dark: Int, alpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark, alpha: alpha) : UIColor(rgb: light, alpha: alpha) }
    }
}

private extension UIColor {
    convenience init(rgb: Int, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}
