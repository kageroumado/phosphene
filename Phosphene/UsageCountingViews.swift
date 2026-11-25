import Digoxin
import Propofol
import SwiftUI

// MARK: - The question

/// Digoxin's question: whether this Mac is counted among Phosphene's users. Asked once,
/// at the top of the popover; the settings section holds the choice from then on.
struct UsageQuestionCard: View {
    private let reporting = UsageCounting.shared
    @State private var activeMacs: Int?

    var body: some View {
        if reporting.shouldAsk {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "person.2")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Count yourself in")
                            .font(.system(.body, design: .rounded).weight(.medium))
                        Text("One anonymous check-in a day counts how many people use Phosphene. It never includes which videos you use. Settings lists what is sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let activeMacs {
                            ActiveMacsLine(count: activeMacs)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    HStack(spacing: Theme.Space.sm) {
                        Button("Count Me In") { answer(countThisMac: true) }
                            .buttonStyle(.glassProminent)
                            .foregroundStyle(Theme.onAccent)
                        Button("Not Now") { answer(countThisMac: false) }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.md)
            .glassCard()
            .accessibilityElement(children: .contain)
            .task { activeMacs = await reporting.activeMacs() }
            .transition(OpacityTransition().combined(with: ScaleTransition(0.98, anchor: .top)))
        }
    }

    private func answer(countThisMac: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            reporting.choose(countThisMac, for: \.usageStatistics)
        }
    }
}

/// "Yesterday, N Macs counted themselves in." in the quiet caption of the card and the
/// settings.
private struct ActiveMacsLine: View {
    let count: Int

    var body: some View {
        Text("Yesterday, \(count) Macs counted themselves in.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The setting

struct UsageCountingSettings: View {
    private let reporting = UsageCounting.shared
    @State private var activeMacs: Int?

    @State private var showsLegacyChoices = false

    var body: some View {
        Section {
            Toggle("Send crash reports", isOn: permission(\.crashReports))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                When Phosphene crashes, it sends the crash log, app and macOS versions, hardware details, and \
                language. Your account name, Mac name, and home folder path are redacted.
                """)
                statusNote(.crashes)
                if let deletion = reporting.deletionStatus(for: .previousCrashes) {
                    Text("Earlier crash reports: \(Text(deletionLine(deletion)))")
                }
                #if DEBUG
                    Text("Debug builds skip macOS crash log discovery.")
                #endif
            }
            .font(.footnote)
        }

        Section {
            Toggle("Count this Mac", isOn: permission(\.usageStatistics))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                Counts this Mac once per day of use. Each check-in includes the date, app and macOS versions, chip, \
                memory, language, display count, days active in the past week, and whether you imported videos.
                """)
                if reporting.consent.usageStatistics, let activeMacs {
                    Text("Yesterday, \(activeMacs) Macs counted themselves in.")
                }
                legacyStatistics
                statusNote(.statistics)
                if reporting.storageError {
                    Text("Reporting is paused because its settings could not be saved.")
                }
            }
            .font(.footnote)
        }
        .task(id: reporting.consent.usageStatistics) {
            activeMacs = nil
            guard reporting.consent.usageStatistics else { return }
            let count = await reporting.activeMacs()
            if !Task.isCancelled {
                activeMacs = count
            }
        }
    }

    private func permission(_ keyPath: WritableKeyPath<ReportingConsent, Bool>) -> Binding<Bool> {
        Binding(get: { reporting.consent[keyPath: keyPath] }, set: { value in
            reporting.choose(value, for: keyPath)
            if keyPath == \.usageStatistics, !value,
               let legacy = reporting.legacyStatistics, legacy != .deletionRequested, legacy != .keepRequested {
                showsLegacyChoices = true
            }
        })
    }

    @ViewBuilder
    private var legacyStatistics: some View {
        if let choice = reporting.legacyStatistics {
            VStack(alignment: .leading, spacing: 2) {
                if choice == .keepRequested {
                    Text("Checking the older registration…", tableName: "Reporting")
                } else if choice == .deletionRequested {
                    Text("Older Counting Registration", tableName: "Reporting")
                    if let status = reporting.deletionStatus(for: .legacyStatistics) {
                        Text(deletionLine(status))
                    }
                } else {
                    if choice == .undecided, reporting.consent.usageStatistics {
                        Text("Counting is paused until you choose what to do with the older registration.", tableName: "Reporting")
                    }
                    if choice == .keepUnavailable {
                        Text("The older registration could not be reused. It may still have queued data.", tableName: "Reporting")
                    }
                    Button {
                        showsLegacyChoices = true
                    } label: {
                        Text("Older Counting Registration", tableName: "Reporting")
                    }
                    .confirmationDialog(
                        Text("Older Counting Registration", tableName: "Reporting"),
                        isPresented: $showsLegacyChoices,
                        titleVisibility: .visible,
                    ) {
                        if choice.pausesCounting {
                            if reporting.consent.usageStatistics {
                                Button { reporting.chooseLegacy(.keepRequested) } label: {
                                    Text("Keep the Older Release Registration", tableName: "Reporting")
                                }
                            }
                            Button { reporting.chooseLegacy(.startNew) } label: {
                                Text("Use a New Counting Registration", tableName: "Reporting")
                            }
                        }
                        Button(role: .destructive) { reporting.chooseLegacy(.deletionRequested) } label: {
                            Text("Turn Off Counting and Request Older Data Deletion", tableName: "Reporting")
                        }
                    } message: {
                        Text("""
                        Keep the older registration only if you know it was used exclusively by Release. A new registration may be counted as a reinstall. \
                        Requesting deletion sends signed requests for the older registration to the Release service.
                        """, tableName: "Reporting")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusNote(_ stream: ReportingStream) -> some View {
        if let deletion = reporting.deletionStatus(for: stream) {
            Text(deletionLine(deletion))
        }
        switch reporting.status(for: stream) {
        case .secureEnclaveUnavailable: Text("This Mac has no Secure Enclave, so nothing is sent.")
        case let .failing(reason): Text("Not sent yet: \(reason)")
        case .off, .waiting, .registered, .deletionPending: EmptyView()
        }
    }

    private func deletionLine(_ deletion: ReportingDeletion) -> LocalizedStringKey {
        switch deletion {
        case .requested: "Preparing a deletion request…"
        case .pending: "Deletion was queued. Signed requests expire after 30 days."
        case .unconfirmed: "Server deletion could not be confirmed."
        }
    }
}
