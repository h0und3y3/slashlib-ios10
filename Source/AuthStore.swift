import Foundation
import Security

// Хранит токен в Keychain. Если Keychain недоступен (бывает при фейковой
// подписи ldid без entitlements), используется UserDefaults.
enum AuthStore {
    private static let service = "ru.slashlib.client.token"
    private static let defaultsKey = "auth.token"

    static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
