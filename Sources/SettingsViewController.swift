import UIKit
import SafariServices

// Вкладка «Аккаунт»: вход, внешний вид, источники, энергосбережение, загрузки и кэш, диагностика.
final class SettingsViewController: UIViewController {
    private let status = UILabel()
    private let tokenView = UITextView()
    private let cacheLabel = UILabel()
    private let downloadsLabel = UILabel()
    private let powerSwitch = UISwitch()
    private let followSwitch = UISwitch()
    private let fancySwitch = UISwitch()
    private let mangalibSwitch = UISwitch()
    private let themeControl = UISegmentedControl(items: [ThemeMode.light.title, ThemeMode.dark.title, ThemeMode.auto.title])
    private var swatches: [UIButton] = []
    private var primaryLabels: [UILabel] = []
    private var secondaryLabels: [UILabel] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Аккаунт"

        // --- вход ---
        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 15)
        primaryLabels.append(status)

        let hint = smallLabel("Вставьте токен (Bearer) из вашего аккаунта на сайте. Взять его можно в браузере на ПК: DevTools → Network → любой запрос к api.lib.social → заголовок Authorization.")

        tokenView.layer.borderWidth = 1
        tokenView.layer.cornerRadius = 6
        tokenView.font = .systemFont(ofSize: 13)
        tokenView.autocapitalizationType = .none
        tokenView.autocorrectionType = .no
        tokenView.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let paste = button("Вставить из буфера", #selector(pasteTapped))
        let save = button("Сохранить токен", #selector(saveTapped))
        let register = button("Регистрация на сайте", #selector(registerTapped))
        let logout = button("Выйти", #selector(logoutTapped))
        logout.setTitleColor(.red, for: .normal)

        // --- внешний вид ---
        themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)

        let swatchRow = UIStackView()
        swatchRow.axis = .horizontal
        swatchRow.distribution = .equalSpacing
        swatchRow.alignment = .center
        for (i, item) in Theme.palette.enumerated() {
            let b = UIButton(type: .custom)
            b.tag = i
            b.backgroundColor = item.color
            b.layer.cornerRadius = 16
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            swatchRow.addArrangedSubview(b)
            swatches.append(b)
        }

        fancySwitch.addTarget(self, action: #selector(fancyChanged), for: .valueChanged)
        let fancyRow = switchRow("Анимации и украшения", fancySwitch)
        let fancyHint = smallLabel("Плавное появление списков, блики при загрузке, цветные полоски у заголовков, тени карточек, анимация звезды и переключения вкладок. Один рычаг отключает всё это. В режиме энергосбережения украшения выключаются сами.")

        // --- источники ---
        mangalibSwitch.addTarget(self, action: #selector(mangalibChanged), for: .valueChanged)
        let mangalibRow = switchRow("Тайтлы MangaLib", mangalibSwitch)
        let mangalibHint = smallLabel("Добавляет каталог MangaLib в поиск и подборки (тот же API, другой сайт сети). Работает по моим данным о API и на живом сервере не проверялось; для 18+ нужен токен.")

        // --- энергосбережение ---
        powerSwitch.addTarget(self, action: #selector(powerChanged), for: .valueChanged)
        followSwitch.addTarget(self, action: #selector(followChanged), for: .valueChanged)
        let powerRow = switchRow("Энергосбережение", powerSwitch)
        let followRow = switchRow("Включать вместе с режимом iOS", followSwitch)
        let powerHint = smallLabel("Меньше разрешение и качество картинок, нет предзагрузки страниц, без анимаций, экран может гаснуть во время чтения, загрузка глав в один поток.")

        // --- загрузки и кэш ---
        downloadsLabel.numberOfLines = 0
        downloadsLabel.font = .systemFont(ofSize: 13)
        secondaryLabels.append(downloadsLabel)
        let manage = button("Управление загрузками", #selector(downloadsTapped))
        cacheLabel.numberOfLines = 0
        cacheLabel.font = .systemFont(ofSize: 13)
        secondaryLabels.append(cacheLabel)
        let clear = button("Очистить кэш страниц", #selector(clearCacheTapped))
        let diag = button("Диагностика и журнал ошибок", #selector(diagnosticsTapped))

        let stack = UIStackView(arrangedSubviews: [
            heading("Вход"), status, hint, tokenView, paste, save, register, logout,
            heading("Внешний вид"), themeControl, swatchRow, fancyRow, fancyHint,
            heading("Источники"), mangalibRow, mangalibHint,
            heading("Энергосбережение"), powerRow, followRow, powerHint,
            heading("Загрузки"), downloadsLabel, manage,
            heading("Кэш"), cacheLabel, clear,
            heading("Для разработчика"), diag
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Прокрутка: на маленьких экранах все пункты не помещаются.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        content.addSubview(stack)

        // На iPad колонка не растягивается шире 560 pt и стоит по центру.
        let preferredWidth = stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32)
        preferredWidth.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topLayoutGuide.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.widthAnchor.constraint(equalTo: view.widthAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            preferredWidth
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
        refreshSwitches()
        refreshSwatches()
        refreshDownloads()
        refreshCacheInfo()
    }

    @objc private func applyTheme() {
        view.backgroundColor = Theme.background
        for l in primaryLabels { l.textColor = Theme.text }
        for l in secondaryLabels { l.textColor = Theme.secondary }
        tokenView.backgroundColor = Theme.card
        tokenView.textColor = Theme.text
        tokenView.layer.borderColor = Theme.separator.cgColor
        tokenView.keyboardAppearance = Theme.isDark ? .dark : .default
        refreshSwatches()
    }

    // MARK: конструкторы элементов

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func heading(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text.uppercased()
        l.font = .boldSystemFont(ofSize: 12)
        secondaryLabels.append(l)
        return l
    }

    private func smallLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 13)
        l.text = text
        secondaryLabels.append(l)
        return l
    }

    private func switchRow(_ text: String, _ sw: UISwitch) -> UIStackView {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15)
        primaryLabels.append(l)
        let row = UIStackView(arrangedSubviews: [l, sw])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    // MARK: обновление интерфейса

    private func refreshStatus() {
        status.text = AuthStore.token == nil ? "Не выполнен вход" : "Токен сохранён"
    }

    private func refreshSwitches() {
        powerSwitch.isOn = Prefs.powerSaving
        followSwitch.isOn = Prefs.powerFollowsSystem
        fancySwitch.isOn = Prefs.fancy
        mangalibSwitch.isOn = Prefs.mangalibEnabled
        themeControl.selectedSegmentIndex = Prefs.themeMode.rawValue
    }

    private func refreshSwatches() {
        for b in swatches {
            b.layer.borderColor = Theme.text.cgColor
            b.layer.borderWidth = b.tag == Prefs.accentIndex ? 3 : 0
        }
    }

    private func refreshDownloads() {
        let store = DownloadStore.shared
        let size = ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)
        let queued = DownloadManager.shared.jobs.count
        downloadsLabel.text = "Скачано глав: \(store.count) (\(size))" + (queued > 0 ? ", в очереди: \(queued)" : "")
    }

    private func refreshCacheInfo() {
        cacheLabel.text = "Кэш страниц: считаю…"
        DispatchQueue.global(qos: .utility).async {
            let bytes = PageFiles.totalSize()
            DispatchQueue.main.async { [weak self] in
                let mb = Double(bytes) / 1_048_576
                self?.cacheLabel.text = String(format: "Кэш страниц на диске: %.0f МБ (лимит %.0f МБ, старые удаляются сами). Скачанные главы сюда не входят.",
                                               mb, Double(PageFiles.maxBytes) / 1_048_576)
            }
        }
    }

    private func info(_ msg: String) {
        let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    // MARK: действия

    @objc private func themeChanged() {
        Prefs.themeMode = ThemeMode(rawValue: themeControl.selectedSegmentIndex) ?? .light
        Theme.refresh()
    }

    @objc private func swatchTapped(_ sender: UIButton) {
        Prefs.accentIndex = sender.tag
        Theme.refresh()
    }

    @objc private func fancyChanged() {
        Prefs.fancy = fancySwitch.isOn
        Theme.refresh()      // экраны перерисуют украшения (полоски, тени) заново
    }

    @objc private func mangalibChanged() {
        Prefs.mangalibEnabled = mangalibSwitch.isOn
        NotificationCenter.default.post(name: Sources.didChange, object: nil)
    }

    @objc private func powerChanged() {
        Prefs.powerSaving = powerSwitch.isOn
        Power.apply()
    }

    @objc private func followChanged() {
        Prefs.powerFollowsSystem = followSwitch.isOn
        Power.apply()
    }

    @objc private func pasteTapped() {
        tokenView.text = UIPasteboard.general.string ?? ""
    }

    @objc private func saveTapped() {
        let t = AuthStore.normalize(tokenView.text ?? "")
        guard !t.isEmpty else { info("Токен пустой"); return }
        AuthStore.token = t
        tokenView.text = ""
        view.endEditing(true)
        refreshStatus()
        API.shared.me { [weak self] result in
            switch result {
            case .success(let me):
                self?.status.text = "Вы вошли как \(me.data.username ?? "пользователь")"
            case .failure:
                self?.info("Токен сохранён, но проверить его не удалось. Возможно, он устарел или неверный адрес проверки.")
            }
        }
    }

    @objc private func registerTapped() {
        guard let url = URL(string: Config.referer) else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    @objc private func logoutTapped() {
        AuthStore.token = nil
        refreshStatus()
    }

    @objc private func downloadsTapped() {
        navigationController?.pushViewController(DownloadsViewController(), animated: true)
    }

    @objc private func clearCacheTapped() {
        ImageLoader.shared.clearAllCaches()
        refreshCacheInfo()
        info("Кэш очищен. Закладки, история и скачанные главы не затронуты.")
    }

    @objc private func diagnosticsTapped() {
        navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
    }
}
