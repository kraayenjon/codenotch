import Foundation
import UserNotifications

/// Prepaid API credit that runs out silently when auto-reload is off.
///
/// Two kinds of reading, and the fidelity says which:
///
/// - xAI and Vercel AI Gateway publish the balance itself, so those are
///   `.official`.
/// - Anthropic and OpenAI publish spend but never what is left. The balance is
///   typed in once in Settings (after a top-up), and the provider subtracts
///   the spend their Admin cost endpoints report since that moment. That is
///   `.derived`, and the card says "estimate".
///
/// Checked once a day, not on every poll: the balance moves slowly, and a
/// cost report is a heavy call. Refresh now still asks the source at once.
enum APIBalanceService: String, CaseIterable, Sendable {
    case anthropic = "anthropic-api"
    case openai = "openai-api"
    case xai = "xai-api"
    case vercel = "vercel-gateway"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI API"
        case .xai: return "xAI API"
        case .vercel: return "Vercel AI Gateway"
        }
    }

    var glyph: ProviderGlyph {
        switch self {
        case .anthropic: return .claude
        case .openai: return .openai
        case .xai: return .grok
        case .vercel: return .vercel
        }
    }

    /// Whether the provider publishes the balance itself.
    var isOfficial: Bool { self == .xai || self == .vercel }

    var keyLabel: String {
        switch self {
        case .anthropic: return "Anthropic Admin key (sk-ant-admin…)"
        case .openai: return "OpenAI Admin key"
        case .xai: return "xAI Management key"
        case .vercel: return "AI Gateway API key"
        }
    }

    /// Read when nothing is stored in Settings. A GUI app launched from the
    /// Dock does not see a shell's exports, so this is mostly for `make run`.
    var environmentKey: String {
        switch self {
        case .anthropic: return "ANTHROPIC_ADMIN_KEY"
        case .openai: return "OPENAI_ADMIN_KEY"
        case .xai: return "XAI_MANAGEMENT_KEY"
        case .vercel: return "AI_GATEWAY_API_KEY"
        }
    }

    var keyHelp: String {
        switch self {
        case .anthropic:
            return "Claude Console › Settings › Admin keys. Needs an organization account. Then enter your balance after each top-up — the card subtracts spend since then."
        case .openai:
            return "platform.openai.com › Settings › Organization › Admin keys. Then enter your balance after each top-up — the card subtracts spend since then."
        case .xai:
            return "console.x.ai › Settings › Management keys. The team ID is in the console URL."
        case .vercel:
            return "Vercel dashboard › AI Gateway › API keys."
        }
    }

    var billingURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/billing")
        case .openai: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .xai: return URL(string: "https://console.x.ai")
        case .vercel: return URL(string: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway")
        }
    }
}

/// What Settings stores for each service: the key in the login keychain, the
/// rest in user defaults. None of the defaults are secret.
enum APIBalanceSettings {
    static let keychainAccount = "codenotch"
    private static var defaults: UserDefaults { .standard }

    static func keychainService(_ service: APIBalanceService) -> String { "codenotch-balance-\(service.rawValue)" }

    static func key(_ service: APIBalanceService,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let stored = nonEmpty(KeychainItem.read(service: keychainService(service), account: keychainAccount)) {
            return stored
        }
        return nonEmpty(environment[service.environmentKey])
    }

    static func hasKey(_ service: APIBalanceService) -> Bool {
        KeychainItem.modifiedAt(service: keychainService(service), account: keychainAccount) != nil
            || nonEmpty(ProcessInfo.processInfo.environment[service.environmentKey]) != nil
    }

    static func storeKey(_ value: String, for service: APIBalanceService) {
        guard let trimmed = nonEmpty(value) else { return }
        _ = KeychainItem.store(service: keychainService(service), account: keychainAccount, value: trimmed)
        clearCache(service)
    }

