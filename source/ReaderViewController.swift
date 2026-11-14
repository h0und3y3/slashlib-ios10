import UIKit

// MARK: - Ячейка страницы
// UIScrollView (зум) → container → полосы страницы (UIImageView на каждую).
// Полосы подгружаются только когда попадают в экран (+ запас) и выгружаются, когда уходят далеко.

final class ReaderPageCell: UICollectionViewCell, UIScrollViewDelegate {
    var representedPath: String?
    var onRetry: (() -> Void)?
    var onSingleTap: ((CGFloat) -> Void)?
    var zoomEnabled = false {
        didSet {
            scroll.maximumZoomScale = zoomEnabled ? 3 : 1
            scroll.isScrollEnabled = zoomEnabled
            if !zoomEnabled { scroll.zoomScale = 1 }
        }
    }

    private let scroll = UIScrollView()
    private let container = UIView()
    private var stripViews: [UIImageView] = []
    private var tickets: [Int: StripTicket] = [:]
    private var failed = Set<Int>()
    private var retryCount: [Int: Int] = [:]
    private var source: PageSource?
    private let spinner = ReaderSpinner.make()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lastSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.isScrollEnabled = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        if #available(iOS 11.0, *) { scroll.contentInsetAdjustmentBehavior = .never }
        contentView.addSubview(scroll)
        scroll.addSubview(container)

        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.isHidden = true
        contentView.addSubview(messageLabel)

        retryButton.setTitle("Повторить", for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.layer.borderColor = UIColor.white.cgColor
        retryButton.layer.borderWidth = 1
        retryButton.layer.cornerRadius = 6
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        contentView.addSubview(retryButton)

        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        contentView.addGestureRecognizer(single)
        contentView.addGestureRecognizer(double)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedPath = nil
        onRetry = nil
        onSingleTap = nil
        releaseResources()
        spinner.stopAnimating()
        messageLabel.isHidden = true
        retryButton.isHidden = true
    }

    // Отменяет все незаконченные отрисовки и освобождает картинки.
    func releaseResources() {
        for t in tickets.values { t.cancel() }
        tickets = [:]
        failed = []
        retryCount = [:]
        scroll.zoomScale = 1
        source = nil
        for v in stripViews { v.removeFromSuperview() }
        stripViews = []
        container.frame = .zero
        scroll.contentSize = .zero
    }

    // MARK: состояния

    func showLoading() {
        releaseResources()
        messageLabel.isHidden = true
        retryButton.isHidden = true
        spinner.startAnimating()
        setNeedsLayout()
    }

    func show(source s: PageSource) {
        spinner.stopAnimating()
        messageLabel.isHidden = true
        retryButton.isHidden = true
        releaseResources()
        source = s
        for _ in 0..<s.stripCount {
            let v = UIImageView()
            v.contentMode = .scaleToFill
            v.backgroundColor = UIColor(white: 0.08, alpha: 1)
            container.addSubview(v)
            stripViews.append(v)
        }
        relayout()
        updateVisibleStrips()
    }

    func showFailure(_ text: String) {
        releaseResources()
        spinner.stopAnimating()
        messageLabel.text = text
        messageLabel.isHidden = false
        retryButton.isHidden = false
        setNeedsLayout()
    }

