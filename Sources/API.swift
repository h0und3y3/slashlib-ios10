import Foundation

// MARK: - Терпимое декодирование
// Сервер иногда отдаёт числа строками, строки числами или null. Раньше один такой
// элемент ронял разбор всего списка/главы. Теперь неудачный элемент пропускается.

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        // Int(d) падает с ошибкой на NaN/огромных числах — поэтому Int(exactly:)
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(exactly: d.rounded()) }
        return nil
    }
}

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Модели

struct Cover: Decodable {
    let thumbnail: String?
    let full: String?
    private enum CodingKeys: String, CodingKey { case thumbnail; case full = "default" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thumbnail = c.flexString(.thumbnail)
        full = c.flexString(.full)
    }
}

struct Labeled: Decodable {
    let label: String?
    private enum CodingKeys: String, CodingKey { case label }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.flexString(.label)
    }
}

struct Named: Decodable {
    let name: String?
    private enum CodingKeys: String, CodingKey { case name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
    }
}

struct Title: Decodable {
    let id: Int
    let name: String?
    let rus_name: String?
    let eng_name: String?
    let slug_url: String?
    let cover: Cover?
    let site: Int?
    let kind: String?          // тип: манга/манхва/…
    let age: String?           // возрастное ограничение
    let state: String?         // статус тайтла
    let genres: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, rus_name, eng_name, slug_url, cover, site, site_id, type, ageRestriction, status, genres
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id) ?? 0
        name = c.flexString(.name)
        rus_name = c.flexString(.rus_name)
        eng_name = c.flexString(.eng_name)
        slug_url = c.flexString(.slug_url)
        cover = (try? c.decodeIfPresent(Cover.self, forKey: .cover)) ?? nil
        site = c.flexInt(.site) ?? c.flexInt(.site_id)
        kind = ((try? c.decodeIfPresent(Labeled.self, forKey: .type)) ?? nil)?.label
        age = ((try? c.decodeIfPresent(Labeled.self, forKey: .ageRestriction)) ?? nil)?.label
        state = ((try? c.decodeIfPresent(Labeled.self, forKey: .status)) ?? nil)?.label
        genres = ((try? c.decodeIfPresent([Lossy<Named>].self, forKey: .genres)) ?? nil)?
            .compactMap { $0.value?.name } ?? []
    }

    var display: String {
        for s in [rus_name, name, eng_name] {
            if let s = s, !s.isEmpty { return s }
        }
        return "—"
    }

    // Если у тайтла нет slug_url, API обычно принимает и числовой id.
    var slug: String {
        if let s = slug_url, !s.isEmpty { return s }
        return String(id)
    }

    var ref: TitleRef {
        return TitleRef(slug: slug, name: display, cover: cover?.thumbnail ?? cover?.full, site: site)
    }

    // Теги-плашки для карточки: тип, возраст, статус, пара жанров.
    var chips: [String] {
        var out: [String] = []
        if let k = kind { out.append(k) }
        if let a = age { out.append(a) }
        if let st = state { out.append(st) }
        for g in genres.prefix(2) { out.append(g) }
        return out
    }
}

struct TitleList: Decodable {
    let data: [Title]
    private enum CodingKeys: String, CodingKey { case data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode([Lossy<Title>].self, forKey: .data).compactMap { $0.value }
    }
}

struct Chapter {
    let id: Int
    let volume: String
    let number: String
    let name: String
    let branchIds: [Int]

    init(id: Int, volume: String, number: String, name: String, branchIds: [Int]) {
        self.id = id
        self.volume = volume
        self.number = number
        self.name = name
        self.branchIds = branchIds
    }

    var display: String {
        let v = volume.isEmpty ? "?" : volume
        let n = number.isEmpty ? "?" : number
        return "Том \(v) · Глава \(n)" + (name.isEmpty ? "" : " — \(name)")
    }

    var shortDisplay: String {
        let v = volume.isEmpty ? "?" : volume
        let n = number.isEmpty ? "?" : number
        return "Т\(v) · Гл. \(n)"
    }

    var sortKey: (Double, Double) {
        return (Double(volume) ?? 0, Double(number) ?? 0)
    }
}

