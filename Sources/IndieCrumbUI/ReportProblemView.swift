import AppKit
import IndieCrumbFeedback
import SwiftUI
import UniformTypeIdentifiers

/// The three looks the owner picks from; the other two go once one is picked.
public enum ReportProblemLayout: Sendable { case form, compose, split }

/// "Report a problem": a sheet with the kind, the message, an optional email, a screenshot, the last
/// crash report and the exact payload. Cancel is Escape, Send is Return. Present it with `.sheet`.
public struct ReportProblemView: View {
    @Bindable var model: ReportProblemModel
    let layout: ReportProblemLayout
    var close: (() -> Void)?
    let payloadOpen: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false

    /// - Parameter payloadOpen: start with "What gets sent" open.
    public init(model: ReportProblemModel, layout: ReportProblemLayout = .form, payloadOpen: Bool = false,
                close: (() -> Void)? = nil) {
        self.model = model; self.layout = layout; self.payloadOpen = payloadOpen; self.close = close
    }

    public var body: some View {
        Group {
            if case .sent(let queued) = model.phase {
                SentView(queued: queued, done: finish)
            } else {
                switch layout {
                case .form: FormLayout(model: model, choosingFile: $choosingFile, footer: footer, showPayload: payloadOpen)
                case .compose: ComposeLayout(model: model, choosingFile: $choosingFile, footer: footer, showPayload: payloadOpen)
                case .split: SplitLayout(model: model, choosingFile: $choosingFile, footer: footer)
                }
            }
        }
        .frame(width: size.width)
        .frame(height: size.height)
        .focusEffectDisabled()
        .dropDestination(for: URL.self) { urls, _ in urls.first.map { model.attach(file: $0) } ?? false }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                model.attach(file: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private var size: CGSize {
        switch layout {
        case .form: CGSize(width: 520, height: 620)
        case .compose: CGSize(width: 560, height: 540)
        case .split: CGSize(width: 780, height: 540)
        }
    }

    private func finish() { if let close { close() } else { dismiss() } }

    /// Status on the leading side; Cancel, then the default Send, on the trailing side.
    private var footer: Footer { Footer(model: model, cancel: finish) }
}

// MARK: Shared parts

struct Footer: View {
    let model: ReportProblemModel
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 12)
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Send") { Task { await model.send() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

struct KindPicker: View {
    @Binding var kind: FeedbackKind

    var body: some View {
        Picker("Kind", selection: $kind) {
            Text("Bug").tag(FeedbackKind.bug)
            Text("Idea").tag(FeedbackKind.idea)
            Text("Question").tag(FeedbackKind.question)
        }
        .pickerStyle(.segmented)
    }
}

extension FeedbackKind {
    var prompt: String {
        switch self {
        case .bug: "What happened, and what did you expect instead?"
        case .idea: "What would make the app better for you?"
        case .question: "What would you like to know?"
        }
    }
}

/// A calm note inside the sheet only, never a window of its own.
struct CrashBanner: View {
    let crash: ReportCrash
    let appName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(appName) quit unexpectedly \(crash.time.formatted(.relative(presentation: .named))). The crash report is attached below.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The exact text, monospaced and selectable, in a sunken well.
struct PayloadText: View {
    let text: String
    var maxHeight: CGFloat? = 170

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// A multi-line editor with a placeholder, drawn as a macOS text field.
struct MessageEditor: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5).padding(.vertical, 7)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityLabel("Message")
    }
}

/// Attach menu: one of the app's windows, or a file.
struct AttachMenu: View {
    let model: ReportProblemModel
    @Binding var choosingFile: Bool
    var title = "Attach…"

