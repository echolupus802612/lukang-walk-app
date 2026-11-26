import MapKit
import UIKit

private typealias JournalEntry = WalkJournalStore.Entry

private extension WalkJournalStore.Entry {
    var revealed: Bool { status == .arrived || status == .legacy }

    var journalTitle: String {
        if revealed && !name.isEmpty { return name }
        switch status {
        case .walking: return "散步途中"
        case .stopped: return "中途收工的散步"
        case .interrupted: return "中斷的散步"
        case .arrived: return "已抵達的地點"
        case .legacy: return "以往到過的地點"
        }
    }

    var statusText: String {
        switch status {
        case .walking: return "散步中"
        case .arrived: return "已抵達"
        case .stopped: return "已收工"
        case .interrupted: return "已中斷"
        case .legacy: return "以往到過"
        }
    }

    var modeText: String { isSimulated ? "模擬散步" : "實地散步" }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard revealed, !isSimulated, let latitude, let longitude else { return nil }
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(point) ? point : nil
    }
}

@MainActor
final class WalkJournalViewController: UITableViewController, UISearchResultsUpdating {
    typealias AddPhoto = (UIViewController, String) -> Void
    private let store: WalkJournalStore
    private let album: WalkPhotoAlbum
    private let addPhoto: AddPhoto
    private let search = UISearchController(searchResultsController: nil)
    private var entries: [JournalEntry] = []
    private var sections: [[JournalEntry]] = []
    private var favoritesOnly = false
    private var readFailed = false

    static func present(from presenter: UIViewController, store: WalkJournalStore,
                        album: WalkPhotoAlbum, showing id: String? = nil, addPhoto: @escaping AddPhoto) {
        let list = WalkJournalViewController(store: store, album: album, addPhoto: addPhoto)
        let nav = UINavigationController(rootViewController: list)
        if let id {
            nav.setViewControllers([list, list.detail(id)], animated: false)
        }
        presenter.present(nav, animated: true)
    }

    private init(store: WalkJournalStore, album: WalkPhotoAlbum, addPhoto: @escaping AddPhoto) {
        self.store = store
        self.album = album
        self.addPhoto = addPhoto
        super.init(style: .insetGrouped)
        title = "散步日誌"
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "walkJournalList"
        tableView.keyboardDismissMode = .onDrag
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "搜尋地點或筆記"
        search.searchBar.searchTextField.accessibilityIdentifier = "walkJournalSearch"
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self,
                                                            action: #selector(close))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkJournalDone"
        NotificationCenter.default.addObserver(self, selector: #selector(reloadJournal),
                                               name: .walkJournalDidChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadJournal()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func toggleFilter() {
        favoritesOnly.toggle()
        filter()
    }

    @objc private func reloadJournal() {
        do {
            entries = try store.entries()
            readFailed = false
        } catch {
            entries = []
            readFailed = true
        }
        filter()
    }

    func updateSearchResults(for searchController: UISearchController) { filter() }

    private func filter() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = entries.filter { entry in
            (!favoritesOnly || entry.favorite) && (query.isEmpty || entry.journalTitle.localizedStandardContains(query)
                                                   || entry.note.localizedStandardContains(query))
        }
        sections = [hits.filter { $0.status != .legacy }, hits.filter { $0.status == .legacy }].filter { !$0.isEmpty }
        let bookmark = UIBarButtonItem(image: UIImage(systemName: favoritesOnly ? "heart.fill" : "heart"),
                                       style: .plain, target: self, action: #selector(toggleFilter))
        bookmark.accessibilityLabel = favoritesOnly ? "顯示全部" : "只看收藏"
        bookmark.accessibilityIdentifier = "walkJournalFavoritesFilter"
        navigationItem.leftBarButtonItem = bookmark
        let empty = UILabel()
        empty.textAlignment = .center
        empty.textColor = .secondaryLabel
        if readFailed { empty.text = "暫時無法讀取散步日誌。" }
        else if !query.isEmpty { empty.text = "找不到符合的地點或筆記。" }
        else if favoritesOnly { empty.text = "還沒有收藏。" }
        else { empty.text = "還沒有散步紀錄。" }
        tableView.backgroundView = sections.isEmpty ? empty : nil
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].first?.status == .legacy ? "以往到過的地點" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = sections[indexPath.section][indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "entry")
        var content = cell.defaultContentConfiguration()
        content.text = entry.journalTitle
        let date = entry.startedAt.map(Self.formatDate) ?? entry.date
        let facts = [entry.modeText, entry.status == .legacy ? "" : entry.statusText, date].filter { !$0.isEmpty }
        content.secondaryText = facts.joined(separator: " · ")
        if !entry.note.isEmpty { content.secondaryText? += "\n" + entry.note }
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: entry.favorite ? "heart.fill" : "book.closed")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "walkJournalEntry-" + entry.id
        cell.accessibilityLabel = [content.text, content.secondaryText, entry.favorite ? "已收藏" : nil]
            .compactMap { $0 }.joined(separator: "，")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selected = sections[indexPath.section][indexPath.row]
        navigationController?.pushViewController(detail(selected.id), animated: true)
    }

