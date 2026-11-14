import UIKit

// Номера вкладок нижней панели.
enum AppTabs {
    static let home = 0
    static let search = 1
    static let favorites = 2
    static let bookmarks = 3
    static let account = 4
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UITabBarControllerDelegate {
    var window: UIWindow?
    private var navControllers: [UINavigationController] = []
    private weak var tabs: UITabBarController?

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

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.didChange, object: nil)
        Theme.refresh()     // запоминает текущую тему и красит окно

        Breadcrumbs.shared.log("запуск \(Diagnostics.appVersion), \(Diagnostics.deviceModel), iOS \(UIDevice.current.systemVersion), ОЗУ \(Int(MemoryInfo.physicalMB)) МБ, энергосбережение: \(Power.isSaving ? "вкл" : "выкл")")
        API.shared.loadImageServers()
        DispatchQueue.global(qos: .utility).async { PageFiles.trim(maxBytes: PageFiles.maxBytes) }

        if let report = previousProblem {
            DispatchQueue.main.async { [weak self] in self?.presentProblem(report) }
        }
        return true
    }

    // Нижняя панель: Главная · Поиск · Избранное · Закладки · Аккаунт
    private func makeTabs() -> UITabBarController {
        func tab(_ root: UIViewController, _ title: String, _ icon: UIImage, _ tag: Int) -> UINavigationController {
            let nav = UINavigationController(rootViewController: root)
            nav.tabBarItem = UITabBarItem(title: title, image: icon, tag: tag)
            navControllers.append(nav)
            return nav
        }
        let bar = UITabBarController()
        bar.delegate = self
        bar.viewControllers = [
            tab(HomeViewController(), "Главная", TabIcons.home(), AppTabs.home),
            tab(CatalogViewController(), "Поиск", TabIcons.search(), AppTabs.search),
            tab(FavoritesViewController(), "Избранное", TabIcons.star(), AppTabs.favorites),
            tab(HistoryViewController(), "Закладки", TabIcons.bookmark(), AppTabs.bookmarks),
            tab(SettingsViewController(), "Аккаунт", TabIcons.person(), AppTabs.account)
        ]
        tabs = bar
        return bar
    }

    // Тема или акцент поменялись — перекрашиваем панели.
    @objc private func themeChanged() {
        for nav in navControllers { Theme.styleBars(nav) }
        if let t = tabs { Theme.styleTabBar(t) }
        window?.backgroundColor = Theme.background
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          animationControllerForTransitionFrom fromVC: UIViewController,
                          to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return Fx.enabled ? FadeTransition() : nil
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
        Theme.reevaluate()      // режим «Авто»: ночью тема сменится сама
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Breadcrumbs.shared.flush()
        Session.markClean()
    }
}
