import UIKit

// MARK: - Энергосбережение
// Включается вручную или само, когда включён режим энергосбережения iOS.
// Что меняется: меньше разрешение и качество картинок, нет предзагрузки, экран может гаснуть,
// реже пишется журнал, нет анимаций, загрузки глав идут в один поток.

enum Power {
    static let didChange = Notification.Name("PowerModeDidChange")

    static var isSaving: Bool {
        if Prefs.powerSaving { return true }
        if Prefs.powerFollowsSystem && ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return false
    }

    static func install() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in apply() }
    }

    static func apply() {
        Breadcrumbs.shared.log("энергосбережение: \(isSaving ? "вкл" : "выкл")")
        PageSource.prepare()
        MemoryGuard.purge()          // уже нарисованные полосы сделаны под прежний режим
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - Тема оформления (светлая / тёмная / автоматически ночью)

enum ThemeMode: Int {
    case light = 0, dark = 1, auto = 2

    var title: String {
        switch self {
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        case .auto: return "Авто"
        }
    }
}

enum Theme {
    static let didChange = Notification.Name("ThemeDidChange")
    private static var lastDark = false

    static let palette: [(name: String, color: UIColor)] = [
        ("Синий", UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1)),
        ("Красный", UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1)),
        ("Оранжевый", UIColor(red: 0.96, green: 0.52, blue: 0.00, alpha: 1)),
        ("Зелёный", UIColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 1)),
        ("Бирюзовый", UIColor(red: 0.00, green: 0.64, blue: 0.68, alpha: 1)),
        ("Фиолетовый", UIColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1)),
        ("Розовый", UIColor(red: 0.93, green: 0.30, blue: 0.58, alpha: 1))
    ]

    static var accent: UIColor {
        let i = Prefs.accentIndex
        return palette.indices.contains(i) ? palette[i].color : palette[0].color
    }

    static var isDark: Bool {
        switch Prefs.themeMode {
        case .light: return false
        case .dark: return true
        case .auto:
            let h = Calendar.current.component(.hour, from: Date())
            return h >= 21 || h < 7
        }
    }

    // Цвета: экран, «карточка» (ячейки), основной и второстепенный текст, разделители, плашки-теги.
    static var background: UIColor { return isDark ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.95, alpha: 1) }
    static var card: UIColor { return isDark ? UIColor(white: 0.13, alpha: 1) : .white }
    static var text: UIColor { return isDark ? UIColor(white: 0.93, alpha: 1) : .black }
    static var secondary: UIColor { return isDark ? UIColor(white: 0.60, alpha: 1) : UIColor(white: 0.40, alpha: 1) }
    static var separator: UIColor { return isDark ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.84, alpha: 1) }
    static var chip: UIColor { return isDark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.90, alpha: 1) }
    static var bar: UIColor { return isDark ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.97, alpha: 1) }

    // Вызывать после смены темы/цвета: перекрашивает окно и сообщает экранам.
    static func refresh() {
        lastDark = isDark
        if let w = (UIApplication.shared.delegate as? AppDelegate)?.window {
            w.tintColor = accent
            if #available(iOS 13.0, *) {
                // На новых iOS системные элементы (переключатели, клавиатура, окна вопросов) тоже становятся тёмными.
                w.overrideUserInterfaceStyle = isDark ? .dark : .light
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // В режиме «Авто» тема меняется сама — проверяем при возвращении в приложение.
    static func reevaluate() {
        if isDark != lastDark { refresh() }
    }

    static func styleBars(_ nav: UINavigationController) {
        let dark = isDark
        nav.navigationBar.barStyle = dark ? .black : .default
        nav.navigationBar.barTintColor = dark ? bar : nil
        nav.navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: text]
        nav.toolbar.barStyle = dark ? .black : .default
        nav.toolbar.barTintColor = dark ? bar : nil
        applyBarAppearance(nav, color: dark ? bar : nil, titleColor: text)
    }

    // iOS 13+: без этого панели на iOS 15 у края прокрутки становятся прозрачными, а barTintColor игнорируется.
    static func applyBarAppearance(_ nav: UINavigationController, color: UIColor?, titleColor: UIColor) {
        guard #available(iOS 13.0, *) else { return }
        let a = UINavigationBarAppearance()
        a.configureWithDefaultBackground()
        if let c = color { a.backgroundColor = c }
        a.titleTextAttributes = [.foregroundColor: titleColor]
        nav.navigationBar.standardAppearance = a
        nav.navigationBar.scrollEdgeAppearance = a
        nav.navigationBar.compactAppearance = a

        let t = UIToolbarAppearance()
        t.configureWithDefaultBackground()
        if let c = color { t.backgroundColor = c }
        nav.toolbar.standardAppearance = t
        nav.toolbar.compactAppearance = t
        if #available(iOS 15.0, *) {
            nav.navigationBar.compactScrollEdgeAppearance = a
            nav.toolbar.scrollEdgeAppearance = t
        }
    }

    static func styleTabBar(_ tabs: UITabBarController) {
        tabs.tabBar.barStyle = isDark ? .black : .default
        tabs.tabBar.barTintColor = isDark ? bar : nil
        if #available(iOS 13.0, *) {
            let a = UITabBarAppearance()
            a.configureWithDefaultBackground()
            if isDark { a.backgroundColor = bar }
            tabs.tabBar.standardAppearance = a
            if #available(iOS 15.0, *) { tabs.tabBar.scrollEdgeAppearance = a }
        }
    }

    static func styleTable(_ tv: UITableView) {
        tv.backgroundColor = background
        tv.separatorColor = separator
    }

    static func styleCell(_ cell: UITableViewCell) {
        cell.backgroundColor = card
        cell.textLabel?.textColor = text
        cell.detailTextLabel?.textColor = secondary
        if cell.selectedBackgroundView == nil { cell.selectedBackgroundView = UIView() }   // не создаём заново на каждую строку
        cell.selectedBackgroundView?.backgroundColor = separator
    }
}

