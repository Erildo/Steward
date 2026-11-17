import Foundation

/// Why a call to the owner's AI provider failed, said so the owner can tell
/// whose side the problem is on and what, if anything, to do about it. A
/// failure the owner can't place reads as "the app is broken".
public struct ModelProblem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 401/403: the provider turned the key down.
        case keyRejected
        /// 402: the provider account has no credit left.
        case noCredit
        /// The provider doesn't know the model name.
        case unknownModel
        /// 429: too many requests for now.
        case rateLimited
        /// 5xx: the provider itself is having trouble.
        case providerDown
        case timedOut
        case offline
        /// An answer came back, but not one Steward could use.
        case unusableReply
        case other
    }

    /// Where the sentence will be read. In the Feed the next step is a pull
    /// or a button beside it; in a conversation, the owner writes again.
    public enum Place: Sendable { case feed, conversation }

    public var kind: Kind
    /// The provider's name as the owner knows it, such as "OpenRouter".
    public var provider: String
    /// The model name the owner typed, for an unknown-model message.
    public var model: String?

    public init(_ error: Error, provider: String, model: String? = nil) {
        self.provider = provider
        self.model = model
        kind = Self.kind(of: error)
    }

    public init(kind: Kind, provider: String, model: String? = nil) {
        self.kind = kind
        self.provider = provider
        self.model = model
    }

    /// The fix is in the owner's key settings, not a retry.
    public var isFixedInKeySettings: Bool {
        kind == .keyRejected || kind == .unknownModel
    }

    /// Worth trying again later without changing anything.
    public var isPassing: Bool {
        [.rateLimited, .providerDown, .timedOut, .offline, .unusableReply, .other].contains(kind)
    }

    public func message(in place: Place) -> String {
        let retry = place == .feed ? "Pull to try again" : "Write again to retry"
        let keyPlace = place == .feed ? "your AI key" : "your key in the Steward tab under AI › Your Own AI Key"
        switch kind {
        case .keyRejected:
            return "\(provider) turned down your AI key. Check \(keyPlace)."
        case .noCredit:
            // OpenRouter bills web search even on free models, so a free
            // model chats fine while the Feed fails here.
            return place == .feed
                ? "Your \(provider) account is out of credit. Searching the web costs a little even with a free model. Add some credit with \(provider), then \(retry.lowercased())."
                : "Your \(provider) account is out of credit. Add some with \(provider), then \(retry.lowercased())."
        case .unknownModel:
            let name = model.map { " \"\($0)\"" } ?? ""
            return "\(provider) doesn't offer the model\(name). It may be misspelled or retired. Check the model name in \(keyPlace)."
        case .rateLimited:
            return "\(provider) is busy and asked Steward to slow down. \(retry) in a minute."
        case .providerDown:
            return "\(provider) is having trouble right now, nothing on your side. \(retry) later."
        case .timedOut:
            return "\(provider) took too long to answer. \(retry)."
        case .offline:
            return "This iPhone is offline, so Steward couldn't reach \(provider). \(retry) once you're connected."
        case .unusableReply:
            return place == .feed
                ? "Steward looked but got nothing it could show. \(retry)."
                : "\(provider) sent back an answer Steward couldn't read. \(retry)."
        case .other:
            return place == .feed
                ? "Steward couldn't get today's finds from \(provider). \(retry)."
                : "Steward couldn't get through this step. \(retry)."
        }
    }

    // MARK: Classifying

    static func kind(of error: Error) -> Kind {
        if let http = error as? OpenAICompatibleClient.HTTPError {
            switch http.status {
            case 401, 403: return .keyRejected
            case 402: return .noCredit
            case 404: return mentionsUnknownModel(http.body) ? .unknownModel : .other
            case 400, 422: return mentionsUnknownModel(http.body) ? .unknownModel : .other
            case 408: return .timedOut
            case 429: return .rateLimited
            case 500...599: return .providerDown
            default: return .other
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default: return .other
            }
        }
        if error is FeedComposer.NothingUsable || error is DecodingError { return .unusableReply }
        return .other
    }

    /// Providers word this differently: "is not a valid model ID",
    /// "model_not_found", "The model `x` does not exist".
    static func mentionsUnknownModel(_ body: String) -> Bool {
        let text = body.lowercased()
        guard text.contains("model") else { return false }
        return ["not a valid model", "model_not_found", "does not exist", "not found", "no endpoints found", "invalid model", "unknown model"]
            .contains { text.contains($0) }
    }
}
