import UIKit

// MARK: - Ошибки загрузки картинок (показываются на самой странице вместо чёрного экрана)

enum ImageLoadError: LocalizedError {
    case network(String)
    case http(Int)
    case webp
    case notImage

    var isNotFound: Bool {
        if case .http(let code) = self { return code == 404 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Ошибка сети: \(m)"
        case .http(let c): return "Сервер картинок ответил HTTP \(c)"
        case .webp: return "Картинка в формате WebP — iOS 10 его не умеет показывать"
        case .notImage: return "Сервер вернул не картинку (или файл повреждён)"
        }
    }
}

// MARK: - Хосты картинок

final class ImageServers {
    struct Entry {
        let url: String
        let siteIds: [Int]
        let rank: Int
    }

    static let shared = ImageServers()
    private var entries: [Entry] = []

    func update(_ new: [Entry]) { entries = new }

    // Сначала хосты, подходящие сайту тайтла, потом остальные, в конце — адрес из Config.
    func urls(for site: Int?) -> [String] {
        let sid = site ?? Sites.defaultId
        func matches(_ e: Entry) -> Bool { return e.siteIds.isEmpty || e.siteIds.contains(sid) }
        let sorted = entries.sorted { a, b in
            let am = matches(a), bm = matches(b)
            if am != bm { return am }
            return a.rank < b.rank
        }
        var out: [String] = []
        for raw in sorted.map({ $0.url }) + [Config.imageBase] + Config.extraImageServers {
            let t = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if !t.isEmpty && !out.contains(t) { out.append(t) }
        }
        return out
    }
}

// MARK: - Загрузчик картинок
// Все публичные методы вызывать с главного потока; колбэки приходят на главном.

final class ImageLoader {
    static let shared = ImageLoader()

    private let coverCache = NSCache<NSString, UIImage>()
    private let sourceCache = NSCache<NSString, PageSource>()
    private var waiting: [String: [(Result<PageSource, ImageLoadError>) -> Void]] = [:]
    private let coverSession: URLSession
    private let pageSession: URLSession
    private let fileQueue = DispatchQueue(label: "slashlib.pagefiles", qos: .userInitiated, attributes: .concurrent)

    private init() {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 4
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 90
        c.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024, diskPath: "slashlib-covers")
        coverSession = URLSession(configuration: c)

        // Страницы кэшируем сами (в файлы), поэтому системный кэш тут не нужен.
        let p = URLSessionConfiguration.default
        p.httpMaximumConnectionsPerHost = 3
        p.timeoutIntervalForRequest = 25
        p.timeoutIntervalForResource = 120
        p.urlCache = nil
        p.requestCachePolicy = .reloadIgnoringLocalCacheData
        pageSession = URLSession(configuration: p)