    static func deleteKey(_ service: APIBalanceService) {
        _ = KeychainItem.delete(service: keychainService(service), account: keychainAccount)
        clearCache(service)
    }

    // MARK: xAI team

    static func xaiTeamID() -> String? { nonEmpty(defaults.string(forKey: "apiBalance.xai.teamID")) }

    static func setXAITeamID(_ value: String) {
        defaults.set(nonEmpty(value), forKey: "apiBalance.xai.teamID")
        clearCache(.xai)
    }

    // MARK: Estimated balances (Anthropic, OpenAI)

    /// The balance typed in, and when. Spend before `at` is already in it.
    struct Baseline: Codable, Equatable {
        let amount: Double
        let at: Date
    }

    static func baseline(_ service: APIBalanceService) -> Baseline? {
        guard let data = defaults.data(forKey: "apiBalance.\(service.rawValue).baseline") else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    static func setBaseline(_ amount: Double, for service: APIBalanceService, at date: Date = Date()) {
        guard amount.isFinite, amount >= 0,
              let data = try? JSONEncoder().encode(Baseline(amount: amount, at: date)) else { return }
        defaults.set(data, forKey: "apiBalance.\(service.rawValue).baseline")
        clearCache(service)
    }

    // MARK: Official balances: the high-water mark since the last top-up

    /// The highest balance seen since the last top-up, so the ring can show
    /// how much of it is spent. A balance that rises is a top-up and resets it.
    static func funded(for service: APIBalanceService, balance: Double) -> Double {
        let key = "apiBalance.\(service.rawValue).funded"
        let previous = defaults.double(forKey: key)
        let funded = balance > previous + 0.005 ? balance : previous
        defaults.set(funded, forKey: key)
        return funded
    }

    // MARK: Low-balance alert

    /// Dollars. Below this, a notification fires on each daily check.
    static var alertThreshold: Double {
        get { defaults.object(forKey: "apiBalance.alertThreshold") as? Double ?? 5 }
        set { defaults.set(max(0, newValue), forKey: "apiBalance.alertThreshold") }
    }

    // MARK: Daily cache

    struct Cached: Codable {
        let windows: [LimitWindow]
        let fetchedAt: Date
    }

    static func cached(_ service: APIBalanceService) -> Cached? {
        guard let data = defaults.data(forKey: "apiBalance.\(service.rawValue).cache") else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    static func setCached(_ cached: Cached, for service: APIBalanceService) {
        defaults.set(try? JSONEncoder().encode(cached), forKey: "apiBalance.\(service.rawValue).cache")
    }

    /// A changed key, team or baseline must show at once, not tomorrow.
    static func clearCache(_ service: APIBalanceService) {
        defaults.removeObject(forKey: "apiBalance.\(service.rawValue).cache")
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

actor APIBalanceProvider: UsageProvider {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    nonisolated let service: APIBalanceService
    nonisolated var id: String { service.rawValue }
    nonisolated var displayName: String { service.displayName }
    nonisolated var glyph: ProviderGlyph { service.glyph }

    private let session: URLSession
    private let now: @Sendable () -> Date

    init(_ service: APIBalanceService, session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.session = session
        self.now = now
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Paste your \(service.keyLabel) in Settings › Providers."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard APIBalanceSettings.hasKey(service) else { return nil }
        return ProviderAccount(label: nil, plan: service.isOfficial ? nil : L10n.t("Estimate"),
                               source: service.displayName, manageURL: service.billingURL)
    }

    nonisolated func signOut() async { APIBalanceSettings.deleteKey(service) }
    nonisolated func presentSignIn() {}
    nonisolated func forgetCachedCredential() { APIBalanceSettings.clearCache(service) }
    /// Off until a key is pasted, so four empty rings do not crowd the notch.
    nonisolated var isVisibleWhenAbsent: Bool { false }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await fetchSnapshot(freshness: .standard)
    }

    func fetchSnapshot(freshness: UsageFreshness) async throws -> ProviderSnapshot {
        // Attributes only before the cache check: the store polls every
        // minute, and the secret is read once a day, when it is used.
        guard APIBalanceSettings.hasKey(service) else { throw UsageProviderError.needsAuth }
        if freshness != .fromSource, let cached = APIBalanceSettings.cached(service),
           now().timeIntervalSince(cached.fetchedAt) < Self.checkInterval {
            return snapshot(cached.windows)
        }
        guard let key = APIBalanceSettings.key(service) else { throw UsageProviderError.needsAuth }
        let window = try await readBalance(key: key)
        APIBalanceSettings.setCached(.init(windows: [window], fetchedAt: now()), for: service)
        if let money = window.money { Self.alertIfLow(service, remaining: money.remaining, estimated: !service.isOfficial) }
        return snapshot([window])
    }

    private func snapshot(_ windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                         fidelity: service.isOfficial ? .official : .derived,
                         status: .ok, windows: windows, headlineID: "balance",
                         plan: account()?.plan)
    }

    // MARK: Reading

    private func readBalance(key: String) async throws -> LimitWindow {
        switch service {
        case .vercel:
            let data = try await get(URL(string: "https://ai-gateway.vercel.sh/v1/credits")!,
                                     headers: ["Authorization": "Bearer \(key)"])
            let balance = try APIBalanceParse.vercelBalance(data)
            return officialWindow(balance: balance)
        case .xai:
            guard let team = APIBalanceSettings.xaiTeamID(),
                  let encoded = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://management-api.x.ai/v1/billing/teams/\(encoded)/prepaid/balance")
            else { throw UsageProviderError.apiError(L10n.t("Enter your xAI team ID in Settings")) }
            let data = try await get(url, headers: ["Authorization": "Bearer \(key)"])
            return officialWindow(balance: try APIBalanceParse.xaiBalance(data))
        case .anthropic, .openai:
            guard let baseline = APIBalanceSettings.baseline(service) else {
                // No balance typed in yet: spend this month is still worth seeing.
                let monthStart = Calendar.current.dateInterval(of: .month, for: now())?.start ?? now()
                let spent = try await spend(since: monthStart, key: key)
                return LimitWindow(id: "balance", label: L10n.t("Spent this month"),
                                   usedText: ApifyUsage.money(spent),
                                   detail: L10n.t("\(ApifyUsage.money(spent)) this month — enter your balance in Settings to see what is left"),
                                   prefersUsedText: true)
            }
            let spent = try await spend(since: baseline.at, key: key)
            let remaining = max(0, baseline.amount - spent)
            return LimitWindow(id: "balance", label: L10n.t("Credit balance (estimate)"),
                               usedFraction: baseline.amount > 0 ? min(spent / baseline.amount, 1) : 1,
                               usedText: "≈\(ApifyUsage.money(remaining)) left",
                               money: UsageMoneyBreakdown(currency: "USD", spent: min(spent, baseline.amount),
                                                          remaining: remaining))
        }
    }

    private func officialWindow(balance: Double) -> LimitWindow {
        let funded = APIBalanceSettings.funded(for: service, balance: balance)
        let spent = max(0, funded - balance)
        return LimitWindow(id: "balance", label: L10n.t("Credit balance"),
                           usedFraction: funded > 0 ? spent / funded : 1,
                           usedText: "\(ApifyUsage.money(balance)) left",
                           money: UsageMoneyBreakdown(currency: "USD", spent: spent, remaining: balance))
    }

    /// Dollars spent since `start`, from the Admin cost endpoint, all pages.
    private func spend(since start: Date, key: String) async throws -> Double {
        var total = 0.0
        var page: String?
        for _ in 0..<24 {
            var components: URLComponents
            var headers: [String: String]
            switch service {
            case .anthropic:
                components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
                components.queryItems = [
                    URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: start)),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31")
                ]
                headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
            default:
                components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                components.queryItems = [
                    URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "180")
                ]
                headers = ["Authorization": "Bearer \(key)"]
            }
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            let data = try await get(components.url!, headers: headers)
            let parsed = service == .anthropic
                ? try APIBalanceParse.anthropicCostPage(data)
                : try APIBalanceParse.openAICostPage(data)
            total += parsed.dollars
            guard let next = parsed.nextPage else { return total }
            page = next
        }
        return total
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach \(displayName). Check your connection."))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        // Not `needsAuth`: a key is saved, and that state hides the ring and
        // asks for a key, so a rejected one looked like nothing at all.
        case 401: throw UsageProviderError.apiError(L10n.t("\(displayName) rejected the saved key (HTTP 401). It must be an \(service.keyLabel)."))
        case 403: throw UsageProviderError.apiError(L10n.t("This key cannot read billing (HTTP 403) — use an admin or management key"))
        case 404 where service == .xai: throw UsageProviderError.apiError(L10n.t("xAI found no team with that ID (HTTP 404)"))
        case 429: throw UsageProviderError.rateLimited(retryAfter: 3600)
        default: throw UsageProviderError.badResponse(status: status)
        }
    }

    // MARK: Alert

    private static func alertIfLow(_ service: APIBalanceService, remaining: Double, estimated: Bool) {
        let threshold = APIBalanceSettings.alertThreshold
        guard threshold > 0, remaining < threshold else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            let amount = (estimated ? "≈" : "") + ApifyUsage.money(remaining)
            content.title = L10n.t("\(service.displayName) credit is low")
            content.body = L10n.t("\(amount) left. Top up before requests start failing.")
            content.sound = .default
            content.threadIdentifier = service.rawValue
            center.add(UNNotificationRequest(
                identifier: "\(service.rawValue).low.\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil))
        }
    }
}

