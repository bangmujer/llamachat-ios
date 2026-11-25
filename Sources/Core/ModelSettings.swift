import Foundation

/// Pengaturan per-model yang disimpan di UserDefaults.
///
/// Kunci: `llamachat.modelSettings.<nama file>`. Disimpan saat pengguna
/// menekan Terapkan di Settings; dibaca saat model di-load supaya
/// parameter + template yang terakhir dipakai untuk file itu yang
/// berlaku, bukan default device.
public enum ModelSettingsStore {
    private struct Stored: Codable {
        var parameters: SamplingParameters
        var template: ChatTemplateKind
    }

    private static func key(for fileName: String) -> String {
        "llamachat.modelSettings.\(fileName)"
    }

    public static func load(for fileName: String) -> (parameters: SamplingParameters, template: ChatTemplateKind)? {
        guard let data = UserDefaults.standard.data(forKey: key(for: fileName)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return (stored.parameters, stored.template)
    }

    public static func save(for fileName: String, parameters: SamplingParameters, template: ChatTemplateKind) {
        let stored = Stored(parameters: parameters, template: template)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key(for: fileName))
    }
}
