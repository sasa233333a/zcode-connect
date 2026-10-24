import Foundation
import Security

/// The Z.ai account used to authorize a mobile terminal. The JWT is the same
/// credential the desktop uses; it is never written to ordinary preferences.
public struct RelayAccount: Codable, Sendable, Equatable {
    public let userID: String
    public let name: String
    public let avatarURL: URL?
    public let jwt: String
    public let obtainedAt: Date

    public init(userID: String, name: String, avatarURL: URL?, jwt: String, obtainedAt: Date = .now) {
        self.userID = userID; self.name = name; self.avatarURL = avatarURL
        self.jwt = jwt; self.obtainedAt = obtainedAt
    }
}

/// One pending browser authorization. `pollToken` is the short-lived polling
/// credential returned for this flow; it is not a Z.ai account credential.
public struct RelayLoginFlow: Identifiable, Sendable, Equatable {
    public let id: String
    public let authorizeURL: URL
    public let expiresAt: Date
    public let pollInterval: TimeInterval
    fileprivate let pollToken: String
    public init(id: String, authorizeURL: URL, expiresAt: Date, pollInterval: TimeInterval, pollToken: String) {
        self.id = id; self.authorizeURL = authorizeURL; self.expiresAt = expiresAt
        self.pollInterval = pollInterval; self.pollToken = pollToken
    }
}

/// The two account systems supported by ZCode. The desktop and the phone must
/// use the same one; a QR does not reveal which account issued it.
public enum RelayAccountProvider: String, Sendable, CaseIterable, Hashable {
    case zai
    case bigmodel
    public var label: String { self == .bigmodel ? "BigModel（国内版）" : "Z.ai（国际版）" }
    public var shortLabel: String { self == .bigmodel ? "BigModel" : "Z.ai" }
}

/// Supplies the short-lived relay token for an account-authenticated pairing.
public protocol RelayTerminalTokenProviding: Sendable {
    func terminalToken() async throws -> String
}

public struct RelayAccountTokenProvider: RelayTerminalTokenProviding {
    public init() {}
    public func terminalToken() async throws -> String {
        try await RelayAccountService.shared.terminalToken()
    }
}

/// A desktop that the signed-in account already owns. Discovery removes the
/// need to scan a QR when the desktop is online and running remote control.
public struct RelayDiscoveredDevice: Sendable, Identifiable, Equatable {
    public let deviceSID: String
    public let deviceMid: String
    public let name: String
    public let version: String
    public let platform: String?
    public var id: String { deviceMid }

    public init(deviceSID: String, deviceMid: String, name: String, version: String, platform: String?) {
        self.deviceSID = deviceSID; self.deviceMid = deviceMid
        self.name = name; self.version = version; self.platform = platform
    }

    /// The same payload a current QR carries. It contains no shared secret;
    /// authentication still comes from the signed-in account's terminal token.
    public func pairingPayload() throws -> String {
        var components = URLComponents(string: RelayPairing.officialProfileURL)!
        components.queryItems = [
            URLQueryItem(name: "sid", value: deviceSID),
            URLQueryItem(name: "mid", value: deviceMid),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "app_version", value: version)
        ]
        guard let url = components.url else { throw RelayFailure("relay_invalid_pairing", "无法生成电脑的连接信息。") }
        _ = try RelayPairing(scannedURL: url.absoluteString)
        return url.absoluteString
    }
}

