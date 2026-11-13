import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Порядок важен: сначала читаем итоги прошлого запуска, потом включаем перехват новых сбоев.
        let previousProblem = Session.begin()
        CrashReporter.install()
        MemoryGuard.install()
        Power.install()
        PageSource.prepare()

        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = makeTabs()
        w.tintColor = Theme.accent
        w.makeKeyAndVisible()
        window = w

        Breadcrumbs.shared.log("запуск \(Diagnostics.appVersion), \(Diagnostics.deviceModel), iOS \(UIDevice.current.systemVersion), ОЗУ \(Int(MemoryInfo.physicalMB)) МБ, энергосбережение: \(Power.isSaving ? "вкл" : "выкл")")
        API.shared.loadImageServers()
        DispatchQueue.global(qos: .utility).async { PageFiles.trim(maxBytes: PageFiles.maxBytes) }

        if let report = previousProblem {
            DispatchQueue.main.async { [weak self] in self?.presentProblem(report) }
        }
        return true
    }

    // Нижняя панель: Поиск · Избранное · Закладки · Аккаунт
    private func makeTabs() -> UITabBarController {
        func tab(_ root: UIViewController, _ title: String, _ icon: UIImage, _ tag: Int) -> UINavigationController {
            let nav = UINavigationController(rootViewController: root)
            nav.tabBarItem = UITabBarItem(title: title, image: icon, tag: tag)
            return nav
        }
        let tabs = UITabBarController()
        tabs.viewControllers = [
            tab(CatalogViewController(), "Поиск", TabIcons.search(), 0),
            tab(FavoritesViewController(), "Избранное", TabIcons.star(), 1),
            tab(HistoryViewController(), "Закладки", TabIcons.bookmark(), 2),
            tab(SettingsViewController(), "Аккаунт", TabIcons.person(), 3)
        ]
        return tabs
    }

    private func presentProblem(_ report: String) {
        guard let tabs = window?.rootViewController as? UITabBarController else { return }
        let alert = UIAlertController(title: "Прошлый запуск завершился аварийно",
                                      message: Session.summary(report), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Показать подробности", style: .default) { _ in
            (tabs.selectedViewController as? UINavigationController)?
                .pushViewController(DiagnosticsViewController(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        tabs.present(alert, animated: true)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Breadcrumbs.shared.log("свёрнуто")
        Breadcrumbs.shared.flush()
        Session.markClean()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Session.markRunning()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Breadcrumbs.shared.flush()
        Session.markClean()
    }
}
