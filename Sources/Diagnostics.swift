import UIKit

// MARK: - Память

enum MemoryInfo {
    static let physicalMB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    // 1 ГБ и меньше (iPhone 5s/6, iPad mini 2 и т.п.): включаем «экономный» режим.
    static var isLowRAM: Bool { return physicalMB < 1500 }
    // Выше этого порога чистим кэши сами, не дожидаясь, пока iOS закроет приложение.
    static var softLimitMB: Double { return min(max(physicalMB * 0.30, 220), 600) }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: 1) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

enum MemoryGuard {
    private static var lastCheck = Date.distantPast

    static func install() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            Breadcrumbs.shared.log("⚠️ ПРЕДУПРЕЖДЕНИЕ iOS О ПАМЯТИ — чищу кэши")
            purge()
        }
    }

    static func purge() {
        StripRenderer.shared.purge()
        ImageLoader.shared.purgeMemory()
    }

    // Вызывать с главного потока после тяжёлых операций. Сам ограничивает частоту проверок.
    static func checkSoftLimit() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 1.0 else { return }
        lastCheck = now
        let used = MemoryInfo.residentMB()
        if used > MemoryInfo.softLimitMB {
            Breadcrumbs.shared.log("память \(Int(used)) МБ выше порога \(Int(MemoryInfo.softLimitMB)) МБ — чищу кэши")
            purge()
        }
    }
}

// MARK: - Файлы диагностики

enum Diagnostics {
    static let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var crashURL: URL { return dir.appendingPathComponent("crash.txt") }
    static var lastReportURL: URL { return dir.appendingPathComponent("lastreport.txt") }
    static var breadcrumbsURL: URL { return dir.appendingPathComponent("breadcrumbs.log") }

    static var appVersion: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    static var deviceModel: String {
        var s = utsname()
        uname(&s)
        return withUnsafePointer(to: &s.machine) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static func header() -> String {
        return "Slashlib \(appVersion) · \(deviceModel) · iOS \(UIDevice.current.systemVersion)\n" +
               "ОЗУ \(Int(MemoryInfo.physicalMB)) МБ, сейчас занято \(Int(MemoryInfo.residentMB())) МБ"
    }
}

// MARK: - «Хлебные крошки»: последние действия приложения. Нужны, чтобы после вылета было видно, что происходило.

final class Breadcrumbs {
    static let shared = Breadcrumbs()

    private let lock = NSLock()
    private var lines: [String] = []
    private var flushScheduled = false
    private let start = Date()

    private init() {}

    func log(_ text: String) {
        let line = String(format: "+%.1fс %4.0fМБ  ", Date().timeIntervalSince(start), MemoryInfo.residentMB()) + text
        lock.lock()
        lines.append(line)
        if lines.count > 160 { lines.removeFirst(lines.count - 120) }
        let need = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if need {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (Power.isSaving ? 10 : 2)) { [weak self] in self?.flush() }
        }
    }

    // В обработчике сбоя замок мог быть захвачен упавшим потоком — тогда читаем без него.
    func snapshot() -> [String] {
        let got = lock.`try`()
        let copy = lines
        if got { lock.unlock() }
        return copy
    }

    func flush() {
        lock.lock()
        flushScheduled = false
        let text = lines.joined(separator: "\n")
        lock.unlock()
        try? text.write(to: Diagnostics.breadcrumbsURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        lock.lock()
        lines = []
        lock.unlock()
        try? FileManager.default.removeItem(at: Diagnostics.breadcrumbsURL)
    }
}

// MARK: - Перехват сбоев
// iOS не даёт надёжно показать окно в момент падения, поэтому причина записывается в файл
// и показывается при следующем запуске (и всегда доступна в «Аккаунт → Диагностика»).

enum CrashReporter {
    private static var handling = false

    static func install() {
        signal(SIGPIPE, SIG_IGN)   // обрыв соединения не должен убивать приложение
        NSSetUncaughtExceptionHandler { e in
            CrashReporter.write(kind: "Необработанное исключение \(e.name.rawValue)",
                                detail: e.reason ?? "",
                                stack: e.callStackSymbols)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in CrashReporter.handleSignal(s) }
        }
    }

