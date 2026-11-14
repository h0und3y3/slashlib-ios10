import UIKit

// MARK: - Скачанные главы (манифест хранится в файле рядом со страницами)

struct StoredPage: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

struct DownloadedChapter: Codable {
    let ref: TitleRef
    let chapterId: Int
    let volume: String
    let number: String
    let chapterName: String
    let branchIds: [Int]
    let pages: [StoredPage]
    let bytes: Int64
    let date: Date

    var id: String { return "\(ref.slug)#\(chapterId)" }

    var chapter: Chapter {
        return Chapter(id: chapterId, volume: volume, number: number, name: chapterName, branchIds: branchIds)
    }

    var pageList: [Page] {
        return pages.map { Page(url: $0.url, width: $0.width, height: $0.height) }
    }
}

final class DownloadStore {
    static let shared = DownloadStore()
    static let didChange = Notification.Name("DownloadStoreDidChange")

    private var items: [String: DownloadedChapter] = [:]
    private let writeQueue = DispatchQueue(label: "slashlib.manifest", qos: .utility)
    private var manifestURL: URL { return PageFiles.offlineDir.appendingPathComponent("manifest.json") }

    private init() {
        if let data = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([DownloadedChapter].self, from: data) {
            for d in list { items[d.id] = d }
        }
    }

    var count: Int { return items.count }

    var totalBytes: Int64 {
        var sum: Int64 = 0
        for d in items.values { sum += d.bytes }
        return sum
    }
   
    private static func ordered(_ list: [DownloadedChapter]) -> [DownloadedChapter] {
        return list.sorted { a, b in
            let ka = a.chapter.sortKey, kb = b.chapter.sortKey
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a.date < b.date
        }
   } // <--- 1-я скобка закрывает метод ordered
        // Возвращает список скачанных глав для конкретного тайтла
    func chapters(slug: String) -> [DownloadedChapter] {
        return items.values.filter { $0.ref.slug == slug }
    }

    // Возвращает конкретную скачанную главу по её id
    func downloaded(slug: String, chapterId: Int) -> DownloadedChapter? {
        return items.values.first { $0.ref.slug == slug && $0.chapterId == chapterId }
    }
    
}   // <--- 2-я скобка закрывает класс DownloadStore