    // MARK: раскладка

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateVisibleStrips()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        if b.size != lastSize {
            lastSize = b.size
            scroll.frame = b
            relayout()
        }
        let cy = min(b.midY, 220)   // у очень высоких ячеек центр может быть за экраном
        spinner.center = CGPoint(x: b.midX, y: cy)
        let w = max(b.width - 40, 10)
        let h = messageLabel.sizeThatFits(CGSize(width: w, height: CGFloat.greatestFiniteMagnitude)).height
        messageLabel.frame = CGRect(x: 20, y: cy - h / 2 - 22, width: w, height: h)
        retryButton.frame = CGRect(x: b.midX - 70, y: messageLabel.frame.maxY + 10, width: 140, height: 36)
        updateVisibleStrips()
    }

    private func relayout() {
        scroll.zoomScale = 1
        guard let s = source, s.srcWidth > 0, s.srcHeight > 0 else {
            container.frame = .zero
            scroll.contentSize = .zero
            return
        }
        let b = scroll.bounds.size
        let ratio = s.srcHeight / s.srcWidth
        let fit: CGFloat
        if !zoomEnabled || ratio > 2.5 {
            fit = b.width / s.srcWidth                              // лента и длинные вебтун-страницы: по ширине
        } else {
            fit = min(b.width / s.srcWidth, b.height / s.srcHeight) // обычная страница целиком
        }
        let size = CGSize(width: (s.srcWidth * fit).rounded(), height: (s.srcHeight * fit).rounded())
        container.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        for (i, v) in stripViews.enumerated() {
            let r = s.srcRect(i)
            let top = (r.minY * fit).rounded(.down)
            let bottom = (r.maxY * fit).rounded(.up)
            v.frame = CGRect(x: 0, y: top, width: size.width, height: bottom - top)
        }
        centerContainer()
    }

    private func centerContainer() {
        let b = scroll.bounds.size
        var f = container.frame
        f.origin.x = f.width < b.width ? (b.width - f.width) / 2 : 0
        f.origin.y = f.height < b.height ? (b.height - f.height) / 2 : 0
        container.frame = f
    }

    // MARK: ленивая подгрузка полос

    func updateVisibleStrips() {
        guard let s = source, let win = window, !stripViews.isEmpty else { return }
        let vis = container.convert(win.bounds, from: win)
        let margin = max(win.bounds.height * 0.6, 300)
        let nearTop = vis.minY - margin
        let nearBottom = vis.maxY + margin
        let farTop = vis.minY - margin * 2.5
        let farBottom = vis.maxY + margin * 2.5

        var toRequest: [Int] = []
        for (i, v) in stripViews.enumerated() {
            let f = v.frame
            if f.maxY >= nearTop && f.minY <= nearBottom {
                if v.image == nil && tickets[i] == nil && !failed.contains(i) {
                    if let hit = StripRenderer.shared.cached(s, i) {
                        v.image = hit
                    } else {
                        toRequest.append(i)
                    }
                }
            } else if f.maxY < farTop || f.minY > farBottom {
                // далеко от экрана — освобождаем память
                if v.image != nil { v.image = nil }
                if let t = tickets[i] {
                    t.cancel()
                    tickets[i] = nil
                }
            }
        }
        // Запрашиваем снизу вверх: очередь обслуживает последний запрос первым, значит верхняя полоса будет первой.
        for i in toRequest.reversed() {
            let t = StripTicket()
            tickets[i] = t
            StripRenderer.shared.request(s, i, ticket: t) { [weak self] img in
                guard let self = self, self.source === s, i < self.stripViews.count else { return }
                self.tickets[i] = nil
                if let img = img {
                    self.stripViews[i].image = img
                } else {
                    // Чаще всего это нехватка памяти в момент декодирования: чистим кэши и пробуем ещё раз (до 3 раз).
                    self.failed.insert(i)
                    self.retryCount[i, default: 0] += 1
                    let attempts = self.retryCount[i] ?? 1
                    Breadcrumbs.shared.log("ОШИБКА: не удалось декодировать полосу \(i + 1)/\(s.stripCount), попытка \(attempts)")
                    StripRenderer.shared.purge()
                    if attempts < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            guard let self = self, self.source === s else { return }
                            self.failed.remove(i)
                            self.updateVisibleStrips()
                        }
                    } else {
                        self.stripViews[i].backgroundColor = UIColor(red: 0.35, green: 0.05, blue: 0.05, alpha: 1)
                    }
                }
            }
        }
    }

    // MARK: зум и жесты

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return container }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContainer()
        updateVisibleStrips()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibleStrips() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateVisibleStrips()
    }

    @objc private func retryTapped() { onRetry?() }

    @objc private func singleTapped(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 { return }
        let x = g.location(in: contentView).x / max(contentView.bounds.width, 1)
        onSingleTap?(x)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard zoomEnabled, source != nil else { return }
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let pt = g.location(in: container)
            let z: CGFloat = 2.5
            let w = scroll.bounds.width / z
            let h = scroll.bounds.height / z
            scroll.zoom(to: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h), animated: true)
        }
    }
}

// MARK: - Читалка