    fileprivate static func handleSignal(_ s: Int32) {
        let name: String
        switch s {
        case SIGABRT: name = "SIGABRT — аварийное завершение (assert/исключение)"
        case SIGSEGV: name = "SIGSEGV — обращение к недопустимой памяти"
        case SIGBUS: name = "SIGBUS — ошибка доступа к памяти"
        case SIGILL: name = "SIGILL — недопустимая инструкция (в Swift так выглядят: выход за границы массива, переполнение числа, принудительное снятие nil)"
        case SIGTRAP: name = "SIGTRAP — ловушка Swift (выход за границы массива, переполнение, nil, нехватка памяти при выделении)"
        case SIGFPE: name = "SIGFPE — ошибка арифметики"
        default: name = "сигнал \(s)"
        }
        write(kind: "Сбой: \(name)", detail: "", stack: Thread.callStackSymbols)
        signal(s, SIG_DFL)
        raise(s)
    }

    fileprivate static func write(kind: String, detail: String, stack: [String]) {
        if handling { return }
        handling = true
        var text = "=== СБОЙ ПРИЛОЖЕНИЯ ===\n"
        text += Diagnostics.header() + "\n"
        text += kind + "\n"
        if !detail.isEmpty { text += "Причина: " + detail + "\n" }
        text += "\nСтек вызовов:\n" + stack.prefix(30).joined(separator: "\n") + "\n"
        text += "\nПоследние действия перед сбоем:\n" + Breadcrumbs.shared.snapshot().suffix(60).joined(separator: "\n") + "\n"
        try? text.write(to: Diagnostics.crashURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Итоги прошлого запуска

enum Session {
    private static let key = "session.cleanExit"

    // Вызывать самым первым при старте. Возвращает текст отчёта, если прошлый запуск закончился плохо.
    static func begin() -> String? {
        let d = UserDefaults.standard
        var report: String?

        if let crash = try? String(contentsOf: Diagnostics.crashURL, encoding: .utf8), !crash.isEmpty {
            report = crash
            try? FileManager.default.removeItem(at: Diagnostics.crashURL)
        } else if d.object(forKey: key) != nil && !d.bool(forKey: key) {
            let last = (try? String(contentsOf: Diagnostics.breadcrumbsURL, encoding: .utf8)) ?? ""
            report = "=== ПРИЛОЖЕНИЕ ЗАКРЫЛОСЬ БЕЗ ОШИБКИ В ЖУРНАЛЕ ===\n" +
                "Скорее всего iOS закрыла его из-за нехватки памяти (такое закрытие перехватить нельзя).\n" +
                "Последние действия:\n" + last
        }
        if let r = report {
            try? r.write(to: Diagnostics.lastReportURL, atomically: true, encoding: .utf8)
        }
        markRunning()
        return report
    }

    static func markRunning() {
        UserDefaults.standard.set(false, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func markClean() {
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func summary(_ report: String) -> String {
        let lines = report.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.prefix(6).joined(separator: "\n")
    }
}

// MARK: - Экран диагностики

final class DiagnosticsViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Диагностика"
        view.backgroundColor = Theme.card
        textView.backgroundColor = Theme.card
        textView.textColor = Theme.text
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.font = UIFont(name: "Menlo", size: 11) ?? UIFont.systemFont(ofSize: 11)
        view.addSubview(textView)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Поделиться", style: .plain, target: self, action: #selector(shareTapped(_:))),
            UIBarButtonItem(title: "Очистить", style: .plain, target: self, action: #selector(clearTapped))
        ]
        reload()
    }

    private func reload() {
        var text = Diagnostics.header() + "\n\n"
        text += "— Последний сбой —\n"
        text += ((try? String(contentsOf: Diagnostics.lastReportURL, encoding: .utf8)) ?? "нет записей") + "\n\n"
        text += "— Журнал текущего запуска —\n"
        text += Breadcrumbs.shared.snapshot().joined(separator: "\n")
        textView.text = text
        textView.textColor = Theme.text
    }

    @objc private func shareTapped(_ sender: UIBarButtonItem) {
        let vc = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = sender
        present(vc, animated: true)
    }

    @objc private func clearTapped() {
        try? FileManager.default.removeItem(at: Diagnostics.lastReportURL)
        Breadcrumbs.shared.clear()
        reload()
    }
}