    var body: some View {
        Menu(title) {
            Section("Window") {
                ForEach(model.windows, id: \.windowNumber) { window in
                    Button(window.title.isEmpty ? model.appName : window.title) { model.attach(window: window) }
                }
            }
            Button("Choose File…") { choosingFile = true }
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct Thumbnail: View {
    let image: NSImage
    var size = CGSize(width: 44, height: 30)

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove screenshot")
    }
}

func crashLine(_ crash: ReportCrash, short: Bool = false) -> String {
    let when = crash.time.formatted(.relative(presentation: .named))
    return short ? "\(when), version \(crash.version)" : "Crashed \(when), version \(crash.version)"
}

struct SentView: View {
    let queued: Bool
    let done: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: queued)
            Text("Report sent").font(.headline)
            Text(queued ? "You seem to be offline. It goes out on its own once you are back online."
                        : "Thank you. Every report is read.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: Option 1: a grouped form, like Task Manager Pro's Settings

struct FormLayout: View {
    @Bindable var model: ReportProblemModel
    @Binding var choosingFile: Bool
    let footer: Footer
    @State var showPayload = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    KindPicker(kind: $model.kind)
                    TextField("Message", text: $model.text, prompt: Text(model.kind.prompt), axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .labelsHidden()
                    TextField("Email", text: $model.email, prompt: Text("Optional, for a reply"))
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Report a problem").font(.headline).foregroundStyle(.primary)
                        Text("Goes straight to the \(model.appName) developer.").foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
                Section("Attachments") {
                    LabeledContent("Screenshot") {
                        if let s = model.screenshot {
                            HStack(spacing: 8) {
                                Thumbnail(image: s.image)
                                Text(s.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                RemoveButton { model.screenshot = nil }
                            }
                        } else {
                            AttachMenu(model: model, choosingFile: $choosingFile)
                        }
                    }
                    if let crash = model.crash {
                        Toggle(isOn: $model.includeCrash) {
                            Text("Include the last crash report")
                            Text(crashLine(crash))
                        }
                        DisclosureGroup("Show the crash report") { PayloadText(text: crash.text) }
                            .disabled(!model.includeCrash)
                    }
                }
                Section {
                    DisclosureGroup("What gets sent", isExpanded: $showPayload) { PayloadText(text: model.payload) }
                } footer: {
                    Text("Nothing else is attached: no files, no name, no IP address.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 18)
        }
    }
}

// MARK: Option 2: compose, content first, like a Mail message

struct ComposeLayout: View {
    @Bindable var model: ReportProblemModel
    @Binding var choosingFile: Bool
    let footer: Footer
    @State var showPayload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a problem").font(.headline)
                    Text("Goes straight to the developer.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                KindPicker(kind: $model.kind).labelsHidden().fixedSize()
            }
            if let crash = model.crash { CrashBanner(crash: crash, appName: model.appName) }
            MessageEditor(text: $model.text, prompt: model.kind.prompt)
                .frame(minHeight: 120, maxHeight: .infinity)
            TextField("Email", text: $model.email, prompt: Text("Email, optional, for a reply"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            HStack(spacing: 10) {
                screenshotTile
                if model.crash != nil { crashTile }
            }
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showPayload) {
                VStack(alignment: .leading, spacing: 8) {
                    PayloadText(text: model.payload, maxHeight: 130)
                    if model.includeCrash, let crash = model.crash { PayloadText(text: crash.text, maxHeight: 110) }
                }
                .padding(.top, 6)
            } label: {
                Text(model.includeCrash && model.crash != nil ? "What gets sent: this report and the crash report"
                                                              : "What gets sent")
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, -20)
            footer
        }
        .padding(20)
    }

    private var screenshotTile: some View {
        Tile {
            if let s = model.screenshot {
                Thumbnail(image: s.image, size: CGSize(width: 40, height: 28))
            } else {
                TileIcon(symbol: "photo.on.rectangle.angled")
            }
        } text: {
            Text("Screenshot")
            Text(model.screenshot?.name ?? "Pick a window or drop an image")
        } control: {
            if model.screenshot != nil {
                RemoveButton { model.screenshot = nil }
            } else {
                AttachMenu(model: model, choosingFile: $choosingFile, title: "Attach")
            }
        }
    }

    private var crashTile: some View {
        Tile {
            TileIcon(symbol: "exclamationmark.triangle")
        } text: {
            Text("Last crash report")
            Text(model.crash.map { crashLine($0, short: true) } ?? "")
        } control: {
            Toggle("Include the last crash report", isOn: $model.includeCrash)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// One attachment: icon, two lines, a control; equal width beside its neighbor.
struct Tile<Icon: View, Lines: View, Control: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let text: Lines
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Group { text }
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }
}

struct TileIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 28)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Option 3: two panes, the live payload always in view

struct SplitLayout: View {
    @Bindable var model: ReportProblemModel
    @Binding var choosingFile: Bool
    let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                compose.frame(width: 420)
                Divider()
                payload
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Report a problem").font(.headline)
                Text("Goes straight to the \(model.appName) developer.").font(.callout).foregroundStyle(.secondary)
            }
            KindPicker(kind: $model.kind).labelsHidden()
            MessageEditor(text: $model.text, prompt: model.kind.prompt)
                .frame(maxHeight: .infinity)
            TextField("Email", text: $model.email, prompt: Text("Email, optional, for a reply"))
                .textFieldStyle(.roundedBorder).labelsHidden()
            Divider()
            HStack(spacing: 8) {
                Text("Screenshot")
                Spacer()
                if let s = model.screenshot {
                    Thumbnail(image: s.image, size: CGSize(width: 36, height: 24))
                    RemoveButton { model.screenshot = nil }
                } else {
                    AttachMenu(model: model, choosingFile: $choosingFile)
                }
            }
            .frame(height: 24)
            if let crash = model.crash {
                Toggle(isOn: $model.includeCrash) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Include the last crash report")
                        Text(crashLine(crash)).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(20)
    }

    private var payload: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What gets sent").font(.headline)
            Text("This is the whole report. It updates as you type.")
                .font(.callout).foregroundStyle(.secondary)
            PayloadText(text: model.payload, maxHeight: .infinity)
            if model.includeCrash, let crash = model.crash {
                Text("Crash report").font(.subheadline.weight(.semibold)).padding(.top, 4)
                PayloadText(text: crash.text, maxHeight: 150)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}
