import Foundation
import Security
import StewardCore

/// The one place the app gets a model for the feed.
///
/// Undecided (see the relay plan): the owner never handles a key. The likely
/// shape is that the relay creates a capped key for this phone and the app
/// keeps it in the Keychain slot below. Until then, debug runs take the key
/// from the launch environment, like chat's `-uiState agent`.
nonisolated enum ModelAccess {
    struct Setup {
        var key: String
        var model: String
        var baseURL: URL
    }

    static let openRouter = URL(string: "https://openrouter.ai/api/v1")!

    /// A model that can search the web, or `nil` when none is set up.
    static func feedModel() -> (any ModelClient)? {
        guard let setup = provisioned() ?? debugSetup() else { return nil }
        return OpenAICompatibleClient(baseURL: setup.baseURL, model: withWebSearch(setup.model, on: setup.baseURL), apiKey: setup.key)
    }

    /// OpenRouter adds web search to any model with the `:online` suffix.
    static func withWebSearch(_ model: String, on baseURL: URL) -> String {
        guard baseURL.host() == openRouter.host(), !model.hasSuffix(":online") else { return model }
        return model + ":online"
    }

    // MARK: Sources

    /// The Keychain slot a provisioned key will fill. Nothing writes it yet.
    private static func provisioned() -> Setup? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.steward.model",
            kSecAttrAccount as String: "feed",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return Setup(key: stored.key, model: stored.model, baseURL: stored.baseURL)
    }

    private struct Stored: Decodable {
        var key: String
        var model: String
        var baseURL: URL
    }

    /// Debug runs only: `STEWARD_MODEL_KEY` in the launch environment, plus
    /// `-feedModel <name>` (or chat's `-agentModel`) and optionally `-agentBaseURL`.
    private static func debugSetup() -> Setup? {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let key = ProcessInfo.processInfo.environment["STEWARD_MODEL_KEY"], !key.isEmpty,
              let model = defaults.string(forKey: "feedModel") ?? defaults.string(forKey: "agentModel"), !model.isEmpty,
              let base = URL(string: defaults.string(forKey: "agentBaseURL") ?? openRouter.absoluteString)
        else { return nil }
        return Setup(key: key, model: model, baseURL: base)
        #else
        return nil
        #endif
    }
}
