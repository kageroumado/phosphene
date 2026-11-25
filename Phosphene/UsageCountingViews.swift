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
            reporting.consent.usageStatistics = countThisMac
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
    @Bindable private var reporting = UsageCounting.shared
    @State private var activeMacs: Int?

    var body: some View {
        Section {
            Toggle("Send crash reports", isOn: $reporting.consent.crashReports)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                When Phosphene crashes, it sends the crash log, app and macOS versions, hardware details, and \
                language. Your account name, Mac name, and home folder path are redacted.
                """)
                statusNote(reporting.crashStatus)
            }
            .font(.footnote)
        }

        Section {
            Toggle("Count this Mac", isOn: $reporting.consent.usageStatistics)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                Counts this Mac once per day of use. Each check-in includes the date, app and macOS versions, chip, \
                memory, language, display count, days active in the past week, and whether you imported videos.
                """)
                if reporting.consent.usageStatistics, let activeMacs {
                    Text("Yesterday, \(activeMacs) Macs counted themselves in.")
                }
                statusNote(reporting.statisticsStatus)
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

    @ViewBuilder
    private func statusNote(_ status: DigoxinStatus) -> some View {
        switch status {
        case .deletionPending: Text("Deletion is pending until the service can be reached.")
        case .secureEnclaveUnavailable: Text("This Mac has no Secure Enclave, so nothing is sent.")
        case let .failing(reason): Text("Not sent yet: \(reason)")
        case .off, .waiting, .registered: EmptyView()
        }
    }
}
