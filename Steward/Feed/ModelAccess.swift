import Foundation
import StewardCore

/// The one place the app gets a model, for tasks, the feed and the review.
///
/// The owner never has to handle a key. In order:
/// 1. the owner's own key, if they added one in the Steward tab (it takes
///    the relay off the model path entirely, docs/adr/0003),
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
        if let setup = ownKey() ?? debugSetup() {
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

    /// The provider's name as the owner knows it, for messages when a call fails.
    @MainActor
    static var providerName: String {
        guard let host = (ownKey() ?? debugSetup())?.baseURL.host()?.lowercased() else {
            return CaseService.relayConnection == nil ? "your AI provider" : "Steward's server"
        }
        let known = ["openrouter.ai": "OpenRouter", "api.openai.com": "OpenAI", "api.anthropic.com": "Anthropic",
                     "generativelanguage.googleapis.com": "Google", "api.groq.com": "Groq", "api.mistral.ai": "Mistral"]
        return known[host] ?? host.replacingOccurrences(of: "api.", with: "")
    }

    /// Why a call to the model failed, worded for the owner.
    @MainActor
    static func problem(_ error: Error) -> ModelProblem {
        ModelProblem(error, provider: providerName, model: (ownKey() ?? debugSetup())?.model)
    }

    /// Whether the owner's setup can search the web. Only OpenRouter adds
    /// search to any model (the `:online` suffix); other providers don't here.
    static func searchesWeb(_ baseURL: URL) -> Bool { baseURL.host() == openRouter.host() }

    // MARK: Sources

    /// The owner's own key: any OpenAI-compatible provider, OpenRouter by
    /// default. Kept in the Keychain on this phone only.
    static let ownKeySlot = KeychainSlot(service: "com.steward.model", account: "feed")

    struct OwnKey: Codable, Equatable {
        var key: String
        var model: String
        var baseURL: URL
    }

    static func ownKey() -> Setup? {
        guard let data = ownKeySlot.read(), let stored = try? JSONDecoder().decode(OwnKey.self, from: data) else { return nil }
        return Setup(key: stored.key, model: stored.model, baseURL: stored.baseURL)
    }

    static var hasOwnKey: Bool { ownKey() != nil }

    static func saveOwnKey(_ own: OwnKey) throws {
        try ownKeySlot.write(JSONEncoder().encode(own))
    }

    static func removeOwnKey() { ownKeySlot.delete() }

    /// The owner's own key as a model client, for the errand agent too.
    static func ownModel() -> (any ModelClient)? {
        ownKey().map { OpenAICompatibleClient(baseURL: $0.baseURL, model: $0.model, apiKey: $0.key) }
    }

    /// The errand agent's model with no relay: the owner's own key, or a
    /// debug key from the launch environment.
    static func agentModel() -> (any ModelClient)? {
        (ownKey() ?? debugSetup()).map { OpenAICompatibleClient(baseURL: $0.baseURL, model: $0.model, apiKey: $0.key) }
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
