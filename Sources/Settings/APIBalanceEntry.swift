import SwiftUI

/// Settings for one prepaid API balance: the key, xAI's team, and — where the
/// provider publishes no balance — the amount after the last top-up.
///
/// Laid out like the Apify token entry: the caption on its own line, because a
/// field's own title becomes a crowded leading label inside a `Form` row.
struct APIBalanceEntry: View {
    let service: APIBalanceService
    /// Refreshes the provider so a new key or balance shows at once.
    let onSave: () -> Void

    @State private var key = ""
    @State private var keySaved = false
    @State private var teamID = APIBalanceSettings.xaiTeamID() ?? ""
    @State private var balance: Double?
    /// Bumped on Set, so the "Set to …" line re-reads the stored baseline.
    @State private var baselineVersion = 0
    @State private var threshold = APIBalanceSettings.alertThreshold

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(service.keyLabel).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField(L10n.t("Paste your key"), text: $key)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    Button(L10n.t("Save")) {
                        APIBalanceSettings.storeKey(key, for: service)
                        key = ""
                        keySaved = true
                        onSave()
                    }
                    .disabled(key.isEmpty)
                    if keySaved || APIBalanceSettings.hasKey(service) {
                        Text(L10n.t("Saved")).foregroundStyle(.green)
                    }
                }
            }

            if service == .xai {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Team ID")).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(L10n.t("Team ID"), text: $teamID)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        Button(L10n.t("Save")) {
                            APIBalanceSettings.setXAITeamID(teamID)
                            onSave()
                        }
                        .disabled(teamID.isEmpty)
                    }
                }
            }

            if !service.isOfficial {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Balance now (after your last top-up)")).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("$")
                        TextField(L10n.t("Amount"), value: $balance, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 100)
                        Button(L10n.t("Set")) {
                            guard let balance else { return }
                            APIBalanceSettings.setBaseline(balance, for: service)
                            self.balance = nil
                            baselineVersion += 1
                            onSave()
                        }
                        .disabled(balance == nil)
                    }
                    if baselineVersion >= 0, let current = APIBalanceSettings.baseline(service) {
                        Text(L10n.t("Set to \(ApifyUsage.money(current.amount)) on \(current.at.formatted(date: .abbreviated, time: .shortened))."))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Notify me below")).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("$")
                    TextField(L10n.t("Amount"), value: $threshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 100)
                        .onSubmit { APIBalanceSettings.alertThreshold = threshold }
                    Text(L10n.t("(all API balances)")).foregroundStyle(.tertiary)
                }
            }

            Text(service.keyHelp + " " + L10n.t("Checked once a day; click the ring to check now. The key is stored in your login keychain."))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .onChange(of: threshold) { value in APIBalanceSettings.alertThreshold = value }
    }
}
