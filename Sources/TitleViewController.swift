import UIKit

// Шапка с обложкой: высота подстраивается под прокрутку списка и сворачивается до нуля.
final class TitleHeaderView: UIView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        clipsToBounds = true
        isUserInteractionEnabled = false      // касания и жесты достаются таблице под шапкой
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // insetBy с отрицательным результатом даёт CGRect.null и ломает раскладку — считаем вручную.
        let pad = min(10, bounds.height / 2)
        imageView.frame = CGRect(x: 0, y: pad, width: bounds.width, height: max(bounds.height - pad * 2, 0))
    }
}

// Экран тайтла: сверху сворачивающаяся обложка, ниже «О тайтле» и выбор главы.
final class TitleViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum AboutRow { case name, meta, summary, action }

    private var ref: TitleRef          // site может уточниться после загрузки глав
    private let starButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let headerView = TitleHeaderView()
    private var headerMax: CGFloat = 280
    private var didInitialOffset = false

    private var baseChapters: [Chapter] = []     // по возрастанию
    private var chapters: [Chapter] = []         // в порядке показа
    private var loadingChapters = true
    private var offline = false

    private var details: TitleDetails?
    private var aboutRows: [AboutRow] = [.name, .action]
    private var summaryExpanded = false
    private var loadedCoverPath: String?

    private var favoriteItem: UIBarButtonItem!
    private var menuItem: UIBarButtonItem!
    private var reloadScheduled = false

    init(ref: TitleRef) {
        self.ref = ref
        super.init(nibName: nil, bundle: nil)
        title = ref.name
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        automaticallyAdjustsScrollViewInsets = false

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 56
        tableView.rowHeight = UITableView.automaticDimension
        tableView.cellLayoutMarginsFollowReadableWidth = true
        if #available(iOS 11.0, *) { tableView.contentInsetAdjustmentBehavior = .never }
        view.addSubview(tableView)
        view.addSubview(headerView)

        headerMax = computeHeaderMax()
        tableView.contentInset = UIEdgeInsets(top: headerMax, left: 0, bottom: 0, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
        tableView.contentOffset = CGPoint(x: 0, y: -headerMax)
        updateHeader()

        starButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        starButton.addTarget(self, action: #selector(favoriteTapped), for: .touchUpInside)
        favoriteItem = UIBarButtonItem(customView: starButton)
        menuItem = UIBarButtonItem(title: "Загрузки", style: .plain, target: self, action: #selector(menuTapped))
        navigationItem.rightBarButtonItems = [favoriteItem, menuItem]
        updateFavoriteIcon()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(downloadsChanged), name: DownloadManager.didChange, object: nil)
        nc.addObserver(self, selector: #selector(downloadsChanged), name: DownloadStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(updateFavoriteIcon), name: FavoritesStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()

        if let c = ref.cover { loadHeaderImage(c) }
        loadDetails()
        loadChapters()
    }

    @objc private func applyTheme() {
        view.backgroundColor = Theme.background
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = Theme.separator
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()     // отметки закладок и прочитанного могли измениться в читалке
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let newMax = computeHeaderMax()
        if abs(newMax - headerMax) > 0.5 || !didInitialOffset {
            let atTop = !didInitialOffset || tableView.contentOffset.y <= -headerMax + 1
            headerMax = newMax
            var inset = tableView.contentInset
            inset.top = newMax
            tableView.contentInset = inset
            tableView.scrollIndicatorInsets = inset
            if atTop { tableView.contentOffset = CGPoint(x: 0, y: -newMax) }
            didInitialOffset = true
        }
        updateHeader()
    }

    private func computeHeaderMax() -> CGFloat {
        let h = view.bounds.height
        return min(320, max(120, (h * 0.36).rounded()))
    }

    private func updateHeader() {
        let h = max(0, -tableView.contentOffset.y)
        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: h)
        headerView.alpha = headerMax > 0 ? min(1, h / (headerMax * 0.5)) : 1
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === tableView { updateHeader() }
    }

    // MARK: загрузка данных

    private func loadHeaderImage(_ path: String) {
        guard loadedCoverPath != path else { return }
        loadedCoverPath = path
        ImageLoader.shared.load(path, site: ref.site) { [weak self] img in
            guard let self = self, let img = img else { return }
            Fx.setImage(self.headerView.imageView, img)
        }
    }

    private func loadDetails() {
        API.shared.titleDetails(slug: ref.slug, site: ref.site) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let d):
                self.details = d
                self.rebuildAbout()
                self.tableView.reloadSections([0], with: .none)
                if let c = d.cover { self.loadHeaderImage(c) }
            case .failure(let e):
                Breadcrumbs.shared.log("описание тайтла не загрузилось: \(e.localizedDescription)")
            }
        }
    }

    private func loadChapters() {
        loadingChapters = true
        tableView.reloadSections([1], with: .none)
        API.shared.chapters(slug: ref.slug, site: ref.site) { [weak self] result in
            guard let self = self else { return }
            self.loadingChapters = false
            switch result {
            case .success(let (list, resolved)):
                self.offline = false
                self.baseChapters = Chapter.sortedAscending(list.data)
                // Узнали, на каком сайте лежит тайтл, — запоминаем (нужно для страниц и картинок).
                if self.ref.site == nil, let site = resolved, Prefs.mangalibEnabled {
                    self.ref = TitleRef(slug: self.ref.slug, name: self.ref.name, cover: self.ref.cover, site: site)
                }
            case .failure(let e):
                let saved = DownloadStore.shared.chapters(slug: self.ref.slug).map { $0.chapter }
                if saved.isEmpty {
                    self.baseChapters = []
                    self.showError(e)
                } else {
                    // Нет сети (или сервер недоступен): показываем скачанные главы.
                    self.offline = true
                    self.baseChapters = Chapter.sortedAscending(saved)
                }
            }
            self.applyOrder()
            self.tableView.reloadData()
        }
    }

    private func applyOrder() {
        chapters = Prefs.chaptersDescending ? Array(baseChapters.reversed()) : baseChapters
    }

    // MARK: блок «О тайтле»

    private func metaText(_ d: TitleDetails) -> String? {
        var lines: [String] = []
        if let v = d.type { lines.append("Тип: \(v)") }
        if let v = d.status { lines.append("Статус: \(v)") }
        if let v = d.year { lines.append("Год: \(v)") }
        if let v = d.age { lines.append("Возраст: \(v)") }
        if let v = d.rating { lines.append("Рейтинг: \(v)") }
        if !d.genres.isEmpty { lines.append("Жанры: " + d.genres.joined(separator: ", ")) }
        if !d.tags.isEmpty { lines.append("Теги: " + d.tags.prefix(12).joined(separator: ", ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func rebuildAbout() {
        var rows: [AboutRow] = [.name]
        if let d = details, metaText(d) != nil { rows.append(.meta) }
        if let s = details?.summary, !s.isEmpty { rows.append(.summary) }
        rows.append(.action)
        aboutRows = rows
    }

    private func resumePoint() -> Bookmark? {
        return ReadingProgress.shared.last(slug: ref.slug) ?? BookmarkStore.shared.bookmarks(slug: ref.slug).first
    }

    // Страница, с которой открывать главу: закладка, иначе недочитанное место, иначе начало.
    private func startPage(for c: Chapter) -> Int {
        if let b = BookmarkStore.shared.bookmark(slug: ref.slug, chapterId: c.id) { return b.page }
        if let r = ReadingProgress.shared.last(slug: ref.slug), r.chapterId == c.id, r.page < r.pageCount - 1 {
            return r.page
        }
        return 0
    }

    private func open(_ chapter: Chapter, page: Int) {
        navigationController?.pushViewController(
            ReaderViewController(title: ref, chapter: chapter, chapters: baseChapters, startPage: page),
            animated: true)
    }

    private func resumeOrStart() {
        if let b = resumePoint() {
            open(b.chapter, page: b.page)
        } else if let first = baseChapters.first {
            open(first, page: startPage(for: first))
        } else {
            let a = UIAlertController(title: nil, message: "Список глав ещё не загружен.", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        }
    }

    // MARK: избранное

    @objc private func updateFavoriteIcon() {
        starButton.setImage(StarIcon.image(filled: FavoritesStore.shared.isFavorite(ref.slug), size: 26), for: .normal)
    }

    @objc private func favoriteTapped() {
        FavoritesStore.shared.toggle(ref)
        updateFavoriteIcon()
        Fx.pop(starButton)
    }

    // MARK: загрузки и меню

    @objc private func downloadsChanged() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.reloadScheduled = false
            guard !self.chapters.isEmpty else { return }
            let visible = (self.tableView.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }
            if !visible.isEmpty { self.tableView.reloadRows(at: visible, with: .none) }
        }
    }

    private func downloadText(_ c: Chapter) -> String? {
        if DownloadStore.shared.isDownloaded(slug: ref.slug, chapterId: c.id) { return "Скачано" }
        if let j = DownloadManager.shared.job(slug: ref.slug, chapterId: c.id) {
            switch j.state {
            case .queued: return "В очереди"
            case .running(let d, let t): return t > 0 ? "Скачивается \(d)/\(t)" : "Скачивается…"
            case .failed(let m): return "Ошибка: " + String(m.prefix(40))
            }
        }
        return nil
    }

    @objc private func menuTapped() {
        let sheet = UIAlertController(title: ref.name, message: nil, preferredStyle: .actionSheet)
        let unread = baseChapters.filter { !ReadingProgress.shared.isRead(slug: ref.slug, chapterId: $0.id) }

        if !unread.isEmpty {
            sheet.addAction(UIAlertAction(title: "Скачать непрочитанные (\(unread.count))", style: .default) { [weak self] _ in
                self?.confirmDownload(unread)
            })
        }
        if !baseChapters.isEmpty {
            sheet.addAction(UIAlertAction(title: "Скачать все главы (\(baseChapters.count))", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.confirmDownload(self.baseChapters)
            })
        }
        if DownloadManager.shared.jobs.contains(where: { $0.ref.slug == ref.slug }) {
            sheet.addAction(UIAlertAction(title: "Отменить текущие загрузки", style: .default) { [weak self] _ in
                guard let self = self else { return }
                DownloadManager.shared.cancelAll(slug: self.ref.slug)
            })
        }
        if !DownloadStore.shared.chapters(slug: ref.slug).isEmpty {
            sheet.addAction(UIAlertAction(title: "Удалить скачанные главы", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                DownloadStore.shared.removeAll(slug: self.ref.slug)
            })
        }
        let orderTitle = Prefs.chaptersDescending ? "Сначала старые главы" : "Сначала новые главы"
        sheet.addAction(UIAlertAction(title: orderTitle, style: .default) { [weak self] _ in
            Prefs.chaptersDescending = !Prefs.chaptersDescending
            self?.applyOrder()
            self?.tableView.reloadSections([1], with: .none)
        })
        sheet.addAction(UIAlertAction(title: "Обновить список глав", style: .default) { [weak self] _ in
            self?.loadDetails()
            self?.loadChapters()
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = menuItem
        present(sheet, animated: true)
    }

    private func confirmDownload(_ list: [Chapter]) {
        guard !list.isEmpty else { return }
        if list.count <= 30 {
            DownloadManager.shared.enqueue(ref: ref, chapters: list)
            return
        }
        let a = UIAlertController(title: "Скачать \(list.count) глав?",
                                  message: "Это может занять много места и времени. Загрузка идёт по одной главе.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        a.addAction(UIAlertAction(title: "Скачать", style: .default) { [weak self] _ in
            guard let self = self else { return }
            DownloadManager.shared.enqueue(ref: self.ref, chapters: list)
        })
        present(a, animated: true)
    }

    // MARK: таблица

    private var placeholderText: String? {
        if loadingChapters && chapters.isEmpty { return "Загрузка глав…" }
        if chapters.isEmpty { return "Глав не найдено" }
        return nil
    }

    func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return aboutRows.count }
        return placeholderText == nil ? chapters.count : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "О тайтле" }
        var t = chapters.isEmpty ? "Главы" : "Главы (\(chapters.count))"
        if offline { t += " · нет сети, показаны скачанные" }
        return t
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { return 0.01 }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = Theme.secondary
    }

    func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "c")
        // Ячейки переиспользуются между разными типами строк — всё сбрасываем явно.
        Theme.styleCell(cell)
        cell.textLabel?.font = .systemFont(ofSize: 16)
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.font = .systemFont(ofSize: 13)
        cell.detailTextLabel?.numberOfLines = 1
        cell.detailTextLabel?.text = nil
        cell.selectionStyle = .default
        cell.accessoryType = .none

        if ip.section == 0 {
            configureAbout(cell, aboutRows[ip.row])
            return cell
        }
        if let text = placeholderText {
            cell.textLabel?.text = text
            cell.textLabel?.textColor = Theme.secondary
            cell.selectionStyle = .none
            return cell
        }

        let c = chapters[ip.row]
        let isRead = ReadingProgress.shared.isRead(slug: ref.slug, chapterId: c.id)
        cell.textLabel?.text = (isRead ? "✓ " : "") + c.display
        cell.textLabel?.textColor = isRead ? Theme.secondary : Theme.text
        var parts: [String] = []
        if let b = BookmarkStore.shared.bookmark(slug: ref.slug, chapterId: c.id) {
            parts.append("🔖 стр. \(b.page + 1)")
        }
        if let d = downloadText(c) { parts.append(d) }
        cell.detailTextLabel?.text = parts.isEmpty ? nil : parts.joined(separator: " · ")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func configureAbout(_ cell: UITableViewCell, _ row: AboutRow) {
        cell.textLabel?.numberOfLines = 0
        switch row {
        case .name:
            cell.textLabel?.text = ref.name
            cell.textLabel?.font = .boldSystemFont(ofSize: 20)
            cell.selectionStyle = .none
        case .meta:
            cell.textLabel?.text = details.flatMap { metaText($0) }
            cell.textLabel?.font = .systemFont(ofSize: 14)
            cell.textLabel?.textColor = Theme.secondary
            cell.selectionStyle = .none
        case .summary:
            cell.textLabel?.text = details?.summary
            cell.textLabel?.font = .systemFont(ofSize: 15)
            cell.textLabel?.numberOfLines = summaryExpanded ? 0 : 6
            cell.detailTextLabel?.text = summaryExpanded ? "Свернуть" : "Показать полностью"
            cell.detailTextLabel?.textColor = view.tintColor
        case .action:
            let point = resumePoint()
            cell.textLabel?.text = point == nil ? "▶  Начать читать" : "▶  Продолжить чтение"
            cell.textLabel?.font = .boldSystemFont(ofSize: 17)
            cell.textLabel?.textColor = view.tintColor
            if let p = point {
                cell.detailTextLabel?.text = "\(p.chapter.shortDisplay), стр. \(p.page + 1)"
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        if ip.section == 0 {
            switch aboutRows[ip.row] {
            case .summary:
                summaryExpanded = !summaryExpanded
                tableView.reloadRows(at: [ip], with: .none)
            case .action:
                resumeOrStart()
            default:
                break
            }
            return
        }
        guard placeholderText == nil, chapters.indices.contains(ip.row) else { return }
        let c = chapters[ip.row]
        open(c, page: startPage(for: c))
    }

    func tableView(_ tableView: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        return ip.section == 1 && placeholderText == nil
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt ip: IndexPath) -> [UITableViewRowAction]? {
        guard ip.section == 1, placeholderText == nil, chapters.indices.contains(ip.row) else { return nil }
        let c = chapters[ip.row]
        let slug = ref.slug

        if DownloadStore.shared.isDownloaded(slug: slug, chapterId: c.id) {
            let del = UITableViewRowAction(style: .destructive, title: "Удалить") { _, _ in
                DownloadStore.shared.remove(slug: slug, chapterId: c.id)
            }
            return [del]
        }
        if DownloadManager.shared.job(slug: slug, chapterId: c.id) != nil {
            let cancel = UITableViewRowAction(style: .destructive, title: "Отменить") { _, _ in
                DownloadManager.shared.cancel(slug: slug, chapterId: c.id)
            }
            return [cancel]
        }
        let get = UITableViewRowAction(style: .normal, title: "Скачать") { [weak self] _, _ in
            guard let self = self else { return }
            DownloadManager.shared.enqueue(ref: self.ref, chapters: [c])
            self.tableView.setEditing(false, animated: true)
        }
        get.backgroundColor = view.tintColor
        return [get]
    }
}
