import UIKit

// MARK: - Скачанные главы (манифест хранится в файле рядом со страницами)

struct StoredPage: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

struct DownloadedChapter: Codable {
    let ref: TitleRef
    let chapterId: Int
    let volume: String
    let number: String
    let chapterName: String
    let branchIds: [Int]
    let pages: [StoredPage]
    let bytes: Int64
    let date: Date

    var id: String { return "\(ref.slug)#\(chapterId)" }

    var chapter: Chapter {
        return Chapter(id: chapterId, volume: volume, number: number, name: chapterName, branchIds: branchIds)
    }

    var pageList: [Page] {
        return pages.map { Page(url: $0.url, width: $0.width, height: $0.height) }
    }
}

final class DownloadStore {
    static let shared = DownloadStore()
    static let didChange = Notification.Name("DownloadStoreDidChange")

    private var items: [String: DownloadedChapter] = [:]
    private let writeQueue = DispatchQueue(label: "slashlib.manifest", qos: .utility)
    private var manifestURL: URL { return PageFiles.offlineDir.appendingPathComponent("manifest.json") }

    private init() {
        if let data = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([DownloadedChapter].self, from: data) {
            for d in list { items[d.id] = d }
        }
    }

    var count: Int { return items.count }

    var totalBytes: Int64 {
        var sum: Int64 = 0
        for d in items.values { sum += d.bytes }
        return sum
    }

    private static func ordered(_ list: [DownloadedChapter]) -> [DownloadedChapter] {
        return list.sorted { a, b in
            let x = a.chapter.sortKey, y = b.chapter.sortKey
            if x.0 != y.0 { return x.0 < y.0 }
            return x.1 < y.1
        }
    }

    func all() -> [DownloadedChapter] { return DownloadStore.ordered(Array(items.values)) }

    func chapters(slug: String) -> [DownloadedChapter] {
        return DownloadStore.ordered(items.values.filter { $0.ref.slug == slug })
    }

    func downloaded(slug: String, chapterId: Int) -> DownloadedChapter? {
        return items["\(slug)#\(chapterId)"]
    }

    func isDownloaded(slug: String, chapterId: Int) -> Bool {
        return items["\(slug)#\(chapterId)"] != nil
    }

    func add(_ d: DownloadedChapter) {
        items[d.id] = d
        persist()
        notify()
    }

    func remove(slug: String, chapterId: Int) {
        guard let d = items.removeValue(forKey: "\(slug)#\(chapterId)") else { return }
        deleteFiles(of: [d])
        persist()
        notify()
    }

    func removeAll(slug: String) {
        let victims = items.values.filter { $0.ref.slug == slug }
        guard !victims.isEmpty else { return }
        for d in victims { items.removeValue(forKey: d.id) }
        deleteFiles(of: victims)
        persist()
        notify()
    }

    func removeEverything() {
        let victims = Array(items.values)
        items = [:]
        deleteFiles(of: victims)
        persist()
        notify()
    }

