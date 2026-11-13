import UIKit

// MARK: - Тайтл (что нужно читалке и истории)

struct TitleRef: Codable {
    let slug: String
    let name: String
    let cover: String?
}

// MARK: - Закладки

struct Bookmark: Codable {
    let id: String
    let slug: String
    let titleName: String
    let cover: String?
    let chapterId: Int
    let volume: String
    let number: String
    let chapterName: String
    let branchIds: [Int]
    let page: Int          // с нуля
    let pageCount: Int
    let date: Date

    var chapter: Chapter {
        return Chapter(id: chapterId, volume: volume, number: number, name: chapterName, branchIds: branchIds)
    }
    var titleRef: TitleRef { return TitleRef(slug: slug, name: titleName, cover: cover) }
}

final class BookmarkStore {
    static let shared = BookmarkStore()
    static let didChange = Notification.Name("BookmarkStoreDidChange")

    private let key = "bookmarks.v1"
    private(set) var all: [Bookmark] = []   // новые сверху

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Bookmark].self, from: data) {
            all = list
        }
        all.sort { $0.date > $1.date }
    }

    private func save() {
        all.sort { $0.date > $1.date }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: BookmarkStore.didChange, object: nil)
    }

    // В каждой главе одна закладка: новая заменяет старую.
    func bookmark(slug: String, chapterId: Int) -> Bookmark? {
        return all.first { $0.slug == slug && $0.chapterId == chapterId }
    }

    func bookmarks(slug: String) -> [Bookmark] {
        return all.filter { $0.slug == slug }
    }

    func set(_ b: Bookmark) {
        all.removeAll { $0.slug == b.slug && $0.chapterId == b.chapterId }
        all.append(b)
        save()
    }

    func remove(id: String) {
        all.removeAll { $0.id == id }
        save()
    }
}

// MARK: - Настройки чтения

enum ReadMode: Int {
    case scroll = 0, pagedLTR = 1, pagedRTL = 2

    var shortTitle: String {
        switch self {
        case .scroll: return "Лента"
        case .pagedLTR: return "Стр. →"
        case .pagedRTL: return "Стр. ←"
        }
    }

    var fullTitle: String {
        switch self {
        case .scroll: return "Лента (вертикально)"
        case .pagedLTR: return "Страницы: слева направо"
        case .pagedRTL: return "Страницы: справа налево (манга)"
        }
    }
}

enum Prefs {
    private static let modeKey = "readMode"
    static var readMode: ReadMode {
        get { return ReadMode(rawValue: UserDefaults.standard.integer(forKey: modeKey)) ?? .scroll }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }
}

// MARK: - Иконка закладки (рисуем сами, чтобы не тащить картинки в ресурсы)

enum BookmarkIcon {
    static func image(filled: Bool) -> UIImage {
        let size = CGSize(width: 18, height: 26)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2, y: 1))
            path.addLine(to: CGPoint(x: 16, y: 1))
            path.addLine(to: CGPoint(x: 16, y: 24))
            path.addLine(to: CGPoint(x: 9, y: 18))
            path.addLine(to: CGPoint(x: 2, y: 24))
            path.close()
            UIColor.black.setStroke()
            UIColor.black.setFill()
            path.lineWidth = 2
            if filled { path.fill() } else { path.stroke() }
        }
        return img.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Прогресс чтения: «недавние» тайтлы и отметки прочитанных глав

final class ReadingProgress {
    static let shared = ReadingProgress()

    private let recentKey = "recent.v1"
    private let readKey = "readChapters.v1"
    private(set) var recent: [Bookmark] = []        // по одной записи на тайтл, новые сверху
    private var read: [String: Set<Int>] = [:]

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: recentKey),
           let list = try? JSONDecoder().decode([Bookmark].self, from: data) { recent = list }
        if let data = d.data(forKey: readKey),
           let map = try? JSONDecoder().decode([String: Set<Int>].self, from: data) { read = map }
    }

    private func persistRecent() {
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: recentKey) }
    }

    private func persistRead() {
        if let data = try? JSONEncoder().encode(read) { UserDefaults.standard.set(data, forKey: readKey) }
    }

    func save(_ b: Bookmark) {
        recent.removeAll { $0.slug == b.slug }
        recent.insert(b, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
        persistRecent()
    }

    func last(slug: String) -> Bookmark? {
        return recent.first { $0.slug == slug }
    }

    func remove(slug: String) {
        recent.removeAll { $0.slug == slug }
        persistRecent()
    }

    func markRead(slug: String, chapterId: Int) {
        var set = read[slug] ?? []
        if set.insert(chapterId).inserted {
            read[slug] = set
            persistRead()
        }
    }

    func isRead(slug: String, chapterId: Int) -> Bool {
        return read[slug]?.contains(chapterId) ?? false
    }
}

// MARK: - Дополнительные настройки

extension Prefs {
    static var powerSaving: Bool {
        get { return UserDefaults.standard.bool(forKey: "powerSaving") }
        set { UserDefaults.standard.set(newValue, forKey: "powerSaving") }
    }

    // По умолчанию приложение следует режиму энергосбережения iOS.
    static var powerFollowsSystem: Bool {
        get { return !UserDefaults.standard.bool(forKey: "powerIgnoresSystem") }
        set { UserDefaults.standard.set(!newValue, forKey: "powerIgnoresSystem") }
    }

    static var accentIndex: Int {
        get { return UserDefaults.standard.integer(forKey: "accentIndex") }
        set { UserDefaults.standard.set(newValue, forKey: "accentIndex") }
    }

    static var chaptersDescending: Bool {
        get { return UserDefaults.standard.bool(forKey: "chaptersDescending") }
        set { UserDefaults.standard.set(newValue, forKey: "chaptersDescending") }
    }
}

// MARK: - Избранное

struct FavoriteItem: Codable {
    let ref: TitleRef
    let date: Date
}

final class FavoritesStore {
    static let shared = FavoritesStore()
    static let didChange = Notification.Name("FavoritesStoreDidChange")

    private let key = "favorites.v1"
    private(set) var all: [FavoriteItem] = []      // новые сверху

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([FavoriteItem].self, from: data) {
            all = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: FavoritesStore.didChange, object: nil)
    }

    func isFavorite(_ slug: String) -> Bool {
        return all.contains { $0.ref.slug == slug }
    }

    // Возвращает true, если тайтл теперь в избранном.
    @discardableResult
    func toggle(_ ref: TitleRef) -> Bool {
        if let i = all.firstIndex(where: { $0.ref.slug == ref.slug }) {
            all.remove(at: i)
            save()
            return false
        }
        all.insert(FavoriteItem(ref: ref, date: Date()), at: 0)
        save()
        return true
    }

    func remove(slug: String) {
        all.removeAll { $0.ref.slug == slug }
        save()
    }
}
