import UIKit

/// 主畫面的舞台：小嚮導站在平躺於地面的金色箭頭上，箭頭以腳底為中心轉向目標，「北」沿著地面環走。
/// 幾何與動作規則照 src/app.html 的 .pet、#wedge、#north 與 ANIM。座標以 400×330 的畫布為準。
@MainActor
final class WalkStageView: UIView {
    enum Pose: String { case idle, walk, point, pointup, pull, care, cheer }

    private struct Animation { let frames: Int; let ms: Double; let sequence: [Int] }
    private static let animations: [Pose: Animation] = [
        .idle: .init(frames: 4, ms: 260, sequence: [0, 0, 0, 1, 1, 0, 0, 2, 0, 0, 3, 3]),
        .walk: .init(frames: 4, ms: 150, sequence: [0, 1, 2, 3]),
        .point: .init(frames: 2, ms: 420, sequence: [0, 1]),
        .pointup: .init(frames: 2, ms: 420, sequence: [0, 1]),
        .pull: .init(frames: 4, ms: 220, sequence: [0, 1, 2, 3]),
        .care: .init(frames: 4, ms: 380, sequence: [0, 1, 2, 3]),
        .cheer: .init(frames: 4, ms: 170, sequence: [0, 1, 2, 3])
    ]
    private static var sheets: [Pose: [UIImage]] = [:]

    /// 箭頭要指的角度（度，畫面上方為 0，順時針為正）。
    var angle: Double = 0
    /// 手機朝向（度）；nil 表示沒有可靠朝向，「北」固定在上方。
    var heading: Double?
    var showsArrow = true { didSet { wedge.isHidden = !showsArrow; outline.isHidden = !showsArrow } }

    private let ground = CALayer()
    private let wedge = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let shadow = CAShapeLayer()
    private let north = UILabel()
    private let kid = UIImageView()
    private var shown: Double = 0
    private var pose: Pose = .idle
    private var poseStart = CACurrentMediaTime()
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "小嚮導指著回程方向"
        accessibilityTraits = .image
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 0, y: -38))
        arrow.addLine(to: CGPoint(x: 28, y: 32))
        arrow.addLine(to: CGPoint(x: 0, y: 17))
        arrow.addLine(to: CGPoint(x: -28, y: 32))
        arrow.close()
        arrow.apply(CGAffineTransform(scaleX: 3.4, y: 3.4).translatedBy(x: 0, y: 3))
        outline.path = arrow.cgPath
        outline.fillColor = nil
        outline.strokeColor = UIColor(red: 42 / 255, green: 13 / 255, blue: 7 / 255, alpha: 0.5).cgColor
        outline.lineWidth = 7 * 3.4
        outline.lineJoin = .round
        wedge.path = arrow.cgPath
        wedge.fillColor = WalkTheme.gold.cgColor
        wedge.strokeColor = WalkTheme.gold.cgColor
        wedge.lineWidth = 3 * 3.4
        wedge.lineJoin = .round
        shadow.fillColor = UIColor(red: 42 / 255, green: 13 / 255, blue: 7 / 255, alpha: 0.4).cgColor
        layer.addSublayer(ground)
        ground.addSublayer(outline)
        ground.addSublayer(wedge)
        layer.addSublayer(shadow)
        north.text = "北"
        north.textColor = WalkTheme.ink.withAlphaComponent(0.7)
        north.textAlignment = .center
        addSubview(north)
        kid.contentMode = .scaleToFill
        addSubview(kid)
        setPose(.idle, flip: false)
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: CGSize { CGSize(width: 380, height: 380 * 330 / 400) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func setPose(_ next: Pose, flip: Bool) {
        if next != pose || kid.image == nil {
            pose = next
            poseStart = CACurrentMediaTime()
        }
        kid.transform = flip ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        drawFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let unit = bounds.width / 400
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.position = CGPoint(x: 200 * unit, y: 268 * unit)
        shadow.path = UIBezierPath(ovalIn: CGRect(x: (200 - 74) * unit, y: (268 - 15) * unit,
                                                  width: 148 * unit, height: 30 * unit)).cgPath
        CATransaction.commit()
        north.font = WalkTheme.kai(24 * unit)
        let kidTransform = kid.transform
        kid.transform = .identity
        kid.frame = CGRect(x: bounds.width * 0.1125, y: bounds.height * -0.088,
                           width: bounds.width * 0.775, height: bounds.height * 0.9394)
        kid.transform = kidTransform
        place()
    }

    @objc private func step() {
        // 跟網頁一樣每個影格往目標角度靠近 12%，先收回 ±180 才不會繞遠路。
        shown = Self.norm180(shown + Self.norm180(angle - shown) * 0.12)
        if UIAccessibility.isReduceMotionEnabled { shown = angle }
        place()
        drawFrame()
    }

    private func place() {
        let unit = bounds.width / 400
        guard unit > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rotate = CATransform3DMakeRotation(CGFloat(shown * .pi / 180), 0, 0, 1)
        let flatten = CATransform3DMakeScale(unit, unit * 0.42, 1)
        ground.transform = CATransform3DConcat(rotate, flatten)
        CATransaction.commit()
        let turn = -(heading ?? 0) * .pi / 180
        north.sizeToFit()
        north.center = CGPoint(x: (200 + 172 * sin(turn)) * unit, y: (268 - 172 * 0.42 * cos(turn)) * unit)
    }

    private func drawFrame() {
        guard let animation = Self.animations[pose] else { return }
        let frames = Self.frames(for: pose, count: animation.frames)
        guard !frames.isEmpty else { return }
        let still = UIAccessibility.isReduceMotionEnabled
        let tick = Int((CACurrentMediaTime() - poseStart) * 1000 / animation.ms)
        let index = still ? 0 : animation.sequence[tick % animation.sequence.count]
        let image = frames[min(index, frames.count - 1)]
        if kid.image !== image { kid.image = image }
    }

    private static func frames(for pose: Pose, count: Int) -> [UIImage] {
        if let cached = sheets[pose] { return cached }
        guard let url = Bundle.main.url(forResource: pose.rawValue, withExtension: "webp", subdirectory: "Web/sprites"),
              let sheet = UIImage(contentsOfFile: url.path)?.cgImage else { return [] }
        let width = sheet.width / count
        let frames = (0..<count).compactMap { index in
            sheet.cropping(to: CGRect(x: index * width, y: 0, width: width, height: sheet.height)).map { UIImage(cgImage: $0) }
        }
        sheets[pose] = frames
        return frames
    }

    static func norm180(_ value: Double) -> Double {
        var result = (value + 180).truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result - 180
    }
}
