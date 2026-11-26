import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class WalkPhotoAlbum {
    struct Visit: Codable, Sendable {
        let id: String
        let placeID: Int
        let name: String
        let date: String
        let isSimulated: Bool
        var tripID: String? = nil
        var journalID: String { tripID ?? id }
    }

    private static let files = WalkPhotoFiles()

    func save(visit: Visit, photo: Data, card: Data) async throws {
        try await Self.files.save(visit: visit, photo: photo, card: card)
    }

    func savedVisits() async throws -> [Visit] {
        try await Self.files.records().map(\.visit)
    }

    @MainActor
    func present(from presenter: UIViewController, showing id: String? = nil) {
        let list = WalkPhotoList(files: Self.files)
        let navigation = UINavigationController(rootViewController: list)
        if let id {
            let detail = WalkPhotoDetail(files: Self.files, visitID: id)
            navigation.setViewControllers([list, detail], animated: false)
        }
        presenter.present(navigation, animated: true)
    }
}

private struct WalkPhotoRecord: Codable, Sendable {
    let visit: WalkPhotoAlbum.Visit
    let generation: UUID
}

private enum WalkPhotoAsset: String, Sendable {
    case photo = "photo.jpg"
    case card = "card.png"
}

// 所有檔案讀寫都在同一個 actor 進行。足跡清單只指向已經寫好兩張圖片的目錄。
private actor WalkPhotoFiles {
    private let fm = FileManager.default
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Walk/PhotoAlbum", isDirectory: true)
    private var index: URL { root.appendingPathComponent("visits.json") }
    private var cleaned = false

    func records() throws -> [WalkPhotoRecord] {
        let records: [WalkPhotoRecord]
        do {
            records = try JSONDecoder().decode([WalkPhotoRecord].self, from: Data(contentsOf: index))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            records = []
        }
        if !cleaned, let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            // 上次若在寫圖片或換清單時被中止，清除不再使用的那一版。
            let live = Set(records.map(\.generation))
            for child in children {
                if let generation = UUID(uuidString: child.lastPathComponent), !live.contains(generation) {
                    try? fm.removeItem(at: child)
                }
            }
            cleaned = true
        }
        return records
    }

    private func directory(for record: WalkPhotoRecord) -> URL {
        root.appendingPathComponent(record.generation.uuidString, isDirectory: true)
    }

    func save(visit: WalkPhotoAlbum.Visit, photo: Data, card: Data) throws {
        guard !visit.id.isEmpty, Self.matches(photo, .jpeg), Self.matches(card, .png) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var localFolder = root
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try localFolder.setResourceValues(attributes)

        var saved = try records()
        let new = WalkPhotoRecord(visit: visit, generation: UUID())
        let staging = directory(for: new)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var replaced: WalkPhotoRecord?
        do {
            try photo.write(to: staging.appendingPathComponent(WalkPhotoAsset.photo.rawValue))
            try card.write(to: staging.appendingPathComponent(WalkPhotoAsset.card.rawValue))
            if let position = saved.firstIndex(where: { $0.visit.id == visit.id }) {
                replaced = saved[position]
                saved[position] = new
            } else {
                saved.insert(new, at: 0)
            }
            try JSONEncoder().encode(saved).write(to: index, options: .atomic)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if let replaced { try? fm.removeItem(at: directory(for: replaced)) }
    }

    private static func matches(_ data: Data, _ type: UTType) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(image), CGImageSourceGetCount(image) > 0 else { return false }
        return (identifier as String) == type.identifier && CGImageSourceGetStatus(image) == .statusComplete
    }

    func preview(_ asset: WalkPhotoAsset, record: WalkPhotoRecord, pixels: Int) throws -> CGImage {
        let file = directory(for: record).appendingPathComponent(asset.rawValue)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    func sharableCard(_ record: WalkPhotoRecord) throws -> URL {
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let copy = folder.appendingPathComponent("散步吧透卡.png")
        do {
            try fm.copyItem(at: directory(for: record).appendingPathComponent(WalkPhotoAsset.card.rawValue), to: copy)
            return copy
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    func discardShare(_ copy: URL) {
        try? fm.removeItem(at: copy.deletingLastPathComponent())
    }
}

@MainActor
private final class WalkPhotoList: UITableViewController {
    private let files: WalkPhotoFiles
    private var records: [WalkPhotoRecord] = []
    private let thumbnails = NSCache<NSString, UIImage>()

    init(files: WalkPhotoFiles) {
        self.files = files
        super.init(style: .insetGrouped)
        title = "相片足跡"
        thumbnails.countLimit = 80
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "walkAlbumList"
        WalkTheme.paint(tableView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .plain, target: self,
                                                           action: #selector(close))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkAlbumDone"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task {
            do {
                records = try await files.records()
                tableView.backgroundView = records.isEmpty ? message("還沒有相片足跡。") : nil
            } catch {
                tableView.backgroundView = message("暫時無法讀取相片足跡。")
            }
            tableView.reloadData()
        }
    }

    private func message(_ text: String) -> UILabel { WalkTheme.message(text) }

    @objc private func close() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }

    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "visit") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "visit")
        let record = records[path.row]
        let cacheKey = record.generation.uuidString as NSString
        let cached = thumbnails.object(forKey: cacheKey)
        var content = cell.defaultContentConfiguration()
        content.text = record.visit.name
        content.secondaryText = record.visit.date + (record.visit.isSimulated ? " · 模擬散步" : "")
        content.image = cached ?? UIImage(systemName: "photo")
        content.imageProperties.maximumSize = CGSize(width: 64, height: 48)
        content.imageProperties.reservedLayoutSize = CGSize(width: 64, height: 48)
        content.imageProperties.cornerRadius = 8
        WalkTheme.style(cell, &content)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "walkAlbumVisit-" + record.visit.id
        cell.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: "，")
        if cached == nil {
            Task { [weak cell] in
                guard let image = try? await files.preview(.photo, record: record, pixels: 160) else { return }
                let thumbnail = UIImage(cgImage: image)
                thumbnails.setObject(thumbnail, forKey: cacheKey)
                guard let cell, tableView.indexPath(for: cell) == path, records.indices.contains(path.row),
                      records[path.row].generation == record.generation,
                      var visible = cell.contentConfiguration as? UIListContentConfiguration else { return }
                visible.image = thumbnail
                cell.contentConfiguration = visible
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        navigationController?.pushViewController(WalkPhotoDetail(files: files, visitID: records[path.row].visit.id),
                                                animated: true)
    }
}

