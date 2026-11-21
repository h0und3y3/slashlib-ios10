import UIKit

// MARK: - Данные главной страницы

struct HomeTitle {
    let ref: TitleRef
    let chips: [String]
}

struct Shelf {
    let name: String
    let titles: [HomeTitle]
}

private struct HomeRequest {
    let name: String
    let genreId: Int?
    let page: Int
}

// Случайные подборки: одна общая и несколько по случайным жанрам.
// ПРОВЕРИТЬ: жанры берутся из /constants, фильтр — параметр genres[] (см. API.swift).
enum HomeLoader {
    static func load(done: @escaping (Result<[Shelf], Error>) -> Void) {
        API.shared.genres { genres in
            var requests = [HomeRequest(name: "Случайные находки", genreId: nil, page: Int.random(in: 1...20))]
            for g in genres.shuffled().prefix(5) {
                requests.append(HomeRequest(name: g.name, genreId: g.id, page: Int.random(in: 1...3)))
            }

            let group = DispatchGroup()
            var results: [[Title]] = Array(repeating: [], count: requests.count)
            var lastError: Error?
            var anySuccess = false

            for (i, r) in requests.enumerated() {
                group.enter()
                fetch(r, retryOnEmpty: true) { result in
                    switch result {
                    case .success(let titles):
                        results[i] = titles
                        anySuccess = true
                    case .failure(let e):
                        lastError = e
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                if !anySuccess {
                    done(.failure(lastError ?? URLError(.cannotConnectToHost)))
                    return
                }
                var seen = Set<Int>()
                var shelves: [Shelf] = []
                for (i, r) in requests.enumerated() {
                    let pool = results[i].filter { !seen.contains($0.id) }.shuffled().prefix(10)
                    guard pool.count >= 2 else { continue }
                    var items: [HomeTitle] = []
                    for t in pool {
                        seen.insert(t.id)
                        var chips = t.chips
                        if r.genreId != nil {
                            chips.removeAll { $0 == r.name }
                            chips.insert(r.name, at: 0)
                        }
                        items.append(HomeTitle(ref: t.ref, chips: chips))
                    }
                    shelves.append(Shelf(name: r.name, titles: items))
                }
                done(.success(shelves))
            }
        }
    }

    // Если случайная страница оказалась за пределами каталога — берём первую.
    private static func fetch(_ r: HomeRequest, retryOnEmpty: Bool,
                              done: @escaping (Result<[Title], Error>) -> Void) {
        API.shared.catalog(query: nil, page: r.page, genreId: r.genreId) { result in
            switch result {
            case .success(let list):
                if list.data.isEmpty && r.page > 1 && retryOnEmpty {
                    fetch(HomeRequest(name: r.name, genreId: r.genreId, page: 1), retryOnEmpty: false, done: done)
                } else {
                    done(.success(list.data))
                }
            case .failure(let e):
                done(.failure(e))
            }
        }
    }
}

// MARK: - Карточка «продолжить чтение» с полосой прогресса

final class ProgressCardCell: UITableViewCell {
    private let card = UIView()
    private let cover = UIImageView()
    private let titleLabel = UILabel()
    private let chapterLabel = UILabel()
    private let bar = ProgressBar()
    private let percent = UILabel()
    private var coverPath: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.layer.cornerRadius = 12
        contentView.addSubview(card)

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 6
        card.addSubview(cover)

        titleLabel.font = .boldSystemFont(ofSize: 16)
        card.addSubview(titleLabel)
        chapterLabel.font = .systemFont(ofSize: 13)
        card.addSubview(chapterLabel)
        card.addSubview(bar)
        percent.font = .boldSystemFont(ofSize: 12)
        percent.textAlignment = .right
        card.addSubview(percent)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ b: Bookmark) {
        card.backgroundColor = Theme.card
        if Fx.enabled {
            card.layer.borderWidth = 0
        } else {
            card.layer.borderWidth = 0.5
            card.layer.borderColor = Theme.separator.cgColor
        }
        Fx.decorate(card: card)
        titleLabel.textColor = Theme.text
        titleLabel.text = b.titleName
        chapterLabel.textColor = Theme.secondary
        chapterLabel.text = "\(b.chapter.display) · стр. \(b.page + 1) из \(b.pageCount)"
        percent.textColor = b.progress >= 0.995 ? Theme.accent : Theme.secondary
        percent.text = b.progress >= 0.995 ? "прочитано" : "\(Int((b.progress * 100).rounded()))%"
        bar.set(b.progress, animated: true)

        cover.backgroundColor = Theme.chip
        cover.image = nil
        coverPath = b.cover
        if let path = b.cover {
            ImageLoader.shared.load(path, site: b.site) { [weak self] img in
                guard let self = self, self.coverPath == path, let img = img else { return }
                Fx.setImage(self.cover, img)
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds.insetBy(dx: 12, dy: 6)
        let w = card.bounds.width
        cover.frame = CGRect(x: 10, y: 9, width: 46, height: 70)
        let x: CGFloat = 68
        titleLabel.frame = CGRect(x: x, y: 10, width: max(w - x - 10, 0), height: 20)
        chapterLabel.frame = CGRect(x: x, y: 32, width: max(w - x - 10, 0), height: 18)
        percent.frame = CGRect(x: w - 10 - 72, y: 54, width: 72, height: 16)
        bar.frame = CGRect(x: x, y: 59, width: max(percent.frame.minX - x - 8, 10), height: 7)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        Fx.press(card, down: highlighted)
    }
}

// MARK: - Постер в подборке: обложка, название, теги в прямоугольниках

final class PosterCell: UICollectionViewCell {
    static var scale: CGFloat { return Prefs.profile == .tablet ? 1.3 : 1 }
    static var size: CGSize { return CGSize(width: 116 * scale, height: 252 * scale) }

    private let shimmer = ShimmerView()
    private let cover = UIImageView()
    private let titleLabel = UILabel()
    private let lineShimmer = ShimmerView()
    private var chipViews: [PaddedLabel] = []
    private var coverPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(shimmer)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 8
        contentView.addSubview(cover)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        contentView.addSubview(lineShimmer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverPath = nil
        cover.image = nil
        for c in chipViews { c.removeFromSuperview() }
        chipViews = []
        shimmer.stop()
        lineShimmer.stop()
    }

    func configureSkeleton() {
        cover.isHidden = true
        titleLabel.isHidden = true
        shimmer.isHidden = false
        lineShimmer.isHidden = false
        shimmer.start()
        lineShimmer.start()
        setNeedsLayout()
    }

    func configure(_ t: HomeTitle) {
        lineShimmer.isHidden = true
        lineShimmer.stop()
        cover.isHidden = false
        titleLabel.isHidden = false
        titleLabel.textColor = Theme.text
        titleLabel.text = t.ref.name
        shimmer.isHidden = false
        shimmer.start()          // блик крутится, пока обложка не загрузилась

        for c in chipViews { c.removeFromSuperview() }
        chipViews = []
        for (i, text) in t.chips.prefix(2).enumerated() {
            let chip = PaddedLabel.chip(text, accent: i == 0)
            contentView.addSubview(chip)
            chipViews.append(chip)
        }

        coverPath = t.ref.cover
        cover.image = nil
        if let path = t.ref.cover {
            ImageLoader.shared.load(path, site: t.ref.site) { [weak self] img in
                guard let self = self, self.coverPath == path, let img = img else { return }
                self.shimmer.stop()
                self.shimmer.isHidden = true
                Fx.setImage(self.cover, img)
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let k = PosterCell.scale
        let coverFrame = CGRect(x: 0, y: 0, width: w, height: 168 * k)
        shimmer.frame = coverFrame
        cover.frame = coverFrame
        titleLabel.frame = CGRect(x: 0, y: 174 * k, width: w, height: 34 * k)
        lineShimmer.frame = CGRect(x: 0, y: 176 * k, width: w * 0.8, height: 14)
        var y: CGFloat = 212 * k
        for chip in chipViews {
            let s = chip.sizeThatFits(CGSize(width: w, height: 18))
            chip.frame = CGRect(x: 0, y: y, width: min(s.width, w), height: 18)
            y += 22
        }
    }

    override var isHighlighted: Bool {
        didSet { Fx.press(self, down: isHighlighted) }
    }
}

// MARK: - Строка-подборка: горизонтальная лента постеров

final class ShelfCell: UITableViewCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((TitleRef) -> Void)?
    private var titles: [HomeTitle] = []
    private var skeleton = false
    private let collection: UICollectionView
    private let flow: UICollectionViewFlowLayout

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        let layout = UICollectionViewFlowLayout()
        flow = layout
        layout.scrollDirection = .horizontal
        layout.itemSize = PosterCell.size
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceVertical = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(PosterCell.self, forCellWithReuseIdentifier: "poster")
        contentView.addSubview(collection)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        collection.frame = contentView.bounds
    }

    func configure(_ list: [HomeTitle]) {
        flow.itemSize = PosterCell.size
        skeleton = false
        titles = list
        collection.reloadData()
        collection.setContentOffset(.zero, animated: false)
    }

    func configureSkeleton() {
        flow.itemSize = PosterCell.size
        skeleton = true
        titles = []
        collection.reloadData()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return skeleton ? 5 : titles.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "poster", for: ip) as! PosterCell
        if skeleton { cell.configureSkeleton() } else { cell.configure(titles[ip.item]) }
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard !skeleton, titles.indices.contains(ip.item) else { return }
        onSelect?(titles[ip.item].ref)
    }
}

// MARK: - Главная

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section {
        case recent
        case skeleton
        case message(String)
        case shelf(Int)
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refresh = UIRefreshControl()
    private var shelves: [Shelf] = []
    private var sections: [Section] = [.recent]
    private var loading = false
    private var errorText: String?
    private var generation = 0
    private var lastSites = Sites.enabled
    private var loadedOnce = false

    private var recent: [Bookmark] { return Array(ReadingProgress.shared.recent.prefix(4)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Главная"
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.estimatedRowHeight = 0
        if #available(iOS 15.0, *) { tableView.sectionHeaderTopPadding = 0 }   // iOS 15 добавляет лишний отступ над заголовками
        view.addSubview(tableView)

        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        tableView.refreshControl = refresh
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Другие", style: .plain,
                                                           target: self, action: #selector(shuffleTapped))

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()
        rebuild()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyTheme() {
        view.backgroundColor = Theme.background
        tableView.backgroundColor = Theme.background
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !loadedOnce || Sites.enabled != lastSites {
            loadedOnce = true
            lastSites = Sites.enabled
            load()
        } else if let i = sections.firstIndex(where: { if case .recent = $0 { return true } else { return false } }) {
            tableView.reloadSections([i], with: .none)    // прогресс мог измениться в читалке
        }
    }

    @objc private func pulled() { load() }
    @objc private func shuffleTapped() { load() }

    private func rebuild() {
        var s: [Section] = [.recent]
        if loading && shelves.isEmpty {
            s.append(.skeleton)
            s.append(.skeleton)
        } else if let e = errorText, shelves.isEmpty {
            s.append(.message(e))
        } else {
            for i in shelves.indices { s.append(.shelf(i)) }
        }
        sections = s
    }

    private func load() {
        generation += 1
        let gen = generation
        loading = true
        errorText = nil
        rebuild()
        tableView.reloadData()
        HomeLoader.load { [weak self] result in
            guard let self = self, gen == self.generation else { return }
            self.loading = false
            self.refresh.endRefreshing()
            switch result {
            case .success(let list):
                self.shelves = list
                if list.isEmpty { self.errorText = "Подборки пока пусты. Потяните вниз, чтобы повторить." }
            case .failure(let e):
                self.shelves = []
                self.errorText = "Не удалось загрузить подборки.\n\(e.localizedDescription)\nПотяните вниз, чтобы повторить."
            }
            self.rebuild()
            self.tableView.reloadData()
            Fx.cascade(self.tableView.visibleCells)
        }
    }

    // MARK: таблица

    func numberOfSections(in tableView: UITableView) -> Int { return sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if case .recent = sections[section] { return max(recent.count, 1) }
        return 1
    }

    func tableView(_ tableView: UITableView, heightForRowAt ip: IndexPath) -> CGFloat {
        switch sections[ip.section] {
        case .recent: return recent.isEmpty ? 64 : 100
        case .message: return 110
        case .shelf, .skeleton: return PosterCell.size.height + 16
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { return 44 }
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { return 0.01 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header: SectionHeaderView
        switch sections[section] {
        case .recent:
            header = SectionHeaderView(title: "Продолжить чтение", buttonTitle: recent.isEmpty ? nil : "История ›")
            header.onButton = { [weak self] in
                HistoryViewController.preferRecent = true
                self?.tabBarController?.selectedIndex = AppTabs.bookmarks
            }
        case .skeleton:
            header = SectionHeaderView(title: "Подбираю для вас…")
        case .message:
            header = SectionHeaderView(title: "Подборки")
        case .shelf(let i):
            header = SectionHeaderView(title: shelves[i].name)
        }
        header.backgroundColor = Theme.background
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        switch sections[ip.section] {
        case .recent:
            let list = recent
            if list.isEmpty {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.backgroundColor = .clear
                cell.selectionStyle = .none
                cell.textLabel?.numberOfLines = 0
                cell.textLabel?.font = .systemFont(ofSize: 14)
                cell.textLabel?.textColor = Theme.secondary
                cell.textLabel?.text = "Здесь появится ваш прогресс: откройте любую главу — и она будет тут, с процентами."
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "progress") as? ProgressCardCell
                ?? ProgressCardCell(style: .default, reuseIdentifier: "progress")
            cell.configure(list[ip.row])
            return cell

        case .skeleton:
            let cell = tableView.dequeueReusableCell(withIdentifier: "shelf") as? ShelfCell
                ?? ShelfCell(style: .default, reuseIdentifier: "shelf")
            cell.configureSkeleton()
            return cell

        case .message(let text):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.font = .systemFont(ofSize: 14)
            cell.textLabel?.textColor = Theme.secondary
            cell.textLabel?.text = text
            return cell

        case .shelf(let i):
            let cell = tableView.dequeueReusableCell(withIdentifier: "shelf") as? ShelfCell
                ?? ShelfCell(style: .default, reuseIdentifier: "shelf")
            cell.configure(shelves[i].titles)
            cell.onSelect = { [weak self] ref in
                self?.navigationController?.pushViewController(TitleViewController(ref: ref), animated: true)
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        guard case .recent = sections[ip.section] else { return }
        let list = recent
        guard list.indices.contains(ip.row) else { return }
        let b = list[ip.row]
        navigationController?.pushViewController(
            ReaderViewController(title: b.titleRef, chapter: b.chapter, chapters: [], startPage: b.page),
            animated: true)
    }
}
