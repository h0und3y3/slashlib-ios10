import UIKit

// Синхронизация закладок, избранного, «недавних» и прочитанных глав между устройствами.
//
// Как это работает: данные лежат одним JSON-файлом в ПРИВАТНОМ Gist вашего аккаунта GitHub.
// Токен GitHub (с правом «gist») вводится на каждом устройстве один раз — второе устройство само находит
// тот же Gist. Конфликты решаются слиянием: у каждой записи побеждает более свежая, удаления помнятся
// («надгробия»), прочитанные главы объединяются.
//
// Почему не токен сайта: у lib.social нет проверенного мной API для истории чтения и обновления токена.
// Токен GitHub можно выпустить без срока действия — продлевать его не нужно.

struct SyncDocument: Codable {
    var version = 1
    var updated = Date()
    var bookmarks: [Bookmark] = []
    var favorites: [FavoriteItem] = []
    var recent: [Bookmark] = []
    var read: [String: [Int]] = [:]
    var tombstones: [String: Date] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, updated, bookmarks, favorites, recent, read, tombstones }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? Date()
        bookmarks = (try? c.decodeIfPresent([Bookmark].self, forKey: .bookmarks)) ?? []
        favorites = (try? c.decodeIfPresent([FavoriteItem].self, forKey: .favorites)) ?? []
        recent = (try? c.decodeIfPresent([Bookmark].self, forKey: .recent)) ?? []
        read = (try? c.decodeIfPresent([String: [Int]].self, forKey: .read)) ?? [:]
        tombstones = (try? c.decodeIfPresent([String: Date].self, forKey: .tombstones)) ?? [:]
    }
}

enum SyncMerge {
    static func ts(_ d: Date) -> Int { return Int(d.timeIntervalSince1970) }

    private static func newest<T>(_ items: [T], key: (T) -> String, date: (T) -> Date) -> [String: T] {
        var m: [String: T] = [:]
        for x in items {
            let k = key(x)
            if let e = m[k], ts(date(e)) >= ts(date(x)) { continue }
            m[k] = x
        }
        return m
    }

    static func merge(_ a: SyncDocument, _ b: SyncDocument) -> SyncDocument {
        var out = SyncDocument()

        var tomb = a.tombstones
        for (k, d) in b.tombstones {
            if let e = tomb[k], ts(e) >= ts(d) { continue }
            tomb[k] = d
        }
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        tomb = tomb.filter { $0.value > cutoff }
        out.tombstones = tomb

        let bm = newest(a.bookmarks + b.bookmarks, key: { "\($0.slug)#\($0.chapterId)" }, date: { $0.date })
        for (k, v) in bm {
            if let t = tomb["b:" + k], ts(t) >= ts(v.date) { continue }
            out.bookmarks.append(v)
        }

        let fav = newest(a.favorites + b.favorites, key: { $0.ref.slug }, date: { $0.date })
        for (k, v) in fav {
            if let t = tomb["f:" + k], ts(t) >= ts(v.date) { continue }
            out.favorites.append(v)
        }

        let rec = newest(a.recent + b.recent, key: { $0.slug }, date: { $0.date })
        for (k, v) in rec {
            if let t = tomb["r:" + k], ts(t) >= ts(v.date) { continue }
            out.recent.append(v)
        }

        var read: [String: Set<Int>] = [:]
        for (k, v) in a.read { read[k, default: []].formUnion(v) }
        for (k, v) in b.read { read[k, default: []].formUnion(v) }
        for (k, v) in read { out.read[k] = Array(v).sorted() }
        return out
    }

    // Отпечаток содержимого (без поля «updated»): по нему понимаем, изменилось ли что-то.
    static func signature(_ d: SyncDocument) -> String {
        var parts: [String] = []
        for b in d.bookmarks { parts.append("b|\(b.slug)#\(b.chapterId)|\(ts(b.date))|\(b.page)") }
        for f in d.favorites { parts.append("f|\(f.ref.slug)|\(ts(f.date))") }
        for r in d.recent { parts.append("r|\(r.slug)|\(ts(r.date))|\(r.chapterId)|\(r.page)") }
        for (k, v) in d.read { parts.append("x|\(k)|" + v.sorted().map { String($0) }.joined(separator: ",")) }
        for (k, v) in d.tombstones { parts.append("t|\(k)|\(ts(v))") }
        return parts.sorted().joined(separator: "\n")
    }
}

enum SyncError: LocalizedError {
    case unauthorized
    case http(Int, String?)
    case network(String)
    case badData

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Токен недействителен или истёк. Создайте новый (github.com/settings/tokens, право gist) и введите его заново."
        case .http(let code, let msg):
            if code == 403 { return "GitHub отказал (403): проверьте, что у токена есть право gist, или подождите — возможно, превышен лимит запросов." }
            return "Ошибка GitHub (HTTP \(code))" + (msg.map { ": " + $0 } ?? "")
        case .network(let m):
            return "Нет связи с GitHub: \(m)"
        case .badData:
            return "Не удалось разобрать данные синхронизации."
        }
    }
}

