import SwiftUI

/// What the switch covers: one case per module the app links. The update check is not under the
/// switch; it always runs.
public enum SharedData: String, CaseIterable, Identifiable, Sendable {
    case usage, crash

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: "Usage, once a day"
        case .crash: "Crash reports, after a crash"
        }
    }

    /// Field and a real example, as the README's "Every field sent" lists them.
    var fields: [(String, String)] {
        switch self {
        case .usage: [("App and macOS version", "1.4.2, macOS 15, Apple silicon"),
                      ("Times you used the app that day", "12"),
                      ("Feature counts", "processes ended: 3"),
                      ("Paid version", "Yes or no")]
        case .crash: [("What went wrong", "EXC_BAD_ACCESS / SIGSEGV"),
                      ("Where in the app's code", "up to 200 code addresses"),
                      ("App and macOS version", "1.4.2, macOS 15")]
        }
    }
}

/// "Share anonymous usage and crash reports", worded for what the app links.
func sharingTitle(_ shares: [SharedData]) -> String {
    switch (shares.contains(.usage), shares.contains(.crash)) {
    case (true, true): "Share anonymous usage and crash reports"
    case (false, true): "Share anonymous crash reports"
    default: "Share anonymous usage reports"
    }
}

/// The fields, grouped by what sends them. Every row names a real example value.
struct SharedFields: View {
    let shares: [SharedData]

    var body: some View {
        ForEach(shares) { share in
            Text(share.title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(share.fields, id: \.0) { field in
                LabeledContent(field.0) { Text(field.1).foregroundStyle(.secondary) }
            }
        }
        Text("Each report also carries a random id made on this Mac and renewed every 90 days. No name, email, file, or IP address is stored.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A drop-in Settings section: the switch, one plain sentence, and "See what's shared".
/// Put it last in a grouped `Form`. On by default is the app's choice (`@AppStorage(...) = true`).
public struct PrivacySection: View {
    @Binding var isOn: Bool
    let shares: [SharedData]
    let appName: String
    @State private var showFields: Bool

    public init(isOn: Binding<Bool>, shares: [SharedData], appName: String, showFields: Bool = false) {
        _isOn = isOn; self.shares = shares; self.appName = appName; _showFields = State(initialValue: showFields)
    }

    public var body: some View {
        Section {
            Toggle(sharingTitle(shares), isOn: $isOn)
            DisclosureGroup("See what's shared", isExpanded: $showFields) { SharedFields(shares: shares) }
        } header: {
            Text("Privacy")
        } footer: {
            Text("This helps fix crashes. When it is off, \(appName) only checks for updates.")
        }
    }
}

/// The About-page line: the switch inline with "What's shared", or, with `openSettings`, a read-only
/// state with a link to the Settings switch. It takes the app's toggle style from the environment.
public struct PrivacyAboutLine: View {
    @Binding var isOn: Bool
    let shares: [SharedData]
    let openSettings: (() -> Void)?
    @State private var showFields: Bool

    public init(isOn: Binding<Bool>, shares: [SharedData], openSettings: (() -> Void)? = nil, showFields: Bool = false) {
        _isOn = isOn; self.shares = shares; self.openSettings = openSettings; _showFields = State(initialValue: showFields)
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let openSettings {
                    Text(isOn ? "Anonymous usage and crash reports are on." : "Anonymous reports are off.")
                        .foregroundStyle(.secondary)
                    Button("Change in Settings", action: openSettings).buttonStyle(.link)
                } else {
                    // The label is its own Text, so a custom switch style that draws only the track keeps it.
                    Text(sharingTitle(shares))
                    Toggle(sharingTitle(shares), isOn: $isOn).labelsHidden()
                    Button(showFields ? "Hide what's shared" : "What's shared") {
                        withAnimation(.snappy(duration: 0.2)) { showFields.toggle() }
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.callout)
            if showFields, openSettings == nil {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(shares) { share in
                        ForEach(share.fields, id: \.0) { field in
                            GridRow {
                                Text(field.0)
                                Text(field.1).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