    private func detail(_ id: String) -> WalkJournalDetail {
        WalkJournalDetail(store: store, album: album, id: id, addPhoto: addPhoto)
    }

    fileprivate static func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "zh_Hant_TW")))
    }
}

@MainActor
private final class WalkJournalDetail: UITableViewController {
    private enum Row: Equatable { case status, start, end, date, note, favorite, map, photo(Int), addPhoto }
    private let store: WalkJournalStore
    private let album: WalkPhotoAlbum
    private let id: String
    private let addPhoto: WalkJournalViewController.AddPhoto
    private var entry: JournalEntry?
    private var sections: [[Row]] = []
    private var photos: [WalkPhotoAlbum.Visit] = []
    private var albumTask: Task<Void, Never>?

    init(store: WalkJournalStore, album: WalkPhotoAlbum, id: String,
         addPhoto: @escaping WalkJournalViewController.AddPhoto) {
        self.store = store
        self.album = album
        self.id = id
        self.addPhoto = addPhoto
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "walkJournalDetail"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self,
                                                            action: #selector(close))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkJournalDone"
        NotificationCenter.default.addObserver(self, selector: #selector(reloadJournal),
                                               name: .walkJournalDidChange, object: nil)
    }

    @objc private func close() { dismiss(animated: true) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadJournal()
    }