final class ReaderViewController: UIViewController, UICollectionViewDataSource,
                                  UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    private let ref: TitleRef
    private var chapter: Chapter
    private var allChapters: [Chapter]        // по возрастанию номера
    private let needsChapterFetch: Bool
    private var pages: [Page] = []
    private var currentPage = 0
    private var pendingStartPage: Int
    private var heights: [Int: CGFloat] = [:]
    private var mode = Prefs.readMode
    private var loadToken = 0
    private var lastSize = CGSize.zero
    private var progressWork: DispatchWorkItem?

    private let layout = UICollectionViewFlowLayout()
    private var collectionView: UICollectionView!

    private let overlay = UIStackView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let spinner = ReaderSpinner.make()

    private let pageButton = UIButton(type: .system)
    private var bookmarkItem: UIBarButtonItem!
    private var prevItem: UIBarButtonItem!
    private var nextItem: UIBarButtonItem!
    private var modeItem: UIBarButtonItem!

    init(title ref: TitleRef, chapter: Chapter, chapters: [Chapter], startPage: Int) {
        self.ref = ref
        self.chapter = chapter
        // Без сети (или если глав не передали) берём список из скачанных.
        let base = chapters.isEmpty ? DownloadStore.shared.chapters(slug: ref.slug).map { $0.chapter } : chapters
        self.allChapters = Chapter.sortedAscending(base)
        self.needsChapterFetch = chapters.isEmpty
        self.pendingStartPage = startPage
        super.init(nibName: nil, bundle: nil)
        self.title = chapter.shortDisplay
        self.hidesBottomBarWhenPushed = true      // у читалки своя нижняя панель
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        edgesForExtendedLayout = []
        automaticallyAdjustsScrollViewInsets = false

        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.scrollDirection = mode == .scroll ? .vertical : .horizontal

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isPagingEnabled = mode != .scroll
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(ReaderPageCell.self, forCellWithReuseIdentifier: "p")
        if #available(iOS 11.0, *) { collectionView.contentInsetAdjustmentBehavior = .never }
        view.addSubview(collectionView)

        setupOverlay()
        setupBars()

        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
                                               name: Power.didChange, object: nil)
        if needsChapterFetch {
            API.shared.chapters(slug: ref.slug, site: ref.site) { [weak self] result in
                guard let self = self, case .success(let (list, _)) = result else { return }
                self.allChapters = Chapter.sortedAscending(list.data)
                self.updateChrome()
            }
        }
        loadChapter()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        UIApplication.shared.isIdleTimerDisabled = !Power.isSaving   // экран не гаснет во время чтения (кроме энергосбережения)
    }

    @objc private func powerChanged() {
        UIApplication.shared.isIdleTimerDisabled = !Power.isSaving
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        UIApplication.shared.isIdleTimerDisabled = false
        progressWork?.cancel()
        saveProgress()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            loadToken += 1                                    // обнуляем все ожидающие колбэки
            for case let c as ReaderPageCell in collectionView.visibleCells { c.releaseResources() }
            StripRenderer.shared.purge()
            Breadcrumbs.shared.log("читалка закрыта")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = collectionView.bounds.size
        guard s != lastSize else { return }
        let first = lastSize == .zero
        lastSize = s
        layout.invalidateLayout()
        if !first && mode != .scroll {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scrollToPage(self.currentPage, animated: false)
            }
        }
    }

    // MARK: интерфейс

    private func flex() -> UIBarButtonItem {
        return UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    }

    private func setupBars() {
        bookmarkItem = UIBarButtonItem(image: BookmarkIcon.image(filled: false), style: .plain,
                                       target: self, action: #selector(bookmarkTapped))
        navigationItem.rightBarButtonItem = bookmarkItem

        prevItem = UIBarButtonItem(title: "‹ Гл.", style: .plain, target: self, action: #selector(prevChapterTapped))
        nextItem = UIBarButtonItem(title: "Гл. ›", style: .plain, target: self, action: #selector(nextChapterTapped))
        modeItem = UIBarButtonItem(title: mode.shortTitle, style: .plain, target: self, action: #selector(modeTapped))

        // Нажатие на «стр. 3 / 30» — переход на нужную страницу.
        pageButton.frame = CGRect(x: 0, y: 0, width: 104, height: 32)
        pageButton.titleLabel?.font = .systemFont(ofSize: 14)
        pageButton.addTarget(self, action: #selector(goToPageTapped), for: .touchUpInside)
        let pageItem = UIBarButtonItem(customView: pageButton)

        toolbarItems = [prevItem, flex(), pageItem, flex(), modeItem, flex(), nextItem]
    }

    private func setupOverlay() {
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)

        retryButton.setTitle("Повторить", for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.layer.borderColor = UIColor.white.cgColor
        retryButton.layer.borderWidth = 1
        retryButton.layer.cornerRadius = 6
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        overlay.axis = .vertical
        overlay.alignment = .center
        overlay.spacing = 16
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addArrangedSubview(spinner)
        overlay.addArrangedSubview(statusLabel)
        overlay.addArrangedSubview(retryButton)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func showLoading() {
        overlay.isHidden = false
        spinner.startAnimating()
        statusLabel.text = "Загрузка главы…"
        retryButton.isHidden = true
    }

    private func showMessage(_ text: String) {
        overlay.isHidden = false
        spinner.stopAnimating()
        statusLabel.text = text
        retryButton.isHidden = false
    }

    private func hideOverlay() {
        spinner.stopAnimating()
        overlay.isHidden = true
    }

    private func toast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor(white: 0, alpha: 0.8)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        let maxW = max(view.bounds.width - 64, 80)
        let s = label.sizeThatFits(CGSize(width: maxW, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: 0, y: 0, width: min(s.width, maxW) + 24, height: s.height + 14)
        label.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - 44)
        label.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin]
        view.addSubview(label)
        if !Fx.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { label.removeFromSuperview() }
            return
        }
        label.alpha = 0
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    private func updateChrome() {
        let text = pages.isEmpty ? " " : "стр. \(currentPage + 1) / \(pages.count)"
        UIView.performWithoutAnimation {
            pageButton.setTitle(text, for: .normal)
            pageButton.layoutIfNeeded()
        }
        pageButton.isEnabled = !pages.isEmpty
        let marked = BookmarkStore.shared.bookmark(slug: ref.slug, chapterId: chapter.id)?.page == currentPage
        bookmarkItem.image = BookmarkIcon.image(filled: marked && !pages.isEmpty)
        prevItem.isEnabled = neighbor(-1) != nil
        nextItem.isEnabled = neighbor(1) != nil
        modeItem.title = mode.shortTitle
        title = chapter.shortDisplay
        if mode != .scroll { prefetch(around: currentPage) }
    }

    // MARK: загрузка главы

    private func loadChapter() {
        loadToken += 1
        let token = loadToken
        pages = []
        heights = [:]
        collectionView.reloadData()
        showLoading()
        updateChrome()
        Breadcrumbs.shared.log("открываю главу: \(ref.name) · \(chapter.shortDisplay)")

        let handle: (Result<[Page], Error>) -> Void = { [weak self] result in
            guard let self = self, token == self.loadToken else { return }
            switch result {
            case .success(let pages):
                Breadcrumbs.shared.log("в главе страниц: \(pages.count)")
                self.pages = pages
                self.hideOverlay()
                self.collectionView.reloadData()
                self.collectionView.layoutIfNeeded()
                let start = min(max(self.pendingStartPage, 0), pages.count - 1)
                self.pendingStartPage = 0
                self.currentPage = start
                self.scrollToPage(start, animated: false)
                self.updateChrome()
                self.scheduleProgressSave()
                if start > 0 { self.toast("Открыто на стр. \(start + 1)") }
            case .failure(let e):
                Breadcrumbs.shared.log("ОШИБКА главы: \(e.localizedDescription)")
                self.showMessage(e.localizedDescription)
            }
        }

        if let saved = DownloadStore.shared.downloaded(slug: ref.slug, chapterId: chapter.id) {
            Breadcrumbs.shared.log("читаю скачанную главу (без сети)")
            let pages = saved.pageList
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handle(.success(pages)) }
        } else {
            API.shared.pages(slug: ref.slug, chapter: chapter, site: ref.site, done: handle)
        }
    }

    @objc private func retryTapped() { loadChapter() }

    private func openChapter(_ c: Chapter, startPage: Int) {
        progressWork?.cancel()
        saveProgress()
        chapter = c
        pendingStartPage = startPage
        currentPage = 0
        loadChapter()
    }

    private func neighbor(_ delta: Int) -> Chapter? {
        guard let i = allChapters.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        let j = i + delta
        return allChapters.indices.contains(j) ? allChapters[j] : nil
    }

    private func savedPage(for c: Chapter) -> Int {
        return BookmarkStore.shared.bookmark(slug: ref.slug, chapterId: c.id)?.page ?? 0
    }

    @objc private func nextChapterTapped() {
        guard let n = neighbor(1) else { return }
        openChapter(n, startPage: savedPage(for: n))
    }

    @objc private func prevChapterTapped() {
        guard let p = neighbor(-1) else { return }
        openChapter(p, startPage: savedPage(for: p))
    }

    // MARK: прогресс чтения

    private func makeBookmark() -> Bookmark {
        return Bookmark(id: UUID().uuidString,
                        slug: ref.slug,
                        titleName: ref.name,
                        cover: ref.cover,
                        site: ref.site,
                        chapterId: chapter.id,
                        volume: chapter.volume,
                        number: chapter.number,
                        chapterName: chapter.name,
                        branchIds: chapter.branchIds,
                        page: currentPage,
                        pageCount: pages.count,
                        date: Date())
    }

    private func scheduleProgressSave() {
        progressWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveProgress() }
        progressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    private func saveProgress() {
        guard !pages.isEmpty else { return }
        ReadingProgress.shared.save(makeBookmark())
        if currentPage >= pages.count - 1 {
            ReadingProgress.shared.markRead(slug: ref.slug, chapterId: chapter.id)
        }
    }

    // MARK: закладки

    @objc private func bookmarkTapped() {
        guard !pages.isEmpty else { return }
        let store = BookmarkStore.shared
        if let existing = store.bookmark(slug: ref.slug, chapterId: chapter.id), existing.page == currentPage {
            store.remove(id: existing.id)
            toast("Закладка убрана")
        } else {
            store.set(makeBookmark())
            toast("Закладка: стр. \(currentPage + 1) из \(pages.count)")
        }
        updateChrome()
    }

    // MARK: переход на страницу

    @objc private func goToPageTapped() {
        guard !pages.isEmpty else { return }
        let alert = UIAlertController(title: "Перейти на страницу",
                                      message: "От 1 до \(pages.count)", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.placeholder = "\(self.currentPage + 1)"
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Перейти", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let n = Int(alert?.textFields?.first?.text ?? "") else { return }
            self.scrollToPage(n - 1, animated: false)
        })
        present(alert, animated: true)
    }

    // MARK: режимы чтения

    @objc private func modeTapped() {
        let sheet = UIAlertController(title: "Режим чтения", message: nil, preferredStyle: .actionSheet)
        for m in [ReadMode.scroll, ReadMode.pagedLTR, ReadMode.pagedRTL] {
            let name = m.fullTitle + (m == mode ? "  ✓" : "")
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                Prefs.readMode = m
                self?.applyMode()
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = modeItem
        present(sheet, animated: true)
    }

    private func applyMode() {
        let page = currentPage
        mode = Prefs.readMode
        layout.scrollDirection = mode == .scroll ? .vertical : .horizontal
        collectionView.isPagingEnabled = mode != .scroll
        collectionView.reloadData()
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        scrollToPage(page, animated: false)
        currentPage = page
        updateChrome()
    }

    // В режиме «справа налево» элементы идут в обратном порядке (функция сама себе обратна).
    private func page(forItem i: Int) -> Int {
        return mode == .pagedRTL ? pages.count - 1 - i : i
    }

    private func scrollToPage(_ p: Int, animated: Bool) {
        guard !pages.isEmpty else { return }
        let target = min(max(p, 0), pages.count - 1)
        let item = page(forItem: target)
        if mode == .scroll {
            collectionView.scrollToItem(at: IndexPath(item: item, section: 0), at: .top, animated: animated)
        } else {
            collectionView.setContentOffset(
                CGPoint(x: CGFloat(item) * collectionView.bounds.width, y: 0), animated: animated)
        }
    }

    // MARK: перелистывание

    private func handleTap(_ fraction: CGFloat) {
        guard mode != .scroll, !pages.isEmpty else { return }
        let rtl = mode == .pagedRTL
        if fraction < 0.3 { turn(rtl ? 1 : -1) }
        else if fraction > 0.7 { turn(rtl ? -1 : 1) }
    }

    private func turn(_ delta: Int) {
        let target = currentPage + delta
        if target >= pages.count {
            if let n = neighbor(1) { openChapter(n, startPage: savedPage(for: n)) }
            else { toast("Это последняя глава") }
        } else if target < 0 {
            if let p = neighbor(-1) { openChapter(p, startPage: Int.max) }
            else { toast("Это первая глава") }
        } else {
            scrollToPage(target, animated: true)
        }
    }

    // Заранее скачиваем (в файл, это почти бесплатно по памяти) пару следующих страниц.
    private func prefetch(around page: Int) {
        let count = Power.isSaving ? 1 : 2
        for p in (page + 1)...(page + count) where pages.indices.contains(p) {
            ImageLoader.shared.loadPage(pages[p].url, site: ref.site) { _ in }
        }
    }

    // MARK: коллекция

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return pages.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "p", for: ip) as! ReaderPageCell
        cell.zoomEnabled = mode != .scroll
        cell.onSingleTap = { [weak self] x in self?.handleTap(x) }
        bind(cell, page: page(forItem: ip.item))
        return cell
    }

    private func bind(_ cell: ReaderPageCell, page: Int) {
        guard pages.indices.contains(page) else { return }
        let path = pages[page].url
        let token = loadToken
        cell.representedPath = path
        cell.onRetry = { [weak self, weak cell] in
            guard let self = self, let cell = cell else { return }
            self.bind(cell, page: page)
        }

        if let hit = ImageLoader.shared.cachedSource(path) {
            cell.show(source: hit)
            // layout.invalidateLayout() нельзя вызывать прямо во время cellForItemAt — откладываем.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, token == self.loadToken else { return }
                self.adjustHeight(page: page, source: hit)
            }
            return
        }

        cell.showLoading()
        ImageLoader.shared.loadPage(path, site: ref.site) { [weak self, weak cell] result in
            guard let self = self, token == self.loadToken else { return }   // глава уже сменилась
            guard let cell = cell, cell.representedPath == path else { return }
            switch result {
            case .success(let src):
                cell.show(source: src)
                self.adjustHeight(page: page, source: src)
            case .failure(let e):
                cell.showFailure("Не удалось загрузить страницу \(page + 1)\n\(e.localizedDescription)")
            }
        }
    }

    private func adjustHeight(page: Int, source: PageSource) {
        guard mode == .scroll, source.srcWidth > 0 else { return }
        let h = (collectionView.bounds.width * source.srcHeight / source.srcWidth).rounded()
        if abs((heights[page] ?? 0) - h) > 1 {
            heights[page] = h
            layout.invalidateLayout()
        }
    }

    private func estimatedHeight(_ p: Int, width: CGFloat) -> CGFloat {
        if let h = heights[p] { return h }
        if pages.indices.contains(p), let w = pages[p].width, let h = pages[p].height, w > 0, h > 0 {
            return (width * CGFloat(h) / CGFloat(w)).rounded()
        }
        return (width * 1.4).rounded()
    }

    func collectionView(_ cv: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        let b = cv.bounds.size
        if mode != .scroll { return b }
        return CGSize(width: b.width, height: estimatedHeight(page(forItem: ip.item), width: b.width))
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Не больше трёх за раз, чтобы не забивать сеть страницами, до которых пользователь не дойдёт.
        if Power.isSaving { return }
        for ip in indexPaths.prefix(3) {
            let p = page(forItem: ip.item)
            if pages.indices.contains(p) { ImageLoader.shared.loadPage(pages[p].url, site: ref.site) { _ in } }
        }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv === collectionView, !pages.isEmpty else { return }
        for case let c as ReaderPageCell in collectionView.visibleCells { c.updateVisibleStrips() }

        let item: Int
        if mode == .scroll {
            let probe = CGPoint(x: sv.bounds.midX, y: sv.contentOffset.y + sv.bounds.height * 0.25)
            item = collectionView.indexPathForItem(at: probe)?.item
                ?? collectionView.indexPathsForVisibleItems.map { $0.item }.min()
                ?? 0
        } else {
            let w = max(sv.bounds.width, 1)
            item = min(max(Int((sv.contentOffset.x / w).rounded()), 0), pages.count - 1)
        }
        let p = min(max(page(forItem: item), 0), pages.count - 1)
        if p != currentPage {
            currentPage = p
            updateChrome()
            scheduleProgressSave()
        }
    }
}

// Спиннер без указания стиля: init(activityIndicatorStyle:) в новом SDK удалён,
// а init(style:) требует iOS 13. Цвет задаём явно — он работает при любом стиле.
enum ReaderSpinner {
    static func make() -> UIActivityIndicatorView {
        let s = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        s.color = .white
        return s
    }
}
