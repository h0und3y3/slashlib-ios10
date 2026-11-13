import UIKit
import ImageIO

// Как устроено чтение страниц (чтобы большие страницы не убивали приложение):
//  1. Страница скачивается СРАЗУ В ФАЙЛ на диск (не в память) и остаётся там как кэш.
//  2. Из файла читаются только размеры — картинка при этом не декодируется.
//  3. Страница делится на горизонтальные полосы. Каждая полоса декодируется отдельно, через системный
//     ImageIO (он декодирует кусками и может использовать аппаратный декодер JPEG), сразу уменьшается
//     до размера экрана и показывается, как только готова.
//  4. Декодируется только то, что видно на экране (+ небольшой запас), по одной полосе за раз.
//     Полосы, ушедшие далеко от экрана, выбрасываются из памяти.

// MARK: - Дисковый кэш страниц

struct PageFile {
    let url: URL
    let size: Int64
    let date: Date
}

enum PageFiles {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: nil)
        return d
    }()

    static var maxBytes: Int64 { return MemoryInfo.isLowRAM ? 250 * 1_048_576 : 500 * 1_048_576 }

    private static func name(for key: String) -> String {
        // FNV-1a 64 бит
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    static func url(for key: String) -> URL {
        return dir.appendingPathComponent(name(for: key))
    }

    // Скачанные главы: хранятся отдельно от кэша и сами не удаляются.
    static let offlineDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Slashlib-offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: nil)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }()

    static func offlineURL(for key: String) -> URL {
        return offlineDir.appendingPathComponent(name(for: key))
    }

    static func freeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func entries() -> [PageFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []) else { return [] }
        var out: [PageFile] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            out.append(PageFile(url: u, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? Date.distantPast))
        }
        return out
    }

    static func totalSize() -> Int64 {
        var sum: Int64 = 0
        for e in entries() { sum += e.size }
        return sum
    }

    // Удаляет самые старые файлы, пока кэш не уложится в лимит.
    static func trim(maxBytes limit: Int64) {
        var list = entries().sorted { $0.date < $1.date }
        var total: Int64 = 0
        for e in list { total += e.size }
        while total > limit, !list.isEmpty {
            let e = list.removeFirst()
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }

    static func clear() {
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }
}

// MARK: - Страница на диске

final class PageSource {
    let key: String
    let url: URL
    let srcWidth: CGFloat        // исходные размеры в пикселях
    let srcHeight: CGFloat
    let outWidth: Int            // ширина, до которой уменьшаем при показе
    let stripSrcHeight: Int      // высота одной полосы в пикселях оригинала
    let stripCount: Int

    // Считаются один раз на главном потоке при старте (см. prepare()).
    private(set) static var maxOutWidth: Int = 1200
    private(set) static var stripOutHeight: Int = 1536

    static func prepare() {
        let s = UIScreen.main
        let longPx = max(s.bounds.width, s.bounds.height) * s.scale
        let shortPx = min(s.bounds.width, s.bounds.height) * s.scale
        var cap: CGFloat
        if MemoryInfo.isLowRAM {
            cap = min(longPx, max(1200, shortPx))        // iPad mini 2: 1536 px, iPhone 6/5s: 1200 px
        } else {
            cap = min(longPx, 2048)
        }
        if Power.isSaving { cap = min(cap, max(shortPx * 0.75, 600)) }
        maxOutWidth = Int(max(cap, 320))
        stripOutHeight = (MemoryInfo.isLowRAM || Power.isSaving) ? 1536 : 2048
    }

    // nil — если файл не удалось открыть как картинку. Само изображение НЕ декодируется.
    init?(key: String, url: URL) {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }

        let out = min(w, PageSource.maxOutWidth)
        let k = CGFloat(out) / CGFloat(w)
        let sh = max(Int((CGFloat(PageSource.stripOutHeight) / k).rounded(.down)), 64)

        self.key = key
        self.url = url
        self.srcWidth = CGFloat(w)
        self.srcHeight = CGFloat(h)
        self.outWidth = out
        self.stripSrcHeight = sh
        self.stripCount = (h + sh - 1) / sh
    }

    func srcRect(_ i: Int) -> CGRect {
        let y = i * stripSrcHeight
        let h = max(min(stripSrcHeight, Int(srcHeight) - y), 1)
        return CGRect(x: 0, y: y, width: Int(srcWidth), height: h)
    }

    // Декодирует ОДНУ полосу сразу в уменьшенном виде. Вызывать не с главного потока.
    func renderStrip(_ i: Int) -> UIImage? {
        guard i >= 0, i < stripCount else { return nil }
        let rect = srcRect(i)
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let full = CGImageSourceCreateImageAtIndex(src, 0, opts),
              let part = full.cropping(to: rect) else { return nil }

        let k = CGFloat(outWidth) / srcWidth
        let ow = max(outWidth, 1)
        let oh = max(Int((rect.height * k).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = Power.isSaving ? .low : .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        guard let img = ctx.makeImage() else { return nil }
        return UIImage(cgImage: img)
    }
}

// MARK: - Очередь отрисовки полос

final class StripTicket {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

// Одна полоса за раз (чтобы не раздувать память и не греть процессор). Последний запрос обслуживается первым:
// при быстрой прокрутке сначала рисуется то, что видно сейчас, а не то, что пролистали.
final class StripRenderer {
    static let shared = StripRenderer()

    private struct Job {
        let source: PageSource
        let index: Int
        let ticket: StripTicket
        let done: (UIImage?) -> Void
    }

    private let queue = DispatchQueue(label: "slashlib.strips", qos: .userInitiated)
    private let lock = NSLock()
    private var stack: [Job] = []
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = (MemoryInfo.isLowRAM ? 32 : 80) * 1_048_576
    }

    private func key(_ s: PageSource, _ i: Int) -> NSString {
        return "\(s.key)#\(i)" as NSString
    }

    func cached(_ s: PageSource, _ i: Int) -> UIImage? {
        return cache.object(forKey: key(s, i))
    }

    func purge() { cache.removeAllObjects() }

    func request(_ s: PageSource, _ i: Int, ticket: StripTicket, done: @escaping (UIImage?) -> Void) {
        lock.lock()
        stack.append(Job(source: s, index: i, ticket: ticket, done: done))
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        lock.lock()
        let job = stack.popLast()
        lock.unlock()
        guard let j = job, !j.ticket.isCancelled else { return }

        let k = key(j.source, j.index)
        var result: UIImage? = cache.object(forKey: k)
        if result == nil {
            autoreleasepool {
                result = j.source.renderStrip(j.index)
            }
            if let r = result {
                cache.setObject(r, forKey: k, cost: Int(r.size.width * r.size.height * 4))
            }
        }
        let finished = result
        DispatchQueue.main.async {
            if !j.ticket.isCancelled { j.done(finished) }
            MemoryGuard.checkSoftLimit()
        }
    }
}
