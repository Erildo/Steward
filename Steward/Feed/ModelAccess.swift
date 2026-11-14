import Foundation
import Security
import StewardCore

/// The one place the app gets a model, for tasks, the feed and the review.
///
/// The owner never handles a key. In order:
/// 1. a provisioned key in the Keychain slot below (nothing writes it yet:
///    the relay may one day create a capped key for each phone),
/// 2. a debug key from the launch environment, like chat's `-uiState agent`,
/// 3. the relay's model proxy, with the relay's key and its daily cap, once
///    this phone has a relay (`CaseService.relayConnection`).
nonisolated enum ModelAccess {
    struct Setup {
        var key: String
        var model: String
        var baseURL: URL
    }

    static let openRouter = URL(string: "https://openrouter.ai/api/v1")!

    /// A model for Steward's own work, or `nil` when none is set up. With
    /// `searchesWeb`, one that can look things up on the web.
    @MainActor
    static func model(searchesWeb: Bool) -> (any ModelClient)? {
        if let setup = provisioned() ?? debugSetup() {
            let name = searchesWeb ? withWebSearch(setup.model, on: setup.baseURL) : setup.model
            return OpenAICompatibleClient(baseURL: setup.baseURL, model: name, apiKey: setup.key)
        }
        guard let connection = CaseService.relayConnection else { return nil }
        // The relay forwards to OpenRouter, which reads the same suffix.
        let name = searchesWeb && !RelaySettings.model.hasSuffix(":online") ? RelaySettings.model + ":online" : RelaySettings.model
        return RelayModel(connection: connection, model: name)
    }

    /// The feed's model: it always searches the web.
    @MainActor
    static func feedModel() -> (any ModelClient)? { model(searchesWeb: true) }

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
