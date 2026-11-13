import UIKit

// Вкладка «Избранное».
final class FavoritesViewController: UITableViewController {
    private var items: [FavoriteItem] = []
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Избранное"
        tableView.rowHeight = 84
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(CoverCell.self, forCellReuseIdentifier: "f")
        navigationItem.rightBarButtonItem = editButtonItem

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .gray
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.text = "В избранном пока пусто.\nОткройте тайтл и нажмите на звезду вверху справа."
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        items = FavoritesStore.shared.all
        tableView.backgroundView = items.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { return items.count }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "f", for: ip) as! CoverCell
        let ref = items[ip.row].ref
        var detail: String?
        if let last = ReadingProgress.shared.last(slug: ref.slug) {
            detail = "\(last.chapter.shortDisplay), стр. \(last.page + 1)"
        }
        cell.configure(text: ref.name, detail: detail, cover: ref.cover)
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