    private func deleteFiles(of list: [DownloadedChapter]) {
        var urls: [URL] = []
        for d in list { for p in d.pages { urls.append(PageFiles.offlineURL(for: p.url)) } }
        DispatchQueue.global(qos: .utility).async {
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func persist() {
        let list = Array(items.values)
        let url = manifestURL
        writeQueue.async {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: DownloadStore.didChange, object: nil)
    }
}

// MARK: - Очередь загрузки

enum DownloadState {
    case queued
    case running(Int, Int)      // скачано страниц, всего (всего = 0, пока получаем список страниц)
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class DownloadJob {
    let ref: TitleRef
    let chapter: Chapter
    var state: DownloadState = .queued
    var cancelled = false
    var pages: [Page] = []
    var next = 0
    var inFlight = 0
    var done = 0
    var bytes: Int64 = 0
    var error: String?

    init(ref: TitleRef, chapter: Chapter) {
        self.ref = ref
        self.chapter = chapter
    }

    func reset() {
        state = .queued
        cancelled = false
        pages = []
        next = 0
        inFlight = 0
        done = 0
        bytes = 0
        error = nil
    }
}

// Всё выполняется на главном потоке. Главы качаются по одной; страницы внутри главы — в 1–3 потока
// (1 при энергосбережении, 2 на устройствах с 1 ГБ памяти).
final class DownloadManager {
    static let shared = DownloadManager()
    static let didChange = Notification.Name("DownloadManagerDidChange")

    private(set) var jobs: [DownloadJob] = []
    private var active: DownloadJob?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    private init() {}

    func job(slug: String, chapterId: Int) -> DownloadJob? {
        return jobs.first { $0.ref.slug == slug && $0.chapter.id == chapterId }
    }

    func enqueue(ref: TitleRef, chapters: [Chapter]) {
        var added = 0
        for c in chapters {
            if DownloadStore.shared.isDownloaded(slug: ref.slug, chapterId: c.id) { continue }
            if let existing = job(slug: ref.slug, chapterId: c.id) {
                if existing.state.isFailed { existing.reset(); added += 1 }
                continue
            }
            jobs.append(DownloadJob(ref: ref, chapter: c))
            added += 1
        }
        guard added > 0 else { return }
        Breadcrumbs.shared.log("в очередь загрузки добавлено глав: \(added)")
        notify()
        pump()
    }

    func retry(slug: String, chapterId: Int) {
        guard let j = job(slug: slug, chapterId: chapterId), j.state.isFailed else { return }
        j.reset()
        notify()
        pump()
    }

    func cancel(slug: String, chapterId: Int) {
        guard let j = job(slug: slug, chapterId: chapterId) else { return }
        remove(j)
    }

    func cancelAll(slug: String) {
        for j in jobs where j.ref.slug == slug { remove(j) }
    }

    func cancelEverything() {
        for j in jobs { remove(j) }
    }

    private func remove(_ j: DownloadJob) {
        j.cancelled = true
        jobs.removeAll { $0 === j }
        if active === j { active = nil }
        cleanupFiles(j)
        notify()
        pump()
    }

    private func cleanupFiles(_ j: DownloadJob) {
        let urls = j.pages.map { PageFiles.offlineURL(for: $0.url) }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: DownloadManager.didChange, object: nil)
    }

    // MARK: выполнение

    private func pump() {
        guard active == nil else { return }
        guard let j = jobs.first(where: { !$0.state.isFailed }) else {
            endBackgroundTask()
            return
        }
        active = j
        beginBackgroundTask()
        start(j)
    }

    private func start(_ j: DownloadJob) {
        if PageFiles.freeBytes() < 150 * 1_048_576 {
            fail(j, "На устройстве мало свободного места (меньше 150 МБ)")
            return
        }
        j.state = .running(0, 0)
        notify()
        API.shared.pages(slug: j.ref.slug, chapter: j.chapter, site: j.ref.site) { [weak self] result in
            guard let self = self, !j.cancelled else { return }
            switch result {
            case .success(let pages):
                j.pages = pages
                j.state = .running(0, pages.count)
                self.notify()
                self.fill(j)
            case .failure(let e):
                self.fail(j, e.localizedDescription)
            }
        }
    }

    private func fill(_ j: DownloadJob) {
        let limit = Power.isSaving ? 1 : (MemoryInfo.isLowRAM ? 2 : 3)
        while !j.cancelled && j.error == nil && j.inFlight < limit && j.next < j.pages.count {
            let page = j.pages[j.next]
            j.next += 1
            j.inFlight += 1
            ImageLoader.shared.saveOffline(page.url, site: j.ref.site) { [weak self] result in
                guard let self = self else { return }
                if j.cancelled {
                    // задание отменили, пока страница качалась — убираем за собой
                    try? FileManager.default.removeItem(at: PageFiles.offlineURL(for: page.url))
                    return
                }
                j.inFlight -= 1
                switch result {
                case .success(let size):
                    j.done += 1
                    j.bytes += size
                    j.state = .running(j.done, j.pages.count)
                case .failure(let e):
                    if j.error == nil { j.error = "стр. \(j.done + 1): \(e.localizedDescription)" }
                }
                self.notify()
                if let err = j.error {
                    if j.inFlight == 0 { self.fail(j, err) }
                } else if j.done == j.pages.count {
                    self.complete(j)
                } else {
                    self.fill(j)
                }
            }
        }
    }

    private func complete(_ j: DownloadJob) {
        let stored = j.pages.map { StoredPage(url: $0.url, width: $0.width, height: $0.height) }
        DownloadStore.shared.add(DownloadedChapter(ref: j.ref,
                                                   chapterId: j.chapter.id,
                                                   volume: j.chapter.volume,
                                                   number: j.chapter.number,
                                                   chapterName: j.chapter.name,
                                                   branchIds: j.chapter.branchIds,
                                                   pages: stored,
                                                   bytes: j.bytes,
                                                   date: Date()))
        Breadcrumbs.shared.log("глава скачана: \(j.ref.name) · \(j.chapter.shortDisplay), стр. \(j.pages.count)")
        jobs.removeAll { $0 === j }
        active = nil
        notify()
        pump()
    }

    private func fail(_ j: DownloadJob, _ message: String) {
        Breadcrumbs.shared.log("ОШИБКА загрузки главы: \(message)")
        j.state = .failed(message)
        cleanupFiles(j)
        active = nil
        notify()
        pump()
    }

    // MARK: фоновая задача (даёт доработать, если приложение свернули)

    private func beginBackgroundTask() {
        guard bgTask == UIBackgroundTaskIdentifier.invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "slashlib.download") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTask != UIBackgroundTaskIdentifier.invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = UIBackgroundTaskIdentifier.invalid
    }
}

// MARK: - Экран «Загрузки»

final class DownloadsViewController: UITableViewController {
    private struct Group {
        let ref: TitleRef
        let items: [DownloadedChapter]
    }