// MARK: - Анимации и украшения (всё включается и выключается одним переключателем в «Аккаунт»)

enum Fx {
    static var enabled: Bool { return Prefs.fancy && !Power.isSaving }

    static func fadeIn(_ v: UIView, delay: TimeInterval = 0, offset: CGFloat = 14) {
        guard enabled else { return }
        v.alpha = 0
        v.transform = CGAffineTransform(translationX: 0, y: offset)
        UIView.animate(withDuration: 0.35, delay: delay, options: [.curveEaseOut, .allowUserInteraction],
                       animations: {
                           v.alpha = 1
                           v.transform = .identity
                       }, completion: nil)
    }

    static func cascade(_ views: [UIView]) {
        guard enabled else { return }
        for (i, v) in views.prefix(10).enumerated() { fadeIn(v, delay: Double(i) * 0.05) }
    }

    static func setImage(_ iv: UIImageView, _ image: UIImage?) {
        guard enabled, iv.window != nil, image != nil else { iv.image = image; return }
        UIView.transition(with: iv, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { iv.image = image }, completion: nil)
    }

    static func pop(_ v: UIView) {
        guard enabled else { return }
        v.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 8,
                       options: [.allowUserInteraction], animations: { v.transform = .identity }, completion: nil)
    }

    static func press(_ v: UIView, down: Bool) {
        guard enabled else { v.transform = .identity; return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: {
                           v.transform = down ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
                       }, completion: nil)
    }

    // Тень под «карточками» — украшение, поэтому тоже выключается.
    static func decorate(card v: UIView) {
        if enabled {
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = Theme.isDark ? 0.5 : 0.12
            v.layer.shadowRadius = 5
            v.layer.shadowOffset = CGSize(width: 0, height: 2)
        } else {
            v.layer.shadowOpacity = 0
        }
    }
}

// MARK: - Мелкие элементы интерфейса

// «Скелет» на время загрузки: серая плашка с бегущим бликом (блик — только при включённых анимациях).
final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 6
        layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let base = Theme.chip
        let light = Theme.isDark ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 0.98, alpha: 1)
        gradient.colors = [base.cgColor, light.cgColor, base.cgColor]
        gradient.locations = [0.0, 0.5, 1.0]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func start() {
        applyTheme()
        gradient.removeAnimation(forKey: "shimmer")
        guard Fx.enabled else { return }
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-1.0, -0.5, 0.0]
        a.toValue = [1.0, 1.5, 2.0]
        a.duration = 1.3
        a.repeatCount = Float.infinity
        gradient.add(a, forKey: "shimmer")
    }

    func stop() { gradient.removeAnimation(forKey: "shimmer") }
}

// Полоса прогресса (чтение главы).
final class ProgressBar: UIView {
    private let fill = UIView()
    private(set) var value: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(fill)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        backgroundColor = Theme.separator
        fill.backgroundColor = Theme.accent
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
    }

    func set(_ v: CGFloat, animated: Bool) {
        value = min(max(v, 0), 1)
        applyTheme()
        if animated && Fx.enabled && bounds.width > 0 {
            fill.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
            UIView.animate(withDuration: 0.6, delay: 0.1, options: [.curveEaseOut], animations: {
                self.fill.frame = CGRect(x: 0, y: 0, width: self.bounds.width * self.value, height: self.bounds.height)
            }, completion: nil)
        } else {
            setNeedsLayout()
        }
    }
}

// Подпись с внутренними отступами — «плашка-тег».
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = CGSize(width: max(size.width - insets.left - insets.right, 0), height: size.height)
        let s = super.sizeThatFits(inner)
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }

    static func chip(_ text: String, accent: Bool) -> PaddedLabel {
        let l = PaddedLabel()
        l.text = text
        l.font = .boldSystemFont(ofSize: 10)
        l.layer.cornerRadius = 4
        l.clipsToBounds = true
        l.lineBreakMode = .byTruncatingTail
        l.textColor = accent ? Theme.accent : Theme.secondary
        l.backgroundColor = accent ? Theme.accent.withAlphaComponent(0.15) : Theme.chip
        return l
    }
}

