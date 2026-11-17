import UIKit

// Ячейка со своей обложкой: поиск, избранное, закладки. Если передан progress — внизу рисуется полоса
// прогресса чтения и проценты (оформление «истории чтения»).
final class CoverCell: UITableViewCell {
    var coverPath: String?
    private let progressBar = ProgressBar()
    private let percentLabel = UILabel()
    private var hasProgress = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        imageView?.contentMode = .scaleAspectFill
        imageView?.clipsToBounds = true
        accessoryType = .disclosureIndicator
        detailTextLabel?.numberOfLines = 2
        percentLabel.font = .boldSystemFont(ofSize: 11)
        percentLabel.textAlignment = .right
        progressBar.isHidden = true
        percentLabel.isHidden = true
        contentView.addSubview(progressBar)
        contentView.addSubview(percentLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var cachedPlaceholder: (dark: Bool, image: UIImage)?
    private static let thumbs: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    private static func placeholder() -> UIImage {
        let dark = Theme.isDark
        if let c = cachedPlaceholder, c.dark == dark { return c.image }
        let size = CGSize(width: 52, height: 72)
        let color = Theme.chip
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        cachedPlaceholder = (dark: dark, image: img)
        return img
    }

    func configure(text: String, detail: String?, cover: String?, site: Int? = nil, progress: CGFloat? = nil) {
        Theme.styleCell(self)
        textLabel?.text = text
        textLabel?.font = .boldSystemFont(ofSize: 16)
        detailTextLabel?.text = detail
        imageView?.image = CoverCell.placeholder()
        coverPath = cover
        if let p = progress {
            hasProgress = true
            progressBar.isHidden = false
            percentLabel.isHidden = false
            percentLabel.textColor = Theme.secondary
            percentLabel.text = p >= 0.995 ? "прочитано" : "\(Int((p * 100).rounded()))%"
            progressBar.set(p, animated: true)
        } else {
            hasProgress = false
            progressBar.isHidden = true
            percentLabel.isHidden = true
        }
        setNeedsLayout()
        guard let path = cover else { return }
        if let thumb = CoverCell.thumbs.object(forKey: path as NSString) {
            imageView?.image = thumb
            return
        }
        ImageLoader.shared.load(path, site: site) { [weak self] img in
            guard let self = self, self.coverPath == path, let img = img else { return }
            // Уменьшаем до размера ячейки вне главного потока: прокрутка списка не подтормаживает.
            DispatchQueue.global(qos: .userInitiated).async {
                let size = CGSize(width: 52, height: 72)
                let scaled = UIGraphicsImageRenderer(size: size).image { _ in
                    img.draw(in: CGRect(origin: .zero, size: size))
                }
                CoverCell.thumbs.setObject(scaled, forKey: path as NSString)
                DispatchQueue.main.async {
                    guard self.coverPath == path, let iv = self.imageView else { return }
                    Fx.setImage(iv, scaled)
                    self.setNeedsLayout()
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard hasProgress, let text = textLabel else { return }
        let left = text.frame.minX
        let percentWidth: CGFloat = 62
        let y = contentView.bounds.height - 15
        percentLabel.frame = CGRect(x: contentView.bounds.width - percentWidth - 4, y: y - 5, width: percentWidth, height: 16)
        progressBar.frame = CGRect(x: left, y: y, width: max(percentLabel.frame.minX - left - 8, 10), height: 6)
    }
}

final class CatalogViewController: UITableViewController, UISearchBarDelegate {
    private var items: [Title] = []
    private let searchBar = UISearchBar()
    private var lastToken = AuthStore.token
    private var lastSites = Sites.enabled

    // Постраничная подгрузка каталога
    private var page = 1
    private var loading = false
    private var finished = false
    private var generation = 0
    private var currentQuery: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Поиск"
        searchBar.delegate = self
        searchBar.placeholder = "Название тайтла"
        searchBar.sizeToFit()
        tableView.tableHeaderView = searchBar
        tableView.rowHeight = 84
        tableView.cellLayoutMarginsFollowReadableWidth = true   // на iPad список не растягивается на весь экран
        tableView.register(CoverCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()
        reload(query: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyTheme() {
        Theme.styleTable(tableView)
        searchBar.barStyle = Theme.isDark ? .black : .default
        searchBar.barTintColor = Theme.isDark ? Theme.bar : nil
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if AuthStore.token != lastToken || Sites.enabled != lastSites {
            lastToken = AuthStore.token
            lastSites = Sites.enabled
            reload(query: searchBar.text)
        }
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
                if requested == 1 { Fx.cascade(self.tableView.visibleCells) }
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
        var detail = t.eng_name
        if Prefs.mangalibEnabled, let s = t.site { detail = [detail, Sites.name(s)].compactMap { $0 }.joined(separator: " · ") }
        cell.configure(text: t.display, detail: detail, cover: t.cover?.thumbnail ?? t.cover?.full, site: t.site)
        return cell
    }

    override func tableView(_ tv: UITableView, willDisplay cell: UITableViewCell, forRowAt ip: IndexPath) {
        if ip.row >= items.count - 5 { loadNextPage() }
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        navigationController?.pushViewController(TitleViewController(ref: items[ip.row].ref), animated: true)
    }
}