@MainActor
private final class WalkPhotoDetail: UIViewController {
    private let files: WalkPhotoFiles
    private let visitID: String
    private var record: WalkPhotoRecord?
    private var previewTask: Task<Void, Never>?
    private let picker = UISegmentedControl(items: ["透卡", "照片"])
    private let picture = UIImageView()
    private let caption = UILabel()
    private let shareButton = UIButton(type: .system)

    init(files: WalkPhotoFiles, visitID: String) {
        self.files = files
        self.visitID = visitID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        WalkTheme.paint(view)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .plain, target: self,
                                                           action: #selector(close))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkAlbumDone"
        picker.accessibilityIdentifier = "walkAlbumImagePicker"
        picker.selectedSegmentIndex = 0
        picker.addTarget(self, action: #selector(loadPreview), for: .valueChanged)
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = false
        picture.setContentHuggingPriority(.defaultLow, for: .vertical)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.font = WalkTheme.sans(15, weight: .medium, style: .subheadline)
        caption.textColor = WalkTheme.soft
        caption.adjustsFontForContentSizeCategory = true
        WalkTheme.dress(shareButton, .main, title: "分享透卡")
        shareButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        shareButton.accessibilityIdentifier = "walkAlbumShare"
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        shareButton.isEnabled = false

        let stack = UIStackView(arrangedSubviews: [picker, picture, caption, shareButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12)
        ])
        Task {
            do {
                guard let found = try await files.records().first(where: { $0.visit.id == visitID }) else {
                    caption.text = "找不到這一趟的相片足跡。"
                    return
                }
                record = found
                title = found.visit.name
                caption.text = found.visit.date + (found.visit.isSimulated ? " · 模擬散步" : "")
                loadPreview()
                shareButton.isEnabled = true
            } catch { caption.text = "暫時無法讀取相片足跡。" }
        }
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func loadPreview() {
        guard let record else { return }
        previewTask?.cancel()
        let card = picker.selectedSegmentIndex == 0
        picture.image = nil
        picture.accessibilityIdentifier = nil
        picture.isAccessibilityElement = false
        let pixels = Int(max(view.bounds.width, view.bounds.height) * traitCollection.displayScale)
        previewTask = Task {
            do {
                let image = try await files.preview(card ? .card : .photo, record: record, pixels: max(640, pixels))
                guard !Task.isCancelled else { return }
                picture.image = UIImage(cgImage: image)
                picture.accessibilityLabel = record.visit.name + (card ? "的透卡" : "的照片")
                picture.accessibilityIdentifier = card ? "walkAlbumCardImage" : "walkAlbumOriginalImage"
                picture.isAccessibilityElement = true
            } catch {
                if !Task.isCancelled { caption.text = "暫時無法讀取這張圖片。" }
            }
        }
    }

    @objc private func share() {
        guard let record, shareButton.isEnabled else { return }
        shareButton.isEnabled = false
        Task {
            defer { shareButton.isEnabled = true }
            do {
                let copy = try await files.sharableCard(record)
                guard viewIfLoaded?.window != nil else { await files.discardShare(copy); return }
                let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = shareButton
                sheet.popoverPresentationController?.sourceRect = shareButton.bounds
                sheet.completionWithItemsHandler = { [files] _, _, _, _ in
                    Task { await files.discardShare(copy) }
                }
                present(sheet, animated: true)
            } catch {
                let alert = UIAlertController(title: "暫時無法分享這張透卡", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
