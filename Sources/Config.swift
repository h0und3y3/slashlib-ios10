import Foundation

// ВСЁ, ЧТО МОЖЕТ ПОМЕНЯТЬСЯ НА САЙТЕ, ЛЕЖИТ ЗДЕСЬ.
// Эндпоинты неофициальные и мной не проверены на живом сервере.
enum Config {
    static let apiBase = "https://api.lib.social/api"
    static let siteId = "2"                            // ПРОВЕРИТЬ: id Slashlib в сети lib.social
    static let imageBase = "https://img2.imglib.info"  // ПРОВЕРИТЬ: хост картинок страниц
    // Запасные хосты картинок (пробуются, если основной не отдал страницу).
    // Основной список приложение пытается получить само: GET /constants?fields[]=imageServers
    static let extraImageServers: [String] = []
    static let referer = "https://slashlib.me/"
    // Браузерный User-Agent: часть CDN режет запросы с «голым» CFNetwork.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_3 like Mac OS X) AppleWebKit/603.3.8 (KHTML, like Gecko) Version/10.0 Mobile/14G60 Safari/602.1"
}
