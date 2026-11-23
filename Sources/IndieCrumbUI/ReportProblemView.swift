import IndieCrumbFeedback
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// "Report a problem": a stock grouped form in a sheet, with the kind, the message, an optional email,
/// a screenshot, the last crash report and the exact payload. Cancel is Escape, Send is Return.
/// Present it with `.sheet`; on iOS it brings its own navigation bar.
public struct ReportProblemView: View {
    @Bindable var model: ReportProblemModel
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    public init(model: ReportProblemModel, close: (() -> Void)? = nil) {
        self.model = model; self.close = close
    }

    private func finish() {
        if model.asking { model.crash?.discard() }   // sent files are gone already; an unsent one never asks again
        if let close { close() } else { dismiss() }
    }
    private func send() { Task { await model.send() } }

    private var sent: Bool { if case .sent = model.phase { true } else { false } }

    @ViewBuilder private var content: some View {
        if case .sent(let queued) = model.phase { SentView(queued: queued) } else { ReportForm(model: model) }
    }

    #if os(macOS)
    /// At most 90% of the parent window; the form scrolls inside.
    private let height = min(500, (NSApp.mainWindow?.contentLayoutRect.height ?? 600) * 0.9)

    public var body: some View {
        VStack(spacing: 0) {
            content.frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Status(phase: model.phase)
                Spacer(minLength: 12)
                if sent {
                    Button("Done", action: finish).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: finish).keyboardShortcut(.cancelAction)
                    Button("Send", action: send).keyboardShortcut(.defaultAction).disabled(!model.canSend)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: height)
        .focusEffectDisabled()
        .dropDestination(for: URL.self) { urls, _ in urls.first.map { model.attach(file: $0) } ?? false }
    }
    #else
    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Report a Problem")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if sent {
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: finish) }
                    } else {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: finish) }
                        ToolbarItem(placement: .confirmationAction) {
                            if model.phase == .sending { ProgressView() } else {
                                Button("Send", action: send).disabled(!model.canSend)
                            }
                        }
                    }
                }
        }
        .focusEffectDisabled()
    }
    #endif
}

/// The form itself, the same on both platforms; only the screenshot row differs.
struct ReportForm: View {
    @Bindable var model: ReportProblemModel
    @State private var choosingFile = false

    var body: some View {
        Form {
            #if os(iOS)
            if case .failed(let message) = model.phase {
                Section { Status(phase: model.phase) }
            }
            #endif
            Section {
                Picker("Type", selection: $model.kind) {
                    Text("Bug").tag(FeedbackKind.bug)
                    Text("Idea").tag(FeedbackKind.idea)
                    Text("Question").tag(FeedbackKind.question)
                }
                TextEditor(text: $model.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text(model.asking ? "Optional: what were you doing when it quit?" : model.kind.prompt).foregroundStyle(.tertiary).allowsHitTesting(false)
                                #if os(iOS)
                                .padding(.top, 8).padding(.leading, 5)
                                #else
                                .padding(.leading, 5)
                                #endif
                        }
                    }
                    .accessibilityLabel("Message")
            } header: {
                #if os(macOS)
                Text(model.asking ? "\(model.appName) Quit Unexpectedly" : "Report a Problem")
                #endif
            }
            Section {
                #if os(iOS)
                LabeledContent("Email") {   // iOS hides a TextField's own label
                    TextField("Email", text: $model.email, prompt: Text("Optional"))
                        .textContentType(.emailAddress).multilineTextAlignment(.trailing)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                #else
                TextField("Email", text: $model.email, prompt: Text("Optional, for a reply"))
                    .textContentType(.emailAddress)
                #endif
                LabeledContent("Screenshot") { screenshot }
                if let crash = model.crash {
                    Toggle(isOn: $model.includeCrash) {
                        Text("Include last crash")
                        Text("Crashed \(crash.time.formatted(.relative(presentation: .named))), version \(crash.version)")
                    }
                }
            }
            Section {
                DisclosureGroup("What gets sent") {
                    Text(model.includeCrash ? model.payload + "\n\n" + (model.crash?.text ?? "") : model.payload)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("Nothing else is attached: no files, no name, no IP address.")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .scrollContentBackground(.hidden)   // one sheet color behind the form and the buttons
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                model.attach(file: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        #endif
    }

    @ViewBuilder private var screenshot: some View {
        if let s = model.screenshot {
            HStack(spacing: 8) {
                #if os(macOS)
                Text(s.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                #endif
                Thumbnail(image: s.image)
                Button("Remove", systemImage: "xmark.circle.fill") { model.screenshot = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless)
            }
        } else {
            #if os(macOS)
            Menu("Attach") {
                Section("Window") {
                    ForEach(model.windows, id: \.windowNumber) { window in
                        Button(window.title.isEmpty ? model.appName : window.title) { model.attach(window: window) }
                    }
                }
                Button("Choose File…") { choosingFile = true }
            }
            .fixedSize()
            #else
            PhotoAttach(model: model)
            #endif
        }
    }
}

#if os(iOS)
struct PhotoAttach: View {
    let model: ReportProblemModel
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker("Choose", selection: $item, matching: .images)
            .onChange(of: item) {
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { model.attach(data: data, name: "Screenshot") }
                    self.item = nil
                }
            }
    }
}
#endif

/// Sending or the error, beside the buttons (macOS) or at the top of the form (iOS).
struct Status: View {
    let phase: ReportProblemModel.Phase

    var body: some View {
        switch phase {
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        default:
            EmptyView()
        }
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

struct Thumbnail: View {
    let image: ReportImage

    var body: some View {
        #if os(macOS)
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 36, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
        #else
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 36, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
        #endif
    }
}

/// The confirmation, in the same sheet.
struct SentView: View {
    let queued: Bool

    var body: some View {
        ContentUnavailableView {
            Label { Text("Report Sent") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        } description: {
            Text(queued ? "You seem to be offline. It goes out on its own once you are back online."
                        : "Thank you. Every report is read.")
        }
    }
}
