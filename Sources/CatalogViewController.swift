import UIKit

// Ячейка со своей обложкой: каталог, история закладок.
final class CoverCell: UITableViewCell {
    var coverPath: String?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        imageView?.contentMode = .scaleAspectFill
        imageView?.clipsToBounds = true
        accessoryType = .disclosureIndicator
        detailTextLabel?.numberOfLines = 2
        detailTextLabel?.textColor = .gray
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let placeholder: UIImage = {
        let size = CGSize(width: 52, height: 72)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }()

    func configure(text: String, detail: String?, cover: String?) {
        textLabel?.text = text
        detailTextLabel?.text = detail
        imageView?.image = CoverCell.placeholder
        coverPath = cover
        guard let p = cover else { return }
        ImageLoader.shared.load(p) { [weak self] img in
            guard let self = self, self.coverPath == p, let img = img else { return }
            let size = CGSize(width: 52, height: 72)
            self.imageView?.image = UIGraphicsImageRenderer(size: size).image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }
            self.setNeedsLayout()
        }
    }
}

final class CatalogViewController: UITableViewController, UISearchBarDelegate {
    private var items: [Title] = []
    private let searchBar = UISearchBar()
    private var lastToken = AuthStore.token

    // Постраничная подгрузка каталога
    private var page = 1
    private var loading = false
    private var finished = false
    private var generation = 0
    private var currentQuery: String?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if AuthStore.token != lastToken {
            lastToken = AuthStore.token
            reload(query: searchBar.text)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Slashlib"
        searchBar.delegate = self
        searchBar.placeholder = "Поиск"
        searchBar.sizeToFit()
        tableView.tableHeaderView = searchBar
        tableView.rowHeight = 84
        tableView.cellLayoutMarginsFollowReadableWidth = true   // на iPad список не растягивается на весь экран
        tableView.register(CoverCell.self, forCellReuseIdentifier: "cell")
        reload(query: nil)
    }

    private func reload(query: String?) {
        generation += 1
        currentQuery = query
        page = 1
        finished = false
        loading = false
        loadNextPage()
    }

    private func loadNextPage() {
        guard !loading, !finished else { return }
        loading = true
        let gen = generation
        let requested = page
        API.shared.catalog(query: currentQuery, page: requested) { [weak self] result in
            guard let self = self, gen == self.generation else { return }
            self.loading = false
            switch result {
            case .success(let list):
                if requested == 1 { self.items = [] }
                let known = Set(self.items.map { $0.id })
                let fresh = list.data.filter { !known.contains($0.id) }
                if fresh.isEmpty { self.finished = true }
                else {
                    self.items.append(contentsOf: fresh)
                    self.page = requested + 1
                }
                self.tableView.reloadData()
            case .failure(let e):
                if requested == 1 { self.showError(e) }
            }
        }
    }

    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        bar.resignFirstResponder()
        reload(query: bar.text)
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { return items.count }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: ip) as! CoverCell
        let t = items[ip.row]
        cell.configure(text: t.display, detail: t.eng_name, cover: t.cover?.thumbnail ?? t.cover?.full)
        return cell
    }

    override func tableView(_ tv: UITableView, willDisplay cell: UITableViewCell, forRowAt ip: IndexPath) {
        if ip.row >= items.count - 5 { loadNextPage() }
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let t = items[ip.row]
        let ref = TitleRef(slug: t.slug, name: t.display, cover: t.cover?.thumbnail ?? t.cover?.full)
        navigationController?.pushViewController(TitleViewController(ref: ref), animated: true)
    }
}
