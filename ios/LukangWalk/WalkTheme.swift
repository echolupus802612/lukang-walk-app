import CoreText
import UIKit

/// 原生畫面沿用網頁主畫面的配色與字型：紅磚為底、米白文字、金色點題，霞鶩文楷寫標題與按鈕。
/// 色值與 src/app.html 的 :root 變數一致，深色模式也照網頁的深色版。
@MainActor
enum WalkTheme {
    // 底色（網頁 --bg / --bg2）
    static let brick = dynamic(0x9a3a27, 0x3b1610)
    static let brickDeep = dynamic(0x82301f, 0x2a0f0a)
    // 紅磚上的文字（網頁 --ink / --soft / --line）
    static let ink = UIColor(rgb: 0xfbf3e6)
    static let soft = dynamic(0xf3dccb, 0xd9bfae)
    static let line = UIColor(rgb: 0xfbf3e6, alpha: 0.22)
    static let shade = UIColor(white: 0, alpha: 0.16)
    // 金色主按鈕（網頁 --gold / --gold2）
    static let gold = UIColor(rgb: 0xf2c14e)
    static let gold2 = UIColor(rgb: 0xc9922a)
    static let goldInk = UIColor(rgb: 0x3a1a12)
    // 地點卡（網頁 --card / --cardink）
    static let card = dynamic(0xfbf3e6, 0x241310)
    static let cardPressed = dynamic(0xf0e0cb, 0x33201a)
    static let cardInk = dynamic(0x3a1a12, 0xf6e9da)
    static let cardSoft = dynamic(0x7a5a4c, 0xc4a796)
    /// 地點卡裡的強調色：淺色用紅磚，深色用金色才看得清楚。
    static let accent = dynamic(0x9a3a27, 0xf2c14e)
    static let danger = dynamic(0xb3261e, 0xff9d8a)
    /// 紅磚底上的警示字。
    static let dangerOnBrick = UIColor(rgb: 0xffc2b4)

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

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = brick
        bar.shadowColor = .clear
        bar.titleTextAttributes = [.foregroundColor: ink, .font: kai(19, bold: true, style: .headline)]
        bar.largeTitleTextAttributes = [.foregroundColor: ink, .font: kai(32, bold: true, style: .largeTitle)]
        let plain = UIBarButtonItemAppearance()
        plain.normal.titleTextAttributes = [.foregroundColor: ink, .font: kai(17, style: .body)]
        bar.buttonAppearance = plain
        let done = UIBarButtonItemAppearance()
        done.normal.titleTextAttributes = [.foregroundColor: gold, .font: kai(17, bold: true, style: .body)]
        bar.doneButtonAppearance = done
        bar.backButtonAppearance = plain
        let navigation = UINavigationBar.appearance()
        navigation.standardAppearance = bar
        navigation.scrollEdgeAppearance = bar
        navigation.compactAppearance = bar
        navigation.compactScrollEdgeAppearance = bar
        navigation.tintColor = ink

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = brickDeep
        toolbar.buttonAppearance = plain
        toolbar.doneButtonAppearance = done
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().compactAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
        UIToolbar.appearance().tintColor = ink

        UISwitch.appearance().onTintColor = gold2

        let segments = UISegmentedControl.appearance()
        segments.backgroundColor = shade
        segments.selectedSegmentTintColor = ink
        segments.setTitleTextAttributes([.foregroundColor: ink, .font: kai(16, style: .subheadline)], for: .normal)
        segments.setTitleTextAttributes([.foregroundColor: goldInk, .font: kai(16, bold: true, style: .subheadline)],
                                        for: .selected)

        let search = UISearchTextField.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
        search.backgroundColor = shade
        search.textColor = ink
        search.tintColor = gold
        UISearchBar.appearance().tintColor = ink
    }

    // MARK: 畫面與列表

    /// 一般畫面：紅磚底。
    static func paint(_ view: UIView) {
        view.backgroundColor = brick
        view.tintColor = gold
    }

    /// 列表畫面：紅磚底，每一格是米白卡片。
    static func paint(_ table: UITableView) {
        table.backgroundColor = brick
        table.separatorColor = UIColor(rgb: 0x3a1a12, alpha: 0.12)
        table.tintColor = accent
    }

    /// 卡片格：米白底、深棕字、文楷標題。
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
            background.backgroundColor = state.isHighlighted || state.isSelected ? cardPressed : card
            cell.backgroundConfiguration = background
        }
    }

    /// 列表的段落標題與說明字：米白小字，放在紅磚底上看得清楚。
    static func style(header view: UIView, footer: Bool = false) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        if var content = header.contentConfiguration as? UIListContentConfiguration {
            content.textProperties.color = soft
            content.textProperties.font = footer ? sans(13, weight: .regular, style: .footnote)
                                                 : kai(15, bold: true, style: .subheadline)
            content.textProperties.adjustsFontForContentSizeCategory = true
            header.contentConfiguration = content
        } else {
            header.textLabel?.textColor = soft
        }
    }

    /// 空白或讀取失敗時，置中在紅磚底上的說明。
    static func message(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = soft
        label.font = kai(18, style: .body)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    // MARK: 按鈕

    enum ButtonKind { case main, outline, quiet, danger }

    /// 對應網頁的按鈕：主按鈕金底深字、帶下緣陰影；次要按鈕米白框線；其餘為文字按鈕。
    static func buttonStyle(_ kind: ButtonKind, title: String? = nil, image: String? = nil) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch kind {
        case .main:
            config = .filled()
            config.baseBackgroundColor = gold
            config.baseForegroundColor = goldInk
        case .outline:
            config = .plain()
            config.baseForegroundColor = ink
            config.background.backgroundColor = shade
            config.background.strokeColor = line
            config.background.strokeWidth = 1
        case .quiet:
            config = .plain()
            config.baseForegroundColor = soft
        case .danger:
            config = .plain()
            config.baseForegroundColor = dangerOnBrick
        }
        config.title = title
        if let image { config.image = UIImage(systemName: image) }
        config.imagePadding = 10
        config.cornerStyle = .fixed
        config.background.cornerRadius = 14
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let font = kind == .main ? kai(20, bold: true, style: .headline) : kai(17, style: .body)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        return config
    }

    /// 套用按鈕樣式；主按鈕加上網頁那條金色下緣。
    static func dress(_ button: UIButton, _ kind: ButtonKind, title: String? = nil, image: String? = nil) {
        button.configuration = buttonStyle(kind, title: title, image: image)
        button.layer.shadowColor = kind == .main ? gold2.cgColor : nil
        button.layer.shadowOpacity = kind == .main ? 1 : 0
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 5)
        button.configurationUpdateHandler = { button in
            guard kind == .main else { return }
            button.layer.shadowOpacity = button.isEnabled ? 1 : 0
            button.alpha = button.isEnabled ? 1 : 0.55
            button.transform = button.isHighlighted ? CGAffineTransform(translationX: 0, y: 3) : .identity
        }
    }

    // MARK: -

    private static func dynamic(_ light: Int, _ dark: Int) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) }
    }
}

private extension UIColor {
    convenience init(rgb: Int, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}
