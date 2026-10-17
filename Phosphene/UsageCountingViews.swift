import Digoxin
import Propofol
import SwiftUI

// MARK: - The question

/// Digoxin's question: whether this Mac is counted among Phosphene's users. Asked once,
/// at the top of the popover; the settings section holds the choice from then on.
struct UsageQuestionCard: View {
    @State private var isAsking = UsageCounting.tier == nil
    @State private var activeMacs: Int?

    var body: some View {
        if isAsking {
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
            .task { activeMacs = await UsageCounting.activeMacs() }
            .transition(OpacityTransition().combined(with: ScaleTransition(0.98, anchor: .top)))
        }
    }

    private func answer(_ tier: ConsentTier) {
        UsageCounting.choose(tier)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isAsking = false }
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

/// The "Count this Mac" choice among the popover's settings: the tier as a menu pill, one
/// line on what the tier sends, and the full list behind a disclosure.
struct UsageCountingSettings: View {
    @State private var tier = UsageCounting.tier ?? .off
    @State private var status: DigoxinStatus = .off
    @State private var activeMacs: Int?
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            tierMenu
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let statusLine {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let activeMacs {
                    ActiveMacsLine(count: activeMacs)
                }
                if showsDetails {
                    details
                }
                detailsToggle
            }
            .padding(.horizontal, Theme.Space.xs)
        }
        .task {
            tier = UsageCounting.tier ?? .off
            await refreshStatus()
            activeMacs = await UsageCounting.activeMacs()
        }
    }

    private var tierMenu: some View {
        Menu {
            Picker("Count this Mac", selection: $tier) {
                ForEach(ConsentTier.allCases, id: \.self) { tier in
                    Text(Self.title(of: tier)).tag(tier)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text("Count this Mac")
                    .font(.caption)
                    .foregroundStyle(tier == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text(Self.title(of: tier))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.sm)
            .contentShape(Theme.concentricInnerShape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(
            tier == .off ? .regular : .regular.tint(Color.accentColor.opacity(0.35)),
            in: Theme.concentricInnerShape,
        )
        .onChange(of: tier) { _, tier in
            // The read in `task` lands here too.
            guard UsageCounting.tier != tier else { return }
            UsageCounting.choose(tier)
            Task { await refreshStatus() }
        }
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
            Text("Turning this off deletes everything this Mac sent.")
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
        switch status {
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

    private func refreshStatus() async {
        status = await UsageCounting.client.status
    }
}
