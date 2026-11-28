import Digoxin
import Propofol
import SwiftUI

// MARK: - The question

/// Digoxin's question: whether this Mac is counted among Phosphene's users. Asked once,
/// at the top of the popover; the Settings window holds the choice from then on.
struct UsageQuestionCard: View {
    private let reporting = UsageCounting.shared
    @State private var activeMacs: Int?

    var body: some View {
        if reporting.tier == nil, !reporting.storageError {
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
                        Button("Count Me In") { answer(.counting) }
                            .buttonStyle(.glassProminent)
                            .foregroundStyle(Theme.onAccent)
                        Button("Not Now") { answer(.off) }
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

    private func answer(_ tier: ConsentTier) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { reporting.choose(tier) }
    }
}

/// "Yesterday, N Macs counted themselves in." in the quiet caption of the card and the
/// Settings window.
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

/// The "Count this Mac" section of the Settings window: the tier, one line on what it
/// sends, and the full list behind a disclosure.
struct UsageCountingSection: View {
    private let reporting = UsageCounting.shared
    private var tier: ConsentTier {
        reporting.tier ?? .off
    }
    @State private var activeMacs: Int?

    var body: some View {
        Section {
            Picker("Count this Mac", selection: Binding(get: { tier }, set: reporting.choose)) {
                ForEach(ConsentTier.allCases, id: \.self) { tier in
                    Text(Self.title(of: tier)).tag(tier)
                }
            }
            DisclosureGroup("What is sent") { details }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                if let statusLine {
                    Text(statusLine)
                }
                if let activeMacs {
                    ActiveMacsLine(count: activeMacs)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            activeMacs = await reporting.activeMacs()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("On each day you use Phosphene, one anonymous check-in is sent:")
            Text("""
            • Phosphene and macOS versions
            • chip family and memory size
            • language and the date
            • how many of the last 7 days you used it
            • whether you have your own videos, and how many displays
            """)
            Text("It never includes which videos you use, and nothing in it names you.")
            Text("Crash reports adds a report when Phosphene itself crashes, with your name, your Mac\u{2019}s name and folder paths removed.")
            Text("Turning this off requests deletion of what this Mac sent.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private var summary: String {
        switch tier {
        case .off: String(localized: "Nothing is sent.")
        case .counting: String(localized: "One anonymous check-in on each day you use Phosphene.")
        case .crashReports: String(localized: "One anonymous check-in a day, and a report when Phosphene crashes.")
        }
    }

    private var statusLine: String? {
        if reporting.storageError {
            return String(localized: "Reporting is paused because its settings could not be saved.")
        }
        return switch reporting.status {
        case .deletionPending: String(localized: "Deleting what this Mac sent\u{2026}")
        case .secureEnclaveUnavailable: String(localized: "This Mac has no Secure Enclave, so nothing is sent.")
        case let .failing(reason): String(localized: "Not sent yet: \(reason)")
        case .off, .waiting, .registered: nil
        }
    }

    private static func title(of tier: ConsentTier) -> String {
        switch tier {
        case .off: String(localized: "Off")
        case .counting: String(localized: "Counting")
        case .crashReports: String(localized: "Counting and crash reports")
        }
    }
}