/// The response shapes, apart from the network so tests can feed fixtures.
enum APIBalanceParse {
    struct CostPage: Equatable {
        let dollars: Double
        let nextPage: String?
    }

    /// `{"balance":"10.36","total_used":"4.81"}` — strings, in dollars.
    static func vercelBalance(_ data: Data) throws -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = number(root["balance"]), balance.isFinite
        else { throw UsageProviderError.badResponse(status: 0) }
        return balance
    }

    /// `{"changes":[…],"total":{"val":"-1000"}}` — USD cents, and a purchase is
    /// negative, so the money left is the negated total.
    static func xaiBalance(_ data: Data) throws -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["total"] as? [String: Any],
              let cents = number(total["val"]), cents.isFinite
        else { throw UsageProviderError.badResponse(status: 0) }
        return max(0, -cents / 100)
    }

    /// `results[].amount` is a decimal string in cents: "123.45" is $1.23.
    static func anthropicCostPage(_ data: Data) throws -> CostPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]]
        else { throw UsageProviderError.badResponse(status: 0) }
        let cents = buckets
            .flatMap { $0["results"] as? [[String: Any]] ?? [] }
            .compactMap { number($0["amount"]) }
            .reduce(0, +)
        let more = root["has_more"] as? Bool ?? false
        return CostPage(dollars: cents / 100, nextPage: more ? root["next_page"] as? String : nil)
    }

    /// `result[].amount.value` in dollars. The spec says `result`; the live
    /// API has been seen to answer `results`, so both are read.
    static func openAICostPage(_ data: Data) throws -> CostPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]]
        else { throw UsageProviderError.badResponse(status: 0) }
        let dollars = buckets
            .flatMap { ($0["results"] ?? $0["result"]) as? [[String: Any]] ?? [] }
            .compactMap { number(($0["amount"] as? [String: Any])?["value"]) }
            .reduce(0, +)
        let more = root["has_more"] as? Bool ?? false
        return CostPage(dollars: dollars, nextPage: more ? root["next_page"] as? String : nil)
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? NSNumber { return value.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }
}
