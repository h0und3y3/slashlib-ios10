import UIKit
import SafariServices

// Вкладка «Аккаунт»: вход, оформление, энергосбережение, загрузки и кэш, диагностика.
final class SettingsViewController: UIViewController {
    private let status = UILabel()
    private let tokenView = UITextView()
    private let cacheLabel = UILabel()
    private let downloadsLabel = UILabel()
    private let powerSwitch = UISwitch()
    private let followSwitch = UISwitch()
    private var swatches: [UIButton] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Аккаунт"
        view.backgroundColor = .white

        // --- вход ---
        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 15)

        let hint = smallLabel("Вставьте токен (Bearer) из вашего аккаунта на сайте. Взять его можно в браузере на ПК: DevTools → Network → любой запрос к api.lib.social → заголовок Authorization.")

        tokenView.layer.borderColor = UIColor.lightGray.cgColor
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

        // --- оформление ---
        let swatchRow = UIStackView()
        swatchRow.axis = .horizontal
        swatchRow.distribution = .equalSpacing
        swatchRow.alignment = .center
        for (i, item) in Theme.palette.enumerated() {
            let b = UIButton(type: .custom)
            b.tag = i
            b.backgroundColor = item.color
            b.layer.cornerRadius = 16
            b.layer.borderColor = UIColor.darkGray.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            swatchRow.addArrangedSubview(b)
            swatches.append(b)
        }

        // --- энергосбережение ---
        powerSwitch.addTarget(self, action: #selector(powerChanged), for: .valueChanged)
        followSwitch.addTarget(self, action: #selector(followChanged), for: .valueChanged)
        let powerRow = switchRow("Энергосбережение", powerSwitch)
        let followRow = switchRow("Включать вместе с режимом iOS", followSwitch)
        let powerHint = smallLabel("Меньше разрешение и качество картинок, нет предзагрузки страниц, без анимаций, экран может гаснуть во время чтения, загрузка глав в один поток. Заметно продлевает работу от батареи.")

        // --- загрузки и кэш ---
        downloadsLabel.numberOfLines = 0
        downloadsLabel.font = .systemFont(ofSize: 13)
        downloadsLabel.textColor = .darkGray
        let manage = button("Управление загрузками", #selector(downloadsTapped))
        cacheLabel.numberOfLines = 0
        cacheLabel.font = .systemFont(ofSize: 13)
        cacheLabel.textColor = .darkGray
        let clear = button("Очистить кэш страниц", #selector(clearCacheTapped))
        let diag = button("Диагностика и журнал ошибок", #selector(diagnosticsTapped))

        let stack = UIStackView(arrangedSubviews: [
            heading("Вход"), status, hint, tokenView, paste, save, register, logout,
            heading("Цвет акцента"), swatchRow,
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
        refreshSwitches()
        refreshSwatches()
        refreshDownloads()
        refreshCacheInfo()
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
        l.textColor = .gray
        return l
    }

    private func smallLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 13)
        l.textColor = .darkGray
        l.text = text
        return l
    }

    private func switchRow(_ text: String, _ sw: UISwitch) -> UIStackView {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15)
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
    }

    private func refreshSwatches() {
        for b in swatches {
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

    @objc private func swatchTapped(_ sender: UIButton) {
        Prefs.accentIndex = sender.tag
        Theme.applyEverywhere()
        refreshSwatches()
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
