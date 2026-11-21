import UIKit

// Две вкладки: «Закладки» (поставленные вручную) и «Недавние» (сохраняются сами — последнее место в каждом
// тайтле, с полосой прогресса чтения). Нажатие открывает главу на нужной странице.
final class HistoryViewController: UITableViewController {
    // Ставится с главной («История ›»), чтобы открыть сразу вкладку «Недавние».
    static var preferRecent = false

    private var items: [Bookmark] = []
    private let emptyLabel = UILabel()
    private let segment = UISegmentedControl(items: ["Закладки", "Недавние"])
    private var showRecent: Bool { return segment.selectedSegmentIndex == 1 }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Закладки"
        tableView.rowHeight = 92
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(CoverCell.self, forCellReuseIdentifier: "b")
        navigationItem.rightBarButtonItem = editButtonItem

        segment.selectedSegmentIndex = 0
        segment.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        navigationItem.titleView = segment

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyTheme() {
        Theme.styleTable(tableView)
        emptyLabel.textColor = Theme.secondary
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if HistoryViewController.preferRecent {
            HistoryViewController.preferRecent = false
            segment.selectedSegmentIndex = 1
        }
        reload()
    }

    @objc private func segmentChanged() {
        setEditing(false, animated: false)
        reload()
    }

    private func reload() {
        items = showRecent ? ReadingProgress.shared.recent : BookmarkStore.shared.all
        emptyLabel.text = showRecent
            ? "Здесь появятся тайтлы, которые вы читаете.\nМесто, где остановились, сохраняется само."
            : "Закладок пока нет.\nОткройте главу и нажмите значок закладки вверху справа."
        tableView.backgroundView = items.isEmpty ? emptyLabel : nil
        tableView.reloadData()
        Fx.cascade(tableView.visibleCells)
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { return items.count }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "b", for: ip) as! CoverCell
        let b = items[ip.row]
        let detail = "\(b.chapter.display)\nстр. \(b.page + 1) из \(b.pageCount) · \(HistoryViewController.dateFormatter.string(from: b.date))"
        // Полоса прогресса — только в «Недавних»: там это «сколько главы прочитано».
        cell.configure(text: b.titleName, detail: detail, cover: b.cover, site: b.site,
                       progress: showRecent ? b.progress : nil)
        return cell
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let b = items[ip.row]
        navigationController?.pushViewController(
            ReaderViewController(title: b.titleRef, chapter: b.chapter, chapters: [], startPage: b.page),
            animated: true)
    }

    override func tableView(_ tv: UITableView, commit style: UITableViewCell.EditingStyle,
                            forRowAt ip: IndexPath) {
        guard style == .delete, items.indices.contains(ip.row) else { return }
        let b = items[ip.row]
        if showRecent { ReadingProgress.shared.remove(slug: b.slug) } else { BookmarkStore.shared.remove(id: b.id) }
        items.remove(at: ip.row)
        tv.deleteRows(at: [ip], with: .automatic)
        tableView.backgroundView = items.isEmpty ? emptyLabel : nil
    }
}
