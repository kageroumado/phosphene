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

/// Usage and crash reporting controls in the popover's settings.
struct UsageCountingSettings: View {
    @Bindable private var reporting = UsageCounting.shared
    @State private var activeMacs: Int?
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                reportingToggle("Count this Mac", isOn: $reporting.consent.usageStatistics, status: reporting.statisticsStatus)
                reportingToggle("Send crash reports", isOn: $reporting.consent.crashReports, status: reporting.crashStatus)
            }

            VStack(alignment: .leading, spacing: 2) {
                if reporting.consent.usageStatistics, let activeMacs {
                    ActiveMacsLine(count: activeMacs)
                }
                if showsDetails {
                    details
                }
                detailsToggle
            }
            .padding(.horizontal, Theme.Space.xs)
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

    private func reportingToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>, status: DigoxinStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            if let statusLine = statusLine(status) {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var detailsToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showsDetails.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text("What is sent")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(showsDetails ? 90 : 0))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("""
            Counts this Mac once per day of use. Each check-in includes the date, app and macOS versions, chip, \
            memory, language, display count, days active in the past week, and whether you imported videos.
            """)
            Text("""
            When Phosphene crashes, it sends the crash log, app and macOS versions, hardware details, and \
            language. Your account name, Mac name, and home folder path are redacted.
            """)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private func statusLine(_ status: DigoxinStatus) -> String? {
        switch status {
        case .deletionPending: String(localized: "Deletion is pending until the service can be reached.")
        case .secureEnclaveUnavailable: String(localized: "This Mac has no Secure Enclave, so nothing is sent.")
        case let .failing(reason): String(localized: "Not sent yet: \(reason)")
        case .off, .waiting, .registered: nil
        }
    }
}
