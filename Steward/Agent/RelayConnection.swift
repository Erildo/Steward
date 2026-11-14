import Foundation
import Security
import StewardCore

/// Where the relay is. Release builds use `production`, which stays `nil`
/// until the relay is deployed: until then the app has no live errands.
/// Debug runs can point at a local relay with
/// `-relayURL http://localhost:8787` (and `-relayInvite <secret>` if it's
/// invite-only).
nonisolated enum RelaySettings {
    static let production: URL? = nil

    static var url: URL? {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "relayURL"), let url = URL(string: text) { return url }
        #endif
        return production
    }

    static var invite: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "relayInvite")
        #else
        return nil
        #endif
    }

    /// The model the agent asks for through the relay's proxy.
    static var model: String {
        UserDefaults.standard.string(forKey: "agentModel") ?? "nvidia/nemotron-3-ultra-550b-a55b:free"
    }
}

/// This phone's identity at the relay, kept in the Keychain: the private key
/// that opens sealed mail (it never leaves the device), and the token the
/// relay gave at registration.
nonisolated struct RelayAccount: Codable, Sendable {
    var baseURL: URL
    var deviceID: String
    var token: String
    var privateKey: Data

    private static let service = "com.steward.relay"
    private static let account = "device"

    static func load() -> RelayAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(RelayAccount.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Readable after the first unlock, so a push can wake an errand while locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// The phone's link to the relay. It registers the first time it's needed,
/// then hands out a client, the inbox and the push token.
actor RelayConnection {
    let baseURL: URL
    private let invite: String?
    private var account: RelayAccount?
    private var registering: Task<RelayAccount, any Error>?
    private var pushToken: String?

    init(baseURL: URL, invite: String?) {
        self.baseURL = baseURL
        self.invite = invite
        let stored = RelayAccount.load()
        // An account made for another relay is no use here.
        account = stored?.baseURL == baseURL ? stored : nil
    }

    func client() async throws -> RelayClient {
        let account = try await ready()
        return RelayClient(baseURL: account.baseURL, token: account.token)
    }

    func inbox() async throws -> RelayInbox {
        let account = try await ready()
        return RelayInbox(client: RelayClient(baseURL: account.baseURL, token: account.token), keys: try RelayKeys(rawRepresentation: account.privateKey))
    }

    /// APNs gave this device a token: tell the relay, now or once registered.
    func setPushToken(_ token: String) async {
        pushToken = token
        guard account != nil else { return }
        try? await client().setPushToken(token)
    }

    private func ready() async throws -> RelayAccount {
        if let account { return account }
        if let registering { return try await registering.value }
        let task = Task { [baseURL, invite, pushToken] in
            let keys = RelayKeys()
            let registration = try await RelayClient.register(baseURL: baseURL, keys: keys, pushToken: pushToken, invite: invite)
            let account = RelayAccount(baseURL: baseURL, deviceID: registration.deviceId, token: registration.token, privateKey: keys.privateKey.rawRepresentation)
            try account.save()
            return account
        }
        registering = task
        defer { registering = nil }
        let made = try await task.value
        account = made
        return made
    }
}

/// Sends approved emails through the relay, registering first if needed.
nonisolated struct RelayConnectionMailer: MailSender {
    let connection: RelayConnection

    func send(_ email: CaseFile.Email, in file: CaseFile) async throws {
        try await RelayMailer(client: connection.client()).send(email, in: file)
    }
}

/// The agent's model, reached through the relay's proxy with Steward's key:
/// the owner never handles one.
nonisolated struct RelayModel: ModelClient {
    let connection: RelayConnection
    let model: String

    func complete(system: String, messages: [ModelMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        let client = try await connection.client()
        return try await OpenAICompatibleClient(baseURL: client.baseURL.appending(path: "v1/model"), model: model, apiKey: client.token)
            .complete(system: system, messages: messages, tools: tools)
    }
}