    @objc private func reloadJournal() {
        albumTask?.cancel()
        do {
            entry = try store.entry(id: id)
            if entry == nil { throw CocoaError(.fileNoSuchFile) }
            tableView.backgroundView = nil
        } catch {
            entry = nil
            let label = UILabel()
            label.textAlignment = .center
            label.text = "暫時無法讀取這筆紀錄。"
            tableView.backgroundView = label
        }
        render()
        guard let entry, entry.status != .legacy else { return }
        albumTask = Task { [weak self, album, id] in
            do {
                let visits = try await album.savedVisits().filter { $0.journalID == id }
                guard !Task.isCancelled, let self else { return }
                if self.photos.map(\.id) != visits.map(\.id) {
                    self.photos = visits
                    self.render()
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.showError("暫時無法讀取這趟的相片。")
            }
        }
    }

    private func render() {
        guard let entry else { sections = []; tableView.reloadData(); return }
        title = entry.journalTitle
        var timing: [Row] = [.status]
        if entry.startedAt != nil { timing.append(.start) }
        if entry.endedAt != nil { timing.append(.end) }
        if entry.startedAt == nil && entry.endedAt == nil && !entry.date.isEmpty { timing.append(.date) }
        var actions: [Row] = []
        if entry.mapCoordinate != nil { actions.append(.map) }
        if entry.status != .legacy {
            actions += photos.indices.map(Row.photo)
            actions.append(.addPhoto)
        }
        sections = [timing, [.note, .favorite], actions].filter { !$0.isEmpty }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let entry else { return cell }
        let row = sections[indexPath.section][indexPath.row]
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none
        switch row {
        case .status:
            content.text = entry.statusText
            content.secondaryText = entry.modeText
        case .start, .end:
            let start = row == .start
            content.text = start ? "出發時間" : "結束時間"
            content.secondaryText = (start ? entry.startedAt : entry.endedAt).map(WalkJournalViewController.formatDate)
        case .date:
            content.text = "日期"; content.secondaryText = entry.date
        case .note:
            content.text = entry.status == .legacy ? "地點筆記" : "散步筆記"
            content.secondaryText = entry.note.isEmpty ? "寫筆記" : entry.note
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "walkJournalNote"
        case .favorite:
            content.text = entry.favorite ? "取消收藏" : "加入收藏"
            content.image = UIImage(systemName: entry.favorite ? "heart.fill" : "heart")
            cell.accessibilityIdentifier = "walkJournalFavorite"
        case .map:
            content.text = "查看地圖"; content.image = UIImage(systemName: "map")
            cell.accessibilityIdentifier = "walkJournalMap"
        case .photo(let index):
            let photo = photos[index]
            content.text = photos.count == 1 ? "查看照片與透卡" : "照片與透卡 " + String(index + 1)
            let photoTitle = entry.revealed ? photo.name : "散步途中"
            content.secondaryText = [photoTitle, photo.date].filter { !$0.isEmpty }.joined(separator: " · ")
            content.image = UIImage(systemName: "photo.on.rectangle")
            cell.accessibilityIdentifier = photos.count == 1 ? "walkJournalPhoto" : "walkJournalPhoto-" + photo.id
            cell.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: "，")
        case .addPhoto:
            content.text = "加入照片"; content.image = UIImage(systemName: "camera")
            cell.accessibilityIdentifier = "walkJournalAddPhoto"
        }
        switch row {
        case .note, .map, .photo, .addPhoto:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .favorite: cell.selectionStyle = .default
        default: break
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry else { return }
        switch sections[indexPath.section][indexPath.row] {
        case .note:
            let editor = WalkJournalNote(text: entry.note) { [store, id] text in
                try store.setNote(id: id, note: text)
            }
            present(UINavigationController(rootViewController: editor), animated: true)
        case .favorite:
            do { try store.setFavorite(id: id, favorite: !entry.favorite) }
            catch { showError("暫時無法儲存收藏。") }
        case .map:
            guard let coordinate = entry.mapCoordinate else { return }
            let controller = UIViewController()
            controller.title = "地點地圖"
            let map = MKMapView()
            map.accessibilityIdentifier = "walkJournalPlaceMap"
            let pin = MKPointAnnotation()
            pin.coordinate = coordinate
            pin.title = entry.journalTitle
            map.addAnnotation(pin)
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 650, longitudinalMeters: 650),
                          animated: false)
            map.selectAnnotation(pin, animated: false)
            controller.view = map
            navigationController?.pushViewController(controller, animated: true)
        case .photo(let index): album.present(from: self, showing: photos[index].id)
        case .addPhoto: addPhoto(self, id)
        default: break
        }
    }

    private func showError(_ text: String) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

@MainActor
private final class WalkJournalNote: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let original: String
    private let saveNote: (String) throws -> Void

    init(text: String, save: @escaping (String) throws -> Void) {
        original = text
        saveNote = save
        super.init(nibName: nil, bundle: nil)
        title = "編輯筆記"
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        editor.text = original
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.delegate = self
        editor.accessibilityLabel = "筆記內容"
        editor.accessibilityIdentifier = "walkJournalEditor"
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "儲存", style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "walkJournalSaveNote"
    }

    func textViewDidChange(_ textView: UITextView) {
        navigationController?.isModalInPresentation = editor.text != original
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func save() {
        do { try saveNote(editor.text); close() }
        catch {
            let alert = UIAlertController(title: "暫時無法儲存筆記。", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }
}
