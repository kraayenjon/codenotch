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

/// What Settings stores for each service: the key in a private file, the
/// rest in user defaults. None of the defaults are secret.
enum APIBalanceSettings {
    private static var defaults: UserDefaults { .standard }

    /// The keys live in a file only this user can read, not the keychain.
    ///
    /// Every build from CI is ad-hoc signed, so macOS sees each one as a new
    /// app and asks again for every key the last build stored — and a refused
    /// prompt hid the ring. A 0600 file in Application Support never prompts,
    /// survives rebuilds, and is as private as the shell exports these keys
    /// usually come from.
    static var keysURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/api-balance-keys.json")
    }

    private static func readKeys() -> [String: String] {
        guard let data = try? Data(contentsOf: keysURL),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys
    }

    private static func writeKeys(_ keys: [String: String]) {
        let url = keysURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(keys) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        // createFile keeps an existing file's mode, so set it either way.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func key(_ service: APIBalanceService,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(readKeys()[service.rawValue]) ?? nonEmpty(environment[service.environmentKey])
    }

    static func hasKey(_ service: APIBalanceService) -> Bool { key(service) != nil }

    static func storeKey(_ value: String, for service: APIBalanceService) {
        guard let trimmed = nonEmpty(value) else { return }
        var keys = readKeys()
        keys[service.rawValue] = trimmed
        writeKeys(keys)
        clearCache(service)
    }

    static func deleteKey(_ service: APIBalanceService) {
        var keys = readKeys()
        keys[service.rawValue] = nil
        writeKeys(keys)
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
        defaults.removeObject(forKey: "apiBalance.\(service.rawValue).failure")
    }

    struct Failure: Codable {
        let why: String
        let at: Date
    }

    static func failure(_ service: APIBalanceService) -> Failure? {
        guard let data = defaults.data(forKey: "apiBalance.\(service.rawValue).failure") else { return nil }
        return try? JSONDecoder().decode(Failure.self, from: data)
    }

    static func setFailure(_ failure: Failure, for service: APIBalanceService) {
        defaults.set(try? JSONEncoder().encode(failure), forKey: "apiBalance.\(service.rawValue).failure")
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
    /// A failed check is not retried on every poll: once an hour, unless
    /// Refresh now or a new key asks for it sooner.
    static let retryAfterFailure: TimeInterval = 60 * 60

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
        guard APIBalanceSettings.hasKey(service) else { throw UsageProviderError.needsAuth }
        if freshness != .fromSource, let cached = APIBalanceSettings.cached(service),
           now().timeIntervalSince(cached.fetchedAt) < Self.checkInterval {
            return snapshot(cached.windows)
        }
        // Errors become a visible status rather than a throw: the store drops a
        // provider that is hidden when absent on *any* failure, so a rejected
        // key used to make the ring vanish without a word.
        if freshness != .fromSource, let failure = APIBalanceSettings.failure(service),
           now().timeIntervalSince(failure.at) < Self.retryAfterFailure {
            return failed(failure.why)
        }
        guard let key = APIBalanceSettings.key(service) else { throw UsageProviderError.needsAuth }
        let window: LimitWindow
        do {
            window = try await readBalance(key: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UsageProviderError {
            switch error {
            case .apiError(let why): return failed(why)
            case .badResponse(let status): return failed(L10n.t("\(displayName) answered HTTP \(status)"))
            case .timedOut: return failed(L10n.t("\(displayName) did not answer in time"))
            case .rateLimited: return failed(L10n.t("\(displayName) is rate limiting — try later"))
            default: return failed(String(describing: error))
            }
        }
        APIBalanceSettings.clearCache(service)
        APIBalanceSettings.setCached(.init(windows: [window], fetchedAt: now()), for: service)
        if let money = window.money { Self.alertIfLow(service, remaining: money.remaining, estimated: !service.isOfficial) }
        return snapshot([window])
    }

    private func failed(_ why: String) -> ProviderSnapshot {
        if APIBalanceSettings.failure(service)?.why != why {
            APIBalanceSettings.setFailure(.init(why: why, at: now()), for: service)
        }
        var failed = snapshot([])
        failed.status = .error(why)
        return failed
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
                    // Midnight UTC: buckets are whole days, and the day of the
                    // top-up is counted in full, which errs towards less left.
                    URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: Self.utcDayStart(start))),
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

    static func utcDayStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
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
        if (200..<300).contains(status) { return data }
        // The provider's own words where it gave some, then what to do about it.
        let said = APIBalanceParse.errorMessage(data).map { " — \($0)" } ?? ""
        switch status {
        // Not `needsAuth`: a key is saved, and that state hides the ring and
        // asks for a key, so a rejected one looked like nothing at all.
        case 401: throw UsageProviderError.apiError(L10n.t("HTTP 401: key rejected. It must be an \(service.keyLabel)\(said)"))
        case 403: throw UsageProviderError.apiError(L10n.t("HTTP 403: this key cannot read billing. It must be an \(service.keyLabel)\(said)"))
        case 404 where service == .xai: throw UsageProviderError.apiError(L10n.t("HTTP 404: xAI found no team with that ID\(said)"))
        case 429: throw UsageProviderError.rateLimited(retryAfter: 3600)
        default: throw UsageProviderError.apiError("HTTP \(status)\(said)")
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

    /// `{"error":{"message":…}}` (Anthropic, OpenAI, Vercel) or
    /// `{"message":…}` (xAI), so the ring can quote the provider.
    static func errorMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = (root["error"] as? [String: Any])?["message"] as? String
            ?? root["error"] as? String
            ?? root["message"] as? String
        return APIBalanceSettings.nonEmpty(message).map { String($0.prefix(200)) }
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? NSNumber { return value.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }
}