extension Chapter {
    static func sortedAscending(_ list: [Chapter]) -> [Chapter] {
        return list.enumerated().sorted { a, b in
            let ka = a.element.sortKey, kb = b.element.sortKey
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a.offset < b.offset
        }.map { $0.element }
    }
}

extension Chapter: Decodable {
    private enum CodingKeys: String, CodingKey { case id, volume, number, name, branches }

    private struct BranchInfo: Decodable {
        let branchId: Int?
        private enum CodingKeys: String, CodingKey { case branch_id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            branchId = c.flexInt(.branch_id)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let branches = (try? c.decodeIfPresent([Lossy<BranchInfo>].self, forKey: .branches)) ?? []
        var ids: [Int] = []
        for b in branches {
            if let id = b.value?.branchId, !ids.contains(id) { ids.append(id) }
        }
        self.init(id: c.flexInt(.id) ?? 0,
                  volume: c.flexString(.volume) ?? "",
                  number: c.flexString(.number) ?? "",
                  name: c.flexString(.name) ?? "",
                  branchIds: ids)
    }
}

struct ChapterList: Decodable {
    let data: [Chapter]
    private enum CodingKeys: String, CodingKey { case data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode([Lossy<Chapter>].self, forKey: .data).compactMap { $0.value }
    }
}

struct Page: Decodable {
    let url: String
    let width: Int?
    let height: Int?
    private enum CodingKeys: String, CodingKey { case url, width, height }

    init(url: String, width: Int?, height: Int?) {
        self.url = url
        self.width = width
        self.height = height
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let u = c.flexString(.url), !u.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: c.codingPath, debugDescription: "page without url"))
        }
        url = u
        width = c.flexInt(.width)
        height = c.flexInt(.height)
    }
}

struct ChapterData: Decodable {
    let pages: [Page]
    private enum CodingKeys: String, CodingKey { case pages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = (try? c.decode([Lossy<Page>].self, forKey: .pages))?.compactMap { $0.value } ?? []
    }
}
struct ChapterResponse: Decodable { let data: ChapterData }

// Подробности о тайтле. Читаются «вручную» из JSON, поэтому любое отсутствующее или
// изменившееся поле просто пропускается, а не ломает экран. ПРОВЕРИТЬ: имена полей.
struct TitleDetails {
    var summary: String?
    var status: String?
    var type: String?
    var age: String?
    var year: String?
    var rating: String?
    var genres: [String] = []
    var tags: [String] = []
    var cover: String?

    init(json d: [String: Any]) {
        func text(_ v: Any?) -> String? {
            if let s = v as? String, !s.isEmpty { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        func label(_ v: Any?) -> String? {
            return text((v as? [String: Any])?["label"])
        }
        func names(_ v: Any?) -> [String] {
            return ((v as? [[String: Any]]) ?? []).compactMap { text($0["name"]) }
        }
        summary = text(d["summary"])
        status = label(d["status"])
        type = label(d["type"])
        age = label(d["ageRestriction"])
        year = text(d["releaseDateString"]) ?? text(d["releaseDate"])
        if let r = d["rating"] as? [String: Any], let avg = text(r["average"]) {
            if let votes = text(r["votes"]) { rating = "\(avg) (\(votes))" } else { rating = avg }
        }
        genres = names(d["genres"])
        tags = names(d["tags"])
        let c = d["cover"] as? [String: Any]
        cover = text(c?["default"]) ?? text(c?["thumbnail"])
    }
}

struct Me: Decodable { let username: String? }
struct MeResponse: Decodable { let data: Me }

// MARK: - Ошибки

enum APIError: LocalizedError {
    case http(Int, String?)
    case emptyChapter
    case decoding

    var isAuth: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg):
            var text: String
            switch code {
            case 401, 403:
                text = "Доступ закрыт (HTTP \(code)). Если у тайтла возрастное ограничение или он только для авторизованных — откройте «Аккаунт» и вставьте токен."
            case 404:
                text = "Не найдено (HTTP 404)."
            case 429:
                text = "Слишком много запросов (HTTP 429). Подождите немного и повторите."
            case 500...599:
                text = "Сервер временно недоступен (HTTP \(code))."
            default:
                text = "Ошибка сервера (HTTP \(code))."
            }
            if let m = msg, !m.isEmpty { text += "\n\(m)" }
            return text
        case .emptyChapter:
            return "В этой главе нет страниц: сервер вернул пустой список. Возможно, глава закрыта, платная или удалена."
        case .decoding:
            return "Не удалось разобрать ответ сервера. Возможно, формат API изменился."
        }
    }
}