// Заголовок раздела: название, цветная полоска-украшение (если включены украшения) и необязательная кнопка справа.
final class SectionHeaderView: UIView {
    private let label = UILabel()
    private let bar = UIView()
    private let button = UIButton(type: .system)
    var onButton: (() -> Void)?

    init(title: String, buttonTitle: String? = nil) {
        super.init(frame: .zero)
        backgroundColor = .clear
        label.text = title
        label.font = .boldSystemFont(ofSize: 19)
        label.textColor = Theme.text
        bar.backgroundColor = Theme.accent
        bar.layer.cornerRadius = 2
        bar.isHidden = !Fx.enabled
        addSubview(bar)
        addSubview(label)
        if let t = buttonTitle {
            button.setTitle(t, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onButton?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let left: CGFloat = Fx.enabled ? 30 : 16
        bar.frame = CGRect(x: 16, y: 12, width: 4, height: max(bounds.height - 24, 0))
        button.sizeToFit()
        button.frame = CGRect(x: bounds.width - button.bounds.width - 16, y: 0,
                              width: button.bounds.width, height: bounds.height)
        let right = button.superview == nil ? bounds.width - 16 : button.frame.minX - 8
        label.frame = CGRect(x: left, y: 0, width: max(right - left, 0), height: bounds.height)
    }
}

// Плавное переключение вкладок.
final class FadeTransition: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { return 0.2 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        guard let to = ctx.view(forKey: .to) else {
            ctx.completeTransition(false)
            return
        }
        if let vc = ctx.viewController(forKey: .to) { to.frame = ctx.finalFrame(for: vc) }
        to.alpha = 0
        ctx.containerView.addSubview(to)
        UIView.animate(withDuration: 0.2, animations: { to.alpha = 1 }, completion: { _ in
            ctx.completeTransition(!ctx.transitionWasCancelled)
        })
    }
}

// MARK: - Иконки (рисуем сами, чтобы не добавлять картинки в ресурсы)

enum StarIcon {
    static func path(center: CGPoint, outer: CGFloat, inner: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        for i in 0..<10 {
            let r = i % 2 == 0 ? outer : inner
            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.close()
        return p
    }

    static func image(filled: Bool, size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        let img = UIGraphicsImageRenderer(size: s).image { _ in
            let c = CGPoint(x: size / 2, y: size / 2 + size * 0.03)
            let p = StarIcon.path(center: c, outer: size * 0.46, inner: size * 0.19)
            UIColor.black.setStroke()
            UIColor.black.setFill()
            p.lineWidth = 2
            p.lineJoinStyle = .round
            if filled { p.fill() } else { p.stroke() }
        }
        return img.withRenderingMode(.alwaysTemplate)
    }
}

enum TabIcons {
    private static func render(_ draw: () -> Void) -> UIImage {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in draw() }
        return img.withRenderingMode(.alwaysTemplate)
    }

    static func home() -> UIImage {
        return render {
            UIColor.black.setStroke()
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 3, y: 15))
            p.addLine(to: CGPoint(x: 15, y: 4))
            p.addLine(to: CGPoint(x: 27, y: 15))
            p.move(to: CGPoint(x: 6, y: 13))
            p.addLine(to: CGPoint(x: 6, y: 26))
            p.addLine(to: CGPoint(x: 24, y: 26))
            p.addLine(to: CGPoint(x: 24, y: 13))
            p.lineWidth = 2.5
            p.lineJoinStyle = .round
            p.lineCapStyle = .round
            p.stroke()
        }
    }

    static func search() -> UIImage {
        return render {
            UIColor.black.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 16, height: 16))
            ring.lineWidth = 2.5
            ring.stroke()
            let handle = UIBezierPath()
            handle.move(to: CGPoint(x: 18, y: 18))
            handle.addLine(to: CGPoint(x: 26, y: 26))
            handle.lineWidth = 3
            handle.lineCapStyle = .round
            handle.stroke()
        }
    }

    static func star() -> UIImage { return StarIcon.image(filled: false, size: 30) }

    static func bookmark() -> UIImage { return BookmarkIcon.image(filled: false) }

    static func person() -> UIImage {
        return render {
            UIColor.black.setStroke()
            let head = UIBezierPath(ovalIn: CGRect(x: 10, y: 3, width: 10, height: 10))
            head.lineWidth = 2.5
            head.stroke()
            let body = UIBezierPath(arcCenter: CGPoint(x: 15, y: 28), radius: 11,
                                    startAngle: CGFloat.pi, endAngle: 0, clockwise: true)
            body.lineWidth = 2.5
            body.stroke()
        }
    }
}
