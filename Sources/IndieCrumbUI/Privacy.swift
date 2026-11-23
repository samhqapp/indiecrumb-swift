import SwiftUI

/// What the switch covers: one case per module the app links.
public enum SharedData: String, CaseIterable, Identifiable, Sendable {
    case usage, crash

    public var id: String { rawValue }

    /// One line for the summary, as the README's "Every field sent" lists it.
    var line: String {
        switch self {
        case .usage: "Usage counts, once a day: how often the app was opened and which features were used"
        case .crash: "Crash reports, after a crash: what went wrong and where in the app's code"
        }
    }
}

/// "Share anonymous usage and crash reports", worded for what the app links.
func sharingTitle(_ shares: [SharedData]) -> String {
    switch (shares.contains(.usage), shares.contains(.crash)) {
    case (true, true): "Share anonymous usage and crash reports"
    case (false, true): "Share anonymous crash reports"
    default: "Share anonymous usage"
    }
}

/// What the switch sends, in a few short lines: the popover content, also usable on an About page.
public struct PrivacySummary: View {
    let shares: [SharedData]

    public init(shares: [SharedData]) { self.shares = shares }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When this is on, the app sends:").font(.headline)
            ForEach(shares) { Text("• \($0.line)") }
            Text("• App version, system version and chip")
            Text("No name, email, files or IP address. Each report carries a random id made on this device and renewed every 90 days.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }
}

/// A small superscript "1" with a dotted underline. Hover (macOS) or tap (iOS) shows what is shared.
struct ShareFootnote: View {
    let shares: [SharedData]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text("1").font(.caption.weight(.medium)).underline(pattern: .dot).foregroundStyle(.secondary)
                .baselineOffset(6)
        }
        .buttonStyle(.borderless)
        #if os(macOS)
        .onHover { showing = $0 }
        #endif
        .popover(isPresented: $showing, arrowEdge: .top) {
            PrivacySummary(shares: shares).presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("What is shared")
        .accessibilityHint(shares.map(\.line).joined(separator: ". "))
    }
}

/// A drop-in Settings section: one switch row. Put it last in a grouped `Form`.
/// On by default is the app's choice (`@AppStorage(...) = true`).
public struct PrivacySection: View {
    @Binding var isOn: Bool
    let shares: [SharedData]

    /// - Parameter shares: what the app links (`.usage` for IndieCrumbUsage, `.crash` for IndieCrumbCrash).
    public init(isOn: Binding<Bool>, shares: [SharedData]) {
        _isOn = isOn; self.shares = shares
    }

    public var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(sharingTitle(shares))
                    ShareFootnote(shares: shares)
                }
            }
        }
    }
}
