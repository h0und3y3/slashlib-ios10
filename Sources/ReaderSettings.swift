import UIKit

// Панель настроек читалки (выезжает снизу): режим, фон страницы, затемнение,
// автоскрытие панелей, «не гасить экран» и быстрый выбор темы приложения.
final class ReaderSettingsViewController: UIViewController {
    var onChange: (() -> Void)?

    private let card = UIView()
    private let modeControl = UISegmentedControl(items: [ReadMode.scroll.shortTitle, ReadMode.pagedLTR.shortTitle, ReadMode.pagedRTL.shortTitle])
    private let backgroundControl = UISegmentedControl(items: ["Чёрный", "Серый", "Белый"])
    private let themeControl = UISegmentedControl(items: [ThemeMode.light.title, ThemeMode.dark.title, ThemeMode.auto.title])
    private let dimSlider = UISlider()
    private let autoHideSwitch = UISwitch()
    private let awakeSwitch = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.4)

        // Нажатие мимо карточки закрывает панель.
        let closer = UIButton(type: .custom)
        closer.frame = view.bounds
        closer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        closer.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closer)

        card.backgroundColor = Theme.card
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        modeControl.selectedSegmentIndex = Prefs.readMode.rawValue
        backgroundControl.selectedSegmentIndex = Prefs.readerBackground
        themeControl.selectedSegmentIndex = Prefs.themeMode.rawValue
        dimSlider.minimumValue = 0
        dimSlider.maximumValue = 0.6
        dimSlider.value = Float(Prefs.readerDim)
        autoHideSwitch.isOn = Prefs.readerAutoHide
        awakeSwitch.isOn = Prefs.readerKeepAwake
        for c in [modeControl, backgroundControl, themeControl] as [UIControl] {
            c.addTarget(self, action: #selector(changed), for: .valueChanged)
        }
        for c in [dimSlider, autoHideSwitch, awakeSwitch] as [UIControl] {
            c.addTarget(self, action: #selector(changed), for: .valueChanged)
        }

        let done = UIButton(type: .system)
        done.setTitle("Готово", for: .normal)
        done.titleLabel?.font = .boldSystemFont(ofSize: 17)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            heading("Режим чтения"), modeControl,
            heading("Фон страницы"), backgroundControl,
            heading("Затемнение"), dimSlider,
            row("Прятать панели при листании", autoHideSwitch),
            row("Не гасить экран", awakeSwitch),
            heading("Тема приложения"), themeControl,
            done
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let preferred = card.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -20)
        preferred.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            preferred,
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
    }

    private func heading(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text.uppercased()
        l.font = .boldSystemFont(ofSize: 11)
        l.textColor = Theme.secondary
        return l
    }

    private func row(_ text: String, _ sw: UISwitch) -> UIStackView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 15)
        l.textColor = Theme.text
        l.numberOfLines = 0
        let r = UIStackView(arrangedSubviews: [l, sw])
        r.alignment = .center
        r.spacing = 10
        return r
    }

    @objc private func changed() {
        let newTheme = ThemeMode(rawValue: themeControl.selectedSegmentIndex) ?? .light
        let themeChanged = newTheme != Prefs.themeMode
        Prefs.readMode = ReadMode(rawValue: modeControl.selectedSegmentIndex) ?? .scroll
        Prefs.readerBackground = backgroundControl.selectedSegmentIndex
        Prefs.readerDim = Double(dimSlider.value)
        Prefs.readerAutoHide = autoHideSwitch.isOn
        Prefs.readerKeepAwake = awakeSwitch.isOn
        Prefs.themeMode = newTheme
        if themeChanged {
            Theme.refresh()
            card.backgroundColor = Theme.card
        }
        onChange?()
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