// MARK: - API

final class API {
    static let shared = API()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        return URLSession(configuration: cfg)
    }()

    private static func serverMessage(_ data: Data?) -> String? {
        guard let data = data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["message"] as? String
    }

    // Колбэк вызывается НЕ на главном потоке.
    private func request(_ path: String, _ query: [URLQueryItem], site: Int?,
                         done: @escaping (Result<Data, Error>) -> Void) {
        guard var c = URLComponents(string: Config.apiBase + path) else {
            done(.failure(URLError(.badURL))); return
        }
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { done(.failure(URLError(.badURL))); return }
        var req = URLRequest(url: url)
        req.setValue(Sites.headerValue(site), forHTTPHeaderField: "Site-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Sites.referer(site), forHTTPHeaderField: "Referer")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        if let t = AuthStore.token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: req) { data, resp, err in
            if let err = err {
                done(.failure(err))
            } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                done(.failure(APIError.http(http.statusCode, API.serverMessage(data))))
            } else if let data = data {
                done(.success(data))
            } else {
                done(.failure(URLError(.badServerResponse)))
            }
        }.resume()
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem], _ type: T.Type, site: Int?,
                                   done: @escaping (Result<T, Error>) -> Void) {
        request(path, query, site: site) { result in
            let out: Result<T, Error>
            switch result {
            case .failure(let e):
                out = .failure(e)
            case .success(let data):
                do { out = .success(try JSONDecoder().decode(type, from: data)) }
                catch { out = .failure(APIError.decoding) }
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    private func encoded(_ slug: String) -> String {
        return slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
    }

    // Если сайт тайтла неизвестен, пробуем включённые сайты по очереди и возвращаем тот, что ответил.
    private func resolve<T>(_ site: Int?,
                            _ attempt: @escaping (Int?, @escaping (Result<T, Error>) -> Void) -> Void,
                            done: @escaping (Result<(T, Int?), Error>) -> Void) {
        let candidates: [Int?] = site != nil ? [site] : (Prefs.mangalibEnabled ? [Sites.slashlib, Sites.mangalib] : [nil])
        var last: Error = URLError(.unknown)
        func next(_ i: Int) {
            if i >= candidates.count { done(.failure(last)); return }
            attempt(candidates[i]) { result in
                switch result {
                case .success(let v): done(.success((v, candidates[i])))
                case .failure(let e):
                    last = e
                    next(i + 1)
                }
            }
        }
        next(0)
    }

    // genreId — фильтр по жанру (ПРОВЕРИТЬ: параметр genres[]). Сайты берутся из настроек.
    func catalog(query: String?, page: Int, genreId: Int? = nil,
                 done: @escaping (Result<TitleList, Error>) -> Void) {
        var q = Sites.enabled.map { URLQueryItem(name: "site_id[]", value: String($0)) }
        if let s = query, !s.isEmpty { q.append(URLQueryItem(name: "q", value: s)) }
        if let g = genreId { q.append(URLQueryItem(name: "genres[]", value: String(g))) }
        if page > 1 { q.append(URLQueryItem(name: "page", value: String(page))) }
        // Какой сайт указывать в заголовке: единственный включённый, иначе по умолчанию.
        get("/manga", q, TitleList.self, site: Sites.enabled.count == 1 ? Sites.enabled[0] : nil, done: done)
    }

    // ПРОВЕРИТЬ: список жанров из /constants.
    func genres(done: @escaping ([(id: Int, name: String)]) -> Void) {
        request("/constants", [URLQueryItem(name: "fields[]", value: "genres")], site: nil) { result in
            var out: [(id: Int, name: String)] = []
            if case .success(let data) = result,
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let d = root["data"] as? [String: Any],
               let list = d["genres"] as? [[String: Any]] {
                for g in list {
                    guard let name = g["name"] as? String, let id = (g["id"] as? NSNumber)?.intValue else { continue }
                    out.append((id: id, name: name))
                }
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    // Список глав. В ответе — ещё и сайт, на котором тайтл нашёлся.
    func chapters(slug: String, site: Int?, done: @escaping (Result<(ChapterList, Int?), Error>) -> Void) {
        resolve(site, { s, cb in
            self.get("/manga/\(self.encoded(slug))/chapters", [], ChapterList.self, site: s, done: cb)
        }, done: done)
    }

    // Страницы главы. Если у главы несколько веток (переводчиков) и первая пустая/закрыта —
    // пробуем остальные, и в конце запрос вообще без ветки.
    func pages(slug: String, chapter: Chapter, site: Int?, done: @escaping (Result<[Page], Error>) -> Void) {
        resolve(site, { s, cb in
            self.pagesOnSite(slug: slug, chapter: chapter, site: s, done: cb)
        }, done: { result in
            switch result {
            case .success(let r): done(.success(r.0))
            case .failure(let e): done(.failure(e))
            }
        })
    }

    private func pagesOnSite(slug: String, chapter: Chapter, site: Int?,
                             done: @escaping (Result<[Page], Error>) -> Void) {
        var base: [URLQueryItem] = []
        if !chapter.number.isEmpty { base.append(URLQueryItem(name: "number", value: chapter.number)) }
        if !chapter.volume.isEmpty { base.append(URLQueryItem(name: "volume", value: chapter.volume)) }
        var attempts: [[URLQueryItem]] = chapter.branchIds.map {
            base + [URLQueryItem(name: "branch_id", value: String($0))]
        }
        attempts.append(base)

        let path = "/manga/\(encoded(slug))/chapter"
        var lastError: Error = APIError.emptyChapter

        func next(_ i: Int) {
            if i >= attempts.count { done(.failure(lastError)); return }
            get(path, attempts[i], ChapterResponse.self, site: site) { result in
                switch result {
                case .success(let r):
                    if r.data.pages.isEmpty { next(i + 1) } else { done(.success(r.data.pages)) }
                case .failure(let e):
                    let keepOld = (lastError as? APIError)?.isAuth ?? false
                    if !keepOld { lastError = e }
                    next(i + 1)
                }
            }
        }
        next(0)
    }

    func titleDetails(slug: String, site: Int?, done: @escaping (Result<TitleDetails, Error>) -> Void) {
        let q = ["summary", "genres", "tags"].map { URLQueryItem(name: "fields[]", value: $0) }
        resolve(site, { s, cb in
            self.request("/manga/\(self.encoded(slug))", q, site: s) { result in
                switch result {
                case .failure(let e):
                    cb(.failure(e))
                case .success(let data):
                    if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let d = root["data"] as? [String: Any] {
                        cb(.success(TitleDetails(json: d)))
                    } else {
                        cb(.failure(APIError.decoding))
                    }
                }
            }
        }, done: { result in
            let out: Result<TitleDetails, Error>
            switch result {
            case .success(let r): out = .success(r.0)
            case .failure(let e): out = .failure(e)
            }
            DispatchQueue.main.async { done(out) }
        })
    }

    // ПРОВЕРИТЬ: путь проверки токена
    func me(done: @escaping (Result<MeResponse, Error>) -> Void) {
        get("/auth/me", [], MeResponse.self, site: nil, done: done)
    }

    // Список хостов картинок от сервера (ПРОВЕРИТЬ: формат ответа). При неудаче остаётся Config.imageBase.
    func loadImageServers() {
        request("/constants", [URLQueryItem(name: "fields[]", value: "imageServers")], site: nil) { result in
            guard case .success(let data) = result,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let d = root["data"] as? [String: Any],
                  let list = d["imageServers"] as? [[String: Any]] else { return }
            var entries: [ImageServers.Entry] = []
            for (idx, s) in list.enumerated() {
                guard let url = s["url"] as? String, !url.isEmpty else { continue }
                let ids = (s["site_ids"] as? [Int]) ?? []
                var rank = idx
                switch s["id"] as? String {
                case "main"?: rank = -2
                case "secondary"?: rank = -1
                default: break
                }
                entries.append(ImageServers.Entry(url: url, siteIds: ids, rank: rank))
            }
            DispatchQueue.main.async { ImageServers.shared.update(entries) }
        }
    }
}