// Токен GitHub для синхронизации (Keychain, при его недоступности — UserDefaults).
enum SyncTokenStore {
    private static let service = "ru.slashlib.client.synctoken"
    private static let defaultsKey = "sync.token"

    static var token: String? {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
            return UserDefaults.standard.string(forKey: defaultsKey)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            guard let v = newValue, !v.isEmpty, let data = v.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
                UserDefaults.standard.set(v, forKey: defaultsKey)
            }
        }
    }
}

final class SyncService {
    static let shared = SyncService()
    static let didChange = Notification.Name("SyncServiceDidChange")

    private let fileName = "slashlib-sync.json"
    private let gistDescription = "Slashlib sync — закладки и прогресс чтения (не удаляйте)"
    private let gistKey = "sync.gistId"
    private let lastKey = "sync.lastSync"
    private let statusKey = "sync.status"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private var syncing = false
    private var applying = false
    private var pending: DispatchWorkItem?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    private init() {}

    var isEnabled: Bool { return SyncTokenStore.token != nil }

    var statusText: String {
        if !isEnabled { return "Синхронизация выключена" }
        return UserDefaults.standard.string(forKey: statusKey) ?? "Включена"
    }

    private func setStatus(_ s: String) {
        UserDefaults.standard.set(s, forKey: statusKey)
        NotificationCenter.default.post(name: SyncService.didChange, object: nil)
    }

