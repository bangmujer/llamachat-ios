import Foundation
import Security

/// Kredensial pencarian Google milik pengguna, disimpan di Keychain.
///
/// Tool `webSearch` bisa memakai Google Programmable Search (Custom
/// Search JSON API) kalau pengguna mengisi API key + Search Engine ID
/// (CX) di Settings. Keduanya disimpan di Keychain perangkat — bukan
/// UserDefaults — supaya tidak tersimpan sebagai teks polos, tidak
/// pernah ditulis ke log, dan tidak pernah dikirim ke mana pun kecuali
/// ke endpoint Custom Search Google saat pencarian dipakai. Kosongkan
/// salah satunya untuk menghapusnya dari Keychain.
public enum WebSearchSettings {
    private static let service = "com.bangmujer.llamachat"
    private static let apiKeyAccount = "google-search-api-key"
    private static let engineIDAccount = "google-search-engine-id"

    public static var apiKey: String { value(forAccount: apiKeyAccount) ?? "" }
    public static var engineID: String { value(forAccount: engineIDAccount) ?? "" }

    public static var isGoogleConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !engineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func setApiKey(_ newValue: String) {
        set(newValue, forAccount: apiKeyAccount)
    }

    public static func setEngineID(_ newValue: String) {
        set(newValue, forAccount: engineIDAccount)
    }

    private static func value(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func set(_ newValue: String, forAccount account: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