    private var groups: [Group] = []
    private var queue: [DownloadJob] = []
    private var reloadScheduled = false
    private let emptyLabel = UILabel()

    init() {
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Загрузки"
        tableView.rowHeight = 60
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Удалить всё", style: .plain, target: self, action: #selector(deleteAllTapped))

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .gray
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.text = "Скачанных глав нет.\nОткройте тайтл и выберите «Загрузки» или смахните главу влево."

        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: DownloadManager.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: DownloadStore.didChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    @objc private func changed() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.reloadScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        queue = DownloadManager.shared.jobs
        var map: [String: [DownloadedChapter]] = [:]
        var refs: [String: TitleRef] = [:]
        for d in DownloadStore.shared.all() {
            map[d.ref.slug, default: []].append(d)
            refs[d.ref.slug] = d.ref
        }
        let slugs = map.keys.sorted { (refs[$0]?.name ?? "") < (refs[$1]?.name ?? "") }
        groups = slugs.compactMap { slug -> Group? in
            guard let ref = refs[slug], let items = map[slug] else { return nil }
            return Group(ref: ref, items: items)
        }
        Theme.styleTable(tableView)
        emptyLabel.textColor = Theme.secondary
        tableView.backgroundView = (queue.isEmpty && groups.isEmpty) ? emptyLabel : nil
        tableView.reloadData()
    }

    private func size(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: таблица

    private var queueSection: Int? { return queue.isEmpty ? nil : 0 }
    private func groupIndex(for section: Int) -> Int { return section - (queue.isEmpty ? 0 : 1) }

    override func numberOfSections(in tv: UITableView) -> Int {
        return groups.count + (queue.isEmpty ? 0 : 1)
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == queueSection { return queue.count }
        let g = groupIndex(for: section)
        return groups.indices.contains(g) ? groups[g].items.count : 0
    }

    override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == queueSection { return "Очередь загрузки" }
        let g = groupIndex(for: section)
        guard groups.indices.contains(g) else { return nil }
        var bytes: Int64 = 0
        for d in groups[g].items { bytes += d.bytes }
        return "\(groups[g].ref.name) — \(groups[g].items.count) гл., \(size(bytes))"
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "d")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "d")
        Theme.styleCell(cell)
        if ip.section == queueSection {
            let j = queue[ip.row]
            cell.textLabel?.text = "\(j.ref.name) · \(j.chapter.shortDisplay)"
            switch j.state {
            case .queued:
                cell.detailTextLabel?.text = "В очереди"
            case .running(let d, let t):
                cell.detailTextLabel?.text = t > 0 ? "Скачивается: \(d) из \(t) стр." : "Получаю список страниц…"
            case .failed(let m):
                cell.detailTextLabel?.text = "Ошибка (нажмите, чтобы повторить): \(m)"
            }
            cell.detailTextLabel?.numberOfLines = 2
            cell.accessoryType = .none
        } else {
            let d = groups[groupIndex(for: ip.section)].items[ip.row]
            cell.textLabel?.text = d.chapter.display
            cell.detailTextLabel?.text = "\(d.pages.count) стр. · \(size(d.bytes))"
            cell.detailTextLabel?.numberOfLines = 1
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tv: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = Theme.secondary
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        if ip.section == queueSection {
            let j = queue[ip.row]
            DownloadManager.shared.retry(slug: j.ref.slug, chapterId: j.chapter.id)
            return
        }
        let g = groups[groupIndex(for: ip.section)]
        let d = g.items[ip.row]
        navigationController?.pushViewController(
            ReaderViewController(title: g.ref, chapter: d.chapter, chapters: [], startPage: 0), animated: true)
    }

    override func tableView(_ tv: UITableView, commit style: UITableViewCell.EditingStyle,
                            forRowAt ip: IndexPath) {
        guard style == .delete else { return }
        if ip.section == queueSection {
            let j = queue[ip.row]
            DownloadManager.shared.cancel(slug: j.ref.slug, chapterId: j.chapter.id)
        } else {
            let g = groups[groupIndex(for: ip.section)]
            let d = g.items[ip.row]
            DownloadStore.shared.remove(slug: g.ref.slug, chapterId: d.chapterId)
        }
    }

    @objc private func deleteAllTapped() {
        let alert = UIAlertController(title: "Удалить все загрузки?",
                                      message: "Скачанные главы и очередь будут удалены. Закладки и история останутся.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in
            DownloadManager.shared.cancelEverything()
            DownloadStore.shared.removeEverything()
        })
        present(alert, animated: true)
    }
}