    // MARK: запуск и триггеры

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(localChanged), name: BookmarkStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(localChanged), name: FavoritesStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(localChanged), name: ReadingProgress.didChange, object: nil)
        if isEnabled { syncNow() }
    }

    @objc private func localChanged() {
        guard isEnabled, !applying else { return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (Power.isSaving ? 60 : 15), execute: w)
    }

    // При возвращении в приложение — не чаще раза в 2 минуты.
    func syncIfDue() {
        guard isEnabled else { return }
        if let last = UserDefaults.standard.object(forKey: lastKey) as? Date, Date().timeIntervalSince(last) < 120 { return }
        syncNow()
    }

    func enable(token raw: String, completion: @escaping (String?) -> Void) {
        let token = AuthStore.normalize(raw)
        guard !token.isEmpty else { completion("Токен пустой"); return }
        request("GET", "/user", body: nil, token: token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                SyncTokenStore.token = token
                UserDefaults.standard.removeObject(forKey: self.gistKey)
                self.setStatus("Включена, синхронизирую…")
                completion(nil)
                self.syncNow()
            case .failure(let e):
                completion(e.localizedDescription)
            }
        }
    }

    func disable() {
        pending?.cancel()
        SyncTokenStore.token = nil
        UserDefaults.standard.removeObject(forKey: gistKey)
        UserDefaults.standard.removeObject(forKey: lastKey)
        setStatus("Синхронизация выключена")
    }

    // MARK: сама синхронизация

    func syncNow(background: Bool = false) {
        guard isEnabled, !syncing, let token = SyncTokenStore.token else { return }
        syncing = true
        setStatus("Синхронизация…")
        if background { beginBackgroundTask() }
        run(token: token, retried: false) { [weak self] result in
            guard let self = self else { return }
            self.syncing = false
            switch result {
            case .success:
                UserDefaults.standard.set(Date(), forKey: self.lastKey)
                let f = DateFormatter()
                f.dateFormat = "d MMM, HH:mm"
                f.locale = Locale(identifier: "ru_RU")
                self.setStatus("Синхронизировано: " + f.string(from: Date()))
            case .failure(let e):
                self.setStatus("Ошибка: " + e.localizedDescription)
            }
            self.endBackgroundTask()
        }
    }

    private func localDocument() -> SyncDocument {
        var d = SyncDocument()
        d.bookmarks = BookmarkStore.shared.all
        d.favorites = FavoritesStore.shared.all
        d.recent = ReadingProgress.shared.recent
        d.read = ReadingProgress.shared.readSnapshot()
        d.tombstones = Tombstones.shared.items
        return d
    }

    private func run(token: String, retried: Bool, done: @escaping (Result<Void, SyncError>) -> Void) {
        findGist(token: token) { [weak self] found in
            guard let self = self else { return }
            switch found {
            case .failure(let e):
                done(.failure(e))
            case .success(let gistId):
                guard let id = gistId else {
                    // Gist ещё нет — создаём из локальных данных.
                    self.createGist(token: token, doc: self.localDocument(), done: done)
                    return
                }
                self.fetchDocument(token: token, gistId: id) { fetched in
                    switch fetched {
                    case .failure(let e):
                        if case .http(404, _) = e, !retried {
                            UserDefaults.standard.removeObject(forKey: self.gistKey)   // Gist удалили — ищем/создаём заново
                            self.run(token: token, retried: true, done: done)
                        } else {
                            done(.failure(e))
                        }
                    case .success(let remote):
                        self.mergeAndPush(token: token, gistId: id, remote: remote, done: done)
                    }
                }
            }
        }
    }

    private func mergeAndPush(token: String, gistId: String, remote: SyncDocument,
                              done: @escaping (Result<Void, SyncError>) -> Void) {
        let local = localDocument()
        let merged = SyncMerge.merge(local, remote)

        if SyncMerge.signature(merged) != SyncMerge.signature(local) {
            applying = true
            BookmarkStore.shared.replaceAll(merged.bookmarks)
            FavoritesStore.shared.replaceAll(merged.favorites)
            ReadingProgress.shared.replace(recent: merged.recent, read: merged.read)
            Tombstones.shared.replaceAll(merged.tombstones)
            applying = false
        }

        if SyncMerge.signature(merged) == SyncMerge.signature(remote) {
            done(.success(()))        // на сервере уже то же самое
            return
        }
        var toPush = merged
        toPush.updated = Date()
        guard let content = encode(toPush) else { done(.failure(.badData)); return }
        let body: [String: Any] = ["files": [fileName: ["content": content]]]
        request("PATCH", "/gists/\(gistId)", body: body, token: token) { result in
            switch result {
            case .success: done(.success(()))
            case .failure(let e): done(.failure(e))
            }
        }
    }

    // MARK: GitHub API

    private func findGist(token: String, done: @escaping (Result<String?, SyncError>) -> Void) {
        if let saved = UserDefaults.standard.string(forKey: gistKey) { done(.success(saved)); return }
        request("GET", "/gists?per_page=100", body: nil, token: token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                done(.failure(e))
            case .success(let data):
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                for g in list {
                    if let files = g["files"] as? [String: Any], files[self.fileName] != nil, let id = g["id"] as? String {
                        UserDefaults.standard.set(id, forKey: self.gistKey)
                        done(.success(id))
                        return
                    }
                }
                done(.success(nil))
            }
        }
    }

    private func createGist(token: String, doc: SyncDocument, done: @escaping (Result<Void, SyncError>) -> Void) {
        guard let content = encode(doc) else { done(.failure(.badData)); return }
        let body: [String: Any] = [
            "description": gistDescription,
            "public": false,
            "files": [fileName: ["content": content]]
        ]
        request("POST", "/gists", body: body, token: token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                done(.failure(e))
            case .success(let data):
                if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = obj["id"] as? String {
                    UserDefaults.standard.set(id, forKey: self.gistKey)
                    done(.success(()))
                } else {
                    done(.failure(.badData))
                }
            }
        }
    }

    private func fetchDocument(token: String, gistId: String, done: @escaping (Result<SyncDocument, SyncError>) -> Void) {
        request("GET", "/gists/\(gistId)", body: nil, token: token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                done(.failure(e))
            case .success(let data):
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let files = obj["files"] as? [String: Any],
                      let file = files[self.fileName] as? [String: Any] else {
                    done(.success(SyncDocument()))     // файл удалили — считаем, что пусто
                    return
                }
                if (file["truncated"] as? Bool) == true, let raw = file["raw_url"] as? String, let url = URL(string: raw) {
                    self.session.dataTask(with: url) { d, _, err in
                        DispatchQueue.main.async {
                            if let d = d, let doc = self.decode(d) {
                                done(.success(doc))
                            } else {
                                let failure: SyncError
                                if let err = err { failure = SyncError.network(err.localizedDescription) } else { failure = SyncError.badData }
                                done(.failure(failure))
                            }
                        }
                    }.resume()
                    return
                }
                if let text = file["content"] as? String, let d = text.data(using: .utf8), let doc = decode(d) {
                    done(.success(doc))
                } else {
                    done(.success(SyncDocument()))
                }
            }
        }
    }

    private func encode(_ doc: SyncDocument) -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(doc) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode(_ data: Data) -> SyncDocument? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SyncDocument.self, from: data)
    }

    // Колбэк всегда на главном потоке.
    private func request(_ method: String, _ path: String, body: [String: Any]?, token: String,
                         completion: @escaping (Result<Data, SyncError>) -> Void) {
        guard let url = URL(string: "https://api.github.com" + path) else { completion(.failure(.badData)); return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("token " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Slashlib", forHTTPHeaderField: "User-Agent")      // GitHub требует User-Agent
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: req) { data, resp, err in
            let result: Result<Data, SyncError>
            if let err = err {
                result = .failure(.network(err.localizedDescription))
            } else if let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 {
                    result = .failure(.unauthorized)
                } else if (200...299).contains(http.statusCode), let data = data {
                    result = .success(data)
                } else {
                    var msg: String?
                    if let data = data,
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        msg = obj["message"] as? String
                    }
                    result = .failure(.http(http.statusCode, msg))
                }
            } else {
                result = .failure(.badData)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: фоновая задача (дать закончить отправку при сворачивании)

    private func beginBackgroundTask() {
        guard bgTask == UIBackgroundTaskIdentifier.invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "slashlib.sync") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTask != UIBackgroundTaskIdentifier.invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = UIBackgroundTaskIdentifier.invalid
    }
}