        coverCache.countLimit = 150
        sourceCache.countLimit = 200
    }

    func purgeMemory() {
        coverCache.removeAllObjects()
        sourceCache.removeAllObjects()
    }

    func clearAllCaches() {
        purgeMemory()
        StripRenderer.shared.purge()
        PageFiles.clear()
        coverSession.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: обложки

    func load(_ path: String, site: Int? = nil, done: @escaping (UIImage?) -> Void) {
        let key = path as NSString
        if let img = coverCache.object(forKey: key) { done(img); return }
        fetchCover(candidates(for: path, site: site), site, 0, 0, nil) { [weak self] result in
            if case .success(let img) = result {
                self?.coverCache.setObject(img, forKey: key)
                done(img)
            } else {
                done(nil)
            }
        }
    }

    // MARK: страницы глав

    func cachedSource(_ path: String) -> PageSource? {
        return sourceCache.object(forKey: path as NSString)
    }

    func loadPage(_ path: String, site: Int? = nil, done: @escaping (Result<PageSource, ImageLoadError>) -> Void) {
        if let hit = sourceCache.object(forKey: path as NSString) { done(.success(hit)); return }
        if waiting[path] != nil { waiting[path]?.append(done); return }
        waiting[path] = [done]

        let fileURL = PageFiles.url(for: path)
        let offlineURL = PageFiles.offlineURL(for: path)
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            // Глава скачана пользователем — читаем из неё.
            if let s = PageSource(key: path, url: offlineURL) {
                self.deliver(path, .success(s))
                return
            }
            // Уже скачана раньше (кэш)? Тогда сеть не нужна.
            if let s = PageSource(key: path, url: fileURL) {
                PageFiles.touch(fileURL)
                self.deliver(path, .success(s))
                return
            }
            try? FileManager.default.removeItem(at: fileURL)   // вдруг там битый файл
            DispatchQueue.main.async {
                Breadcrumbs.shared.log("скачиваю страницу …\(path.suffix(28))")
                self.downloadPage(self.candidates(for: path, site: site), site, 0, 0, nil, path, fileURL) { result in
                    switch result {
                    case .success(let s):
                        Breadcrumbs.shared.log("страница скачана: \(Int(s.srcWidth))×\(Int(s.srcHeight)), полос: \(s.stripCount)")
                    case .failure(let e):
                        Breadcrumbs.shared.log("ОШИБКА загрузки страницы: \(e.localizedDescription)")
                    }
                    self.deliver(path, result)
                }
            }
        }
    }

    // Сохраняет страницу в «скачанное». Колбэк получает размер файла.
    func saveOffline(_ path: String, site: Int? = nil, done: @escaping (Result<Int64, ImageLoadError>) -> Void) {
        let dest = PageFiles.offlineURL(for: path)
        let cached = PageFiles.url(for: path)
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            if PageSource(key: path, url: dest) != nil {
                let size = PageFiles.fileSize(dest)
                DispatchQueue.main.async { done(.success(size)) }
                return
            }
            // Страница уже лежит в кэше — копируем, сеть не нужна.
            if PageSource(key: path, url: cached) != nil {
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: cached, to: dest)) != nil {
                    let size = PageFiles.fileSize(dest)
                    DispatchQueue.main.async { done(.success(size)) }
                    return
                }
            }
            try? fm.removeItem(at: dest)
            DispatchQueue.main.async {
                self.downloadPage(self.candidates(for: path, site: site), site, 0, 0, nil, path, dest) { result in
                    switch result {
                    case .success: done(.success(PageFiles.fileSize(dest)))
                    case .failure(let e): done(.failure(e))
                    }
                }
            }
        }
    }

    private func deliver(_ path: String, _ result: Result<PageSource, ImageLoadError>) {
        DispatchQueue.main.async {
            if case .success(let s) = result { self.sourceCache.setObject(s, forKey: path as NSString) }
            let callbacks = self.waiting.removeValue(forKey: path) ?? []
            for cb in callbacks { cb(result) }
        }
    }

    // MARK: адреса

    private func candidates(for path: String, site: Int?) -> [URL] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        let servers = ImageServers.shared.urls(for: site)

        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            add(path)
            // Если картинка лежит на одном из наших хостов — пробуем запасные хосты с тем же путём.
            if let u = URL(string: path), let host = u.host,
               servers.contains(where: { URL(string: $0)?.host == host }) {
                var rel = u.path
                if let q = u.query { rel += "?" + q }
                for s in servers { add(s + rel) }
            }
        } else if path.hasPrefix("//") {
            let rest = String(path.dropFirst(2))
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            if first.contains(".") {
                add("https:" + path)                          // «//host/path»
            } else {
                for s in servers { add(s + "/" + rest) }      // «//manga/…» — это путь
            }
        } else {
            let p = path.hasPrefix("/") ? path : "/" + path
            for s in servers { add(s + p) }
        }

        return out.compactMap { s in
            if let u = URL(string: s) { return u }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&'()*+,/:;=?@[]%-._~"))
            return s.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
        }
    }

    private func makeRequest(_ url: URL, site: Int?) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        req.setValue(Sites.referer(site), forHTTPHeaderField: "Referer")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        // WebP намеренно не заявляем: вдруг CDN умеет отдать JPEG/PNG.
        req.setValue("image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        return req
    }

    private func isTransient(_ e: NSError) -> Bool {
        return e.domain == NSURLErrorDomain &&
            [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(e.code)
    }

    // 404 на одном хосте не должен затирать более полезную ошибку с другого.
    private func better(_ last: ImageLoadError?, _ new: ImageLoadError) -> ImageLoadError {
        if let l = last, !l.isNotFound { return l }
        return new
    }

    // MARK: сеть: обложки (в память)

    private func fetchCover(_ urls: [URL], _ site: Int?, _ index: Int, _ attempt: Int, _ last: ImageLoadError?,
                            _ done: @escaping (Result<UIImage, ImageLoadError>) -> Void) {
        guard index < urls.count else { done(.failure(last ?? .notImage)); return }
        coverSession.dataTask(with: makeRequest(urls[index], site: site)) { [weak self] data, resp, err in
            guard let self = self else { return }
            var failure: ImageLoadError
            var transient = false
            if let err = err {
                failure = .network(err.localizedDescription)
                transient = self.isTransient(err as NSError)
            } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = .http(http.statusCode)
                transient = http.statusCode >= 500 || http.statusCode == 429
            } else if let data = data, let img = UIImage(data: data) {
                DispatchQueue.main.async { done(.success(img)) }
                return
            } else {
                failure = .notImage
            }
            let best = self.better(last, failure)
            DispatchQueue.main.async {
                if transient && attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.fetchCover(urls, site, index, attempt + 1, best, done)
                    }
                } else {
                    self.fetchCover(urls, site, index + 1, 0, best, done)
                }
            }
        }.resume()
    }

    // MARK: сеть: страницы (сразу в файл)

    private func downloadPage(_ urls: [URL], _ site: Int?, _ index: Int, _ attempt: Int, _ last: ImageLoadError?,
                              _ key: String, _ dest: URL,
                              _ done: @escaping (Result<PageSource, ImageLoadError>) -> Void) {
        guard index < urls.count else { done(.failure(last ?? .notImage)); return }
        pageSession.downloadTask(with: makeRequest(urls[index], site: site)) { [weak self] tmp, resp, err in
            guard let self = self else { return }
            var failure: ImageLoadError
            var transient = false

            if let err = err {
                failure = .network(err.localizedDescription)
                transient = self.isTransient(err as NSError)
            } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = .http(http.statusCode)
                transient = http.statusCode >= 500 || http.statusCode == 429
            } else if let tmp = tmp {
                // Временный файл удаляется сразу после выхода из этого блока — переносим его тут же.
                let stored = ImageLoader.store(tmp, to: dest, key: key)
                if let s = stored.0 {
                    DispatchQueue.main.async { done(.success(s)) }
                    return
                }
                failure = stored.1 ?? .notImage
            } else {
                failure = .notImage
            }

            let best = self.better(last, failure)
            DispatchQueue.main.async {
                if transient && attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.downloadPage(urls, site, index, attempt + 1, best, key, dest, done)
                    }
                } else {
                    self.downloadPage(urls, site, index + 1, 0, best, key, dest, done)
                }
            }
        }.resume()
    }

    private static func store(_ tmp: URL, to dest: URL, key: String) -> (PageSource?, ImageLoadError?) {
        if isWebP(at: tmp) { return (nil, .webp) }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            return (nil, .network("не удалось сохранить файл страницы (нет места?)"))
        }
        if let s = PageSource(key: key, url: dest) { return (s, nil) }
        try? fm.removeItem(at: dest)
        return (nil, .notImage)
    }

    private static func isWebP(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        let d = h.readData(ofLength: 12)
        h.closeFile()
        guard d.count == 12 else { return false }
        let b = [UInt8](d)
        return b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&   // RIFF
               b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50     // WEBP
    }
}

extension UIViewController {
    func showError(_ error: Error) {
        let a = UIAlertController(title: "Ошибка", message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
