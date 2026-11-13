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

// MARK: - Цвет акцента

enum Theme {
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

    static func applyEverywhere() {
        for w in UIApplication.shared.windows { w.tintColor = accent }
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