public actor RelayAccountService {
    public static let shared = RelayAccountService()
    private let session: URLSession
    private let endpoint = URL(string: "https://zcode.z.ai")!
    private let decoder: JSONDecoder
    /// Same-process fallback when the keychain refuses writes (observed on
    /// unsigned simulator builds after a reinstall); a signed app normally
    /// never needs it.
    private var memoryAccount: RelayAccount?

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public nonisolated static func storedAccount() -> RelayAccount? {
        guard let data = RelayAccountKeychain.load() else { return nil }
        return try? JSONDecoder().decode(RelayAccount.self, from: data)
    }

    public nonisolated static func store(_ account: RelayAccount) throws {
        do {
            let data = try JSONEncoder().encode(account)
            try RelayAccountKeychain.save(data)
        } catch let failure as RelayFailure {
            throw failure
        } catch {
            throw RelayFailure("relay_account_storage_failed", "无法保存登录信息，请重试。")
        }
    }

    public nonisolated static func clear() {
        RelayAccountKeychain.delete()
    }

    /// Starts the same account flow the desktop CLI uses. The browser ends on the
    /// service callback page; the phone only needs to poll, so no custom URL scheme
    /// is involved and no redirect credential crosses an untrusted app.
    public func beginLogin(provider: RelayAccountProvider = .zai) async throws -> RelayLoginFlow {
        let pollToken = Self.randomToken()
        struct InitData: Decodable {
            let flowId: String
            let pollToken: String?
            let authorizeUrl: String
            let expiresAt: Double
            let pollIntervalSec: Double
        }
        let body = try JSONSerialization.data(withJSONObject: ["provider": provider.rawValue])
        let envelope: Envelope<InitData> = try await request(path: "/api/v1/oauth/cli/init", method: "POST", body: body, bearer: pollToken)
        guard let data = envelope.data else { throw RelayFailure("relay_account_invalid_response", "登录服务返回了无效的响应。") }
        let flowID = data.flowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flowID.isEmpty, flowID.utf8.count <= 512, flowID.rangeOfCharacter(from: .controlCharacters) == nil,
              let authorizeURL = URL(string: data.authorizeUrl), authorizeURL.scheme == "https",
              ["chat.z.ai", "zcode.z.ai", "bigmodel.cn", "www.bigmodel.cn"].contains(authorizeURL.host ?? ""),
              authorizeURL.user == nil, authorizeURL.password == nil else {
            throw RelayFailure("relay_account_invalid_response", "登录服务返回了无效的授权地址。")
        }
        let returnedToken = data.pollToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = returnedToken.flatMap { value in
            (32...4096).contains(value.utf8.count) && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : nil
        } ?? pollToken
        let expiresAt = data.expiresAt > 1_000_000_000_000 ? data.expiresAt / 1000 : data.expiresAt
        let expiry = Date(timeIntervalSince1970: expiresAt)
        guard expiry.timeIntervalSinceNow > 5 else { throw RelayFailure("relay_account_expired", "登录请求已过期，请重试。") }
        let interval = min(30, max(1, data.pollIntervalSec.isFinite ? data.pollIntervalSec : 2))
        return RelayLoginFlow(id: flowID, authorizeURL: authorizeURL, expiresAt: expiry, pollInterval: interval, pollToken: token)
    }

    /// Returns nil while the browser has not completed authorization yet.
    public func poll(_ flow: RelayLoginFlow) async throws -> RelayAccount? {
        guard Date() < flow.expiresAt else { throw RelayFailure("relay_account_expired", "登录已过期，请重新开始登录。") }
        struct PollData: Decodable {
            struct User: Decodable {
                let userId: String
                let name: String?
                let email: String?
                let avatar: String?
            }
            let status: String
            let token: String?
            let user: User?
        }
        let path = "/api/v1/oauth/cli/poll/" + (flow.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? flow.id)
        let envelope: Envelope<PollData> = try await request(path: path, method: "GET", body: nil, bearer: flow.pollToken)
        guard let data = envelope.data else { throw RelayFailure("relay_account_invalid_response", "登录服务返回了无效的响应。") }
        switch data.status {
        case "pending":
            return nil
        case "failed":
            throw RelayFailure("relay_account_login_failed", "登录未完成，请在浏览器中重试。")
        case "ready":
            guard let jwt = data.token, Self.validCredential(jwt),
                  let user = data.user, Self.validCredential(user.userId) else {
                throw RelayFailure("relay_account_invalid_response", "登录服务没有返回有效的账号信息。")
            }
            let name = [user.name, user.email, user.userId].compactMap { $0 }.first { !$0.isEmpty } ?? user.userId
            let avatar = user.avatar.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
            return RelayAccount(userID: user.userId, name: String(name.prefix(200)), avatarURL: avatar, jwt: jwt)
        default:
            throw RelayFailure("relay_account_invalid_response", "登录服务返回了未知的状态。")
        }
    }

    /// Adopts an account for this process run when the keychain write failed.
    public func adoptInMemory(_ account: RelayAccount) {
        memoryAccount = account
    }

    public func clearInMemory() {
        memoryAccount = nil
    }

    /// Exchanges the account JWT for a short-lived terminal token. The token is
    /// scoped by the relay to the terminal role and is never persisted.
    public func terminalToken() async throws -> String {
        guard let account = Self.storedAccount() ?? memoryAccount else {
            throw RelayFailure("relay_account_login_required", "请先登录 ZCode 账号。手机和电脑需要登录同一账号。")
        }
        guard Self.validCredential(account.jwt) else {
            throw RelayFailure("relay_account_login_required", "登录信息已失效，请重新登录 ZCode 账号。")
        }
        struct TokenData: Decodable { let token: String; let expiresIn: Double? }
        let body = try JSONSerialization.data(withJSONObject: ["role": "terminal"])
        let envelope: Envelope<TokenData> = try await request(path: "/api/v1/remote/token", method: "POST", body: body, bearer: account.jwt)
        guard let value = envelope.data?.token, Self.validCredential(value), value.utf8.count <= 4096 else {
            throw RelayFailure("relay_account_invalid_response", "中转服务没有返回有效的连接令牌。")
        }
        return value
    }

    /// Lists desktops already associated with the signed-in account and online
    /// with remote control enabled. This is the same account-scoped device list
    /// used by the official QR flow, not a local network scan.
    public func devices() async throws -> [RelayDiscoveredDevice] {
        guard let account = Self.storedAccount() ?? memoryAccount else {
            throw RelayFailure("relay_account_login_required", "请先登录 ZCode 账号。手机和电脑需要登录同一账号。")
        }
        guard Self.validCredential(account.jwt) else {
            throw RelayFailure("relay_account_login_required", "登录信息已失效，请重新登录 ZCode 账号。")
        }
        struct Device: Decodable {
            struct Meta: Decodable {
                let platform: String?
                let name: String?
                let version: String?
            }
            let deviceSid: String?
            let deviceMid: String?
            let online: Bool?
            let meta: Meta?
        }
        let envelope: Envelope<[Device]> = try await request(path: "/api/v1/remote/device", method: "GET",
                                                            body: nil, bearer: account.jwt)
        guard envelope.code == 0, let values = envelope.data else {
            throw RelayFailure("relay_account_invalid_response", "账号服务没有返回可用的电脑列表。")
        }
        var seen = Set<String>()
        return values.compactMap { device -> RelayDiscoveredDevice? in
            guard device.online == true,
                  let sid = device.deviceSid?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty,
                  let mid = device.deviceMid?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty,
                  seen.insert(mid).inserted else { return nil }
            let name = device.meta?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = device.meta?.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RelayDiscoveredDevice(deviceSID: sid, deviceMid: mid,
                                         name: (name?.isEmpty == false ? name! : "电脑"),
                                         version: (version?.isEmpty == false ? version! : "3.16.3"),
                                         platform: device.meta?.platform)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let msg: String?
        let data: T?
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?, bearer: String) async throws -> Envelope<T> {
        guard Self.validCredential(bearer), let url = URL(string: path, relativeTo: endpoint) else {
            throw RelayFailure("relay_account_login_required", "请先登录 ZCode 账号。")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError { throw error }
            throw RelayFailure("relay_account_service_unavailable", "无法连接账号服务，请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayFailure("relay_account_service_unavailable", "账号服务返回了无效的响应。")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw RelayFailure("relay_account_login_required", "登录已过期，请重新登录 ZCode 账号。")
        }
        guard (200..<300).contains(http.statusCode), data.count <= 256 * 1024 else {
            throw RelayFailure("relay_account_service_unavailable", "账号服务暂时不可用（HTTP \(http.statusCode)）。")
        }
        let envelope: Envelope<T>
        do { envelope = try decoder.decode(Envelope<T>.self, from: data) }
        catch { throw RelayFailure("relay_account_invalid_response", "账号服务返回了无法识别的响应。") }
        guard envelope.code == 0 else {
            let detail = envelope.msg?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            throw RelayFailure("relay_account_service_error", detail.flatMap { $0.isEmpty ? nil : "登录服务返回错误：\($0)" } ?? "登录服务暂时不可用。")
        }
        return envelope
    }

    private nonisolated static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

private enum RelayAccountKeychain {
    private static let service = "dev.paco.zcode.mobile.relay-account"
    private static let account = "zai"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        // Some sandboxes refuse updates to existing items; recreate it instead.
        SecItemDelete(query as CFDictionary)
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw RelayFailure("relay_account_storage_failed", "无法保存登录信息，请重试。")
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
