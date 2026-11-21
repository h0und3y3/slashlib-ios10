import UIKit

// Вкладка «Избранное».
final class FavoritesViewController: UITableViewController {
    private var items: [FavoriteItem] = []
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Избранное"
        tableView.rowHeight = 92
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(CoverCell.self, forCellReuseIdentifier: "f")
        navigationItem.rightBarButtonItem = editButtonItem

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.text = "В избранном пока пусто.\nОткройте тайтл и нажмите на звезду вверху справа."

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
        items = FavoritesStore.shared.all
        tableView.backgroundView = items.isEmpty ? emptyLabel : nil
        tableView.reloadData()
        Fx.cascade(tableView.visibleCells)
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { return items.count }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "f", for: ip) as! CoverCell
        let ref = items[ip.row].ref
        var detail: String?
        var progress: CGFloat?
        if let last = ReadingProgress.shared.last(slug: ref.slug) {
            detail = "\(last.chapter.shortDisplay), стр. \(last.page + 1)"
            progress = last.progress
        }
        cell.configure(text: ref.name, detail: detail, cover: ref.cover, site: ref.site, progress: progress)
        return cell
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        navigationController?.pushViewController(TitleViewController(ref: items[ip.row].ref), animated: true)
    }

    override func tableView(_ tv: UITableView, commit style: UITableViewCell.EditingStyle,
                            forRowAt ip: IndexPath) {
        guard style == .delete, items.indices.contains(ip.row) else { return }
        FavoritesStore.shared.remove(slug: items[ip.row].ref.slug)
        items.remove(at: ip.row)
        tv.deleteRows(at: [ip], with: .automatic)
        tableView.backgroundView = items.isEmpty ? emptyLabel : nil
    }
}
