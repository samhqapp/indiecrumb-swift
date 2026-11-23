import Foundation
import IndieCrumbCore
import IndieCrumbCrash
import IndieCrumbUI

extension ReportCrash {
    /// The newest crash waiting on disk, for "Report a problem"; nil when there is none.
    /// Sent with `send(_:)`, so it carries no install id. `discard` deletes every waiting crash.
    public static func latest(_ reporter: CrashReporter) -> ReportCrash? {
        guard let report = reporter.pending.last else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let id = report.id
        return ReportCrash(time: Date(timeIntervalSince1970: TimeInterval(report.time)), version: report.version,
                           text: text, send: { reporter.send(id) },
                           discard: { reporter.pending.forEach { reporter.discard($0.id) } })
    }
}

#if os(macOS)
import AppKit

/// Ask mode: after a crash, the next launch shows the macOS crash alert ("Report…", "Ignore"), then the
/// Problem Report window with the exact text that is sent. Nothing is sent unless the person presses
/// "Send to Developer"; Ignore, "Don't Send" and closing delete the crash, so it asks once.
@MainActor public enum CrashAsk {
    static var window: ProblemReportWindow?
    static var asking = false

    /// Call once, early at launch, instead of `reporter.start()`. Asks now when a crash waits on disk,
    /// or later in this run when MetricKit delivers one.
    public static func start(_ reporter: CrashReporter, core: IndieCrumb, pro: Bool = false) {
        reporter.onNewCrash = { Task { @MainActor in show(reporter, core: core, pro: pro) } }
        reporter.start()
        show(reporter, core: core, pro: pro)
    }

    static func show(_ reporter: CrashReporter, core: IndieCrumb, pro: Bool) {
        guard !asking, window == nil, let crash = ReportCrash.latest(reporter) else { return }
        asking = true
        Task { @MainActor in   // after launch finishes, so the modal alert never blocks the app's own setup
            let model = ReportProblemModel(core: core, pro: pro, crash: crash, asking: true)
            answer(alert(model.appName).runModal(), model)
            asking = false
        }
    }

    /// The macOS 27 crash alert. Critical style draws the caution icon over the app icon.
    static func alert(_ appName: String) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "\(appName) quit unexpectedly."
        a.informativeText = "Nothing is sent unless you press Send."
        a.addButton(withTitle: "Report…")
        a.addButton(withTitle: "Ignore").keyEquivalent = "\u{1b}"
        a.window.hidesOnDeactivate = false   // the app may still be in the background at launch
        for b in a.buttons { b.focusRingType = .none }
        return a
    }

    /// First button: the Problem Report window. Anything else (Ignore): delete the crash, send nothing.
    static func answer(_ response: NSApplication.ModalResponse, _ model: ReportProblemModel) {
        guard response == .alertFirstButtonReturn else { return model.crash?.discard() ?? () }
        let w = ProblemReportWindow(model) { window = nil }
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }   // never activates the app
        window = w
    }
}

/// The macOS Problem Report window: a comment field, the exact text that is sent, and
/// "Send to Developer" or "Don't Send". Sizes follow Apple's window (1000 x 740), at most 90% of the screen.
@MainActor class ProblemReportWindow: NSWindow, NSTextViewDelegate {
    let model: ReportProblemModel
    let closed: () -> Void
    let note = NSTextField(wrappingLabelWithString: "")
    let comment = NSTextView.scrollableTextView()
    let details = NSTextView.scrollableTextView()
    let send = NSButton(title: "Send to Developer", target: nil, action: nil)
    let dont = NSButton(title: "Don’t Send", target: nil, action: nil)

    init(_ model: ReportProblemModel, closed: @escaping () -> Void) {
        self.model = model; self.closed = closed
        let W: CGFloat = 1000
        let H = min(740, ((NSScreen.main?.visibleFrame.height ?? 900) * 0.9 - 28).rounded())
        super.init(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Problem Report for \(model.appName)"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Apple's window: no traffic lights, a left-aligned title with a document icon.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        titleVisibility = .hidden
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let doc = NSImageView(image: NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)!)
        doc.contentTintColor = .secondaryLabelColor
        doc.frame = NSRect(x: 18, y: 7, width: 14, height: 14)
        let t = Self.label(title, .systemFont(ofSize: 13, weight: .semibold), .secondaryLabelColor)
        t.frame = NSRect(x: 36, y: 5, width: 560, height: 17)
        bar.addSubview(doc); bar.addSubview(t)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = bar; acc.layoutAttribute = .leading
        addTitlebarAccessoryViewController(acc)

        let v = Flipped(frame: NSRect(x: 0, y: 0, width: W, height: H))
        contentView = v
        func add(_ x: NSView, _ r: NSRect) { x.frame = r; v.addSubview(x) }
        let icon = NSImageView(image: NSImage(named: NSImage.cautionName)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        add(icon, NSRect(x: 20, y: 20, width: 64, height: 64))
        add(Self.label("\(model.appName) quit unexpectedly.", .boldSystemFont(ofSize: 13)), NSRect(x: 99, y: 24, width: 860, height: 17))
        note.font = .systemFont(ofSize: 11)
        note.stringValue = "Click “Send to Developer” to send this report to the developer. Nothing else is sent."
        add(note, NSRect(x: 99, y: 54, width: 860, height: 15))

        add(Self.label("Comments", .systemFont(ofSize: 13)), NSRect(x: 101, y: 96, width: 200, height: 17))
        comment.borderType = .lineBorder; comment.hasVerticalScroller = false
        let ct = comment.documentView as! NSTextView
        ct.font = .systemFont(ofSize: 13); ct.textContainerInset = NSSize(width: 2, height: 4)
        ct.isRichText = false; ct.allowsUndo = true; ct.delegate = self
        ct.setValue(NSAttributedString(string: "Optional: what were you doing when it quit?",
                                       attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 13)]),
                    forKey: "placeholderAttributedString")
        add(comment, NSRect(x: 99, y: 118, width: 880, height: 73))

        add(Self.label("Problem Details", .systemFont(ofSize: 13)), NSRect(x: 101, y: 200, width: 400, height: 17))
        details.borderType = .lineBorder
        let dt = details.documentView as! NSTextView
        dt.isEditable = false; dt.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dt.textContainerInset = NSSize(width: 2, height: 5)
        add(details, NSRect(x: 99, y: 220, width: 880, height: H - 278))   // the only part that shrinks on a short screen

        // A push button paints 6 pt inside its frame on each side and 2 pt top and bottom: 121 x 28 shows Apple's 109 x 24 bezel.
        send.bezelStyle = .push; send.keyEquivalent = "\r"; send.target = self; send.action = #selector(sendPressed)
        send.sizeToFit()
        let sw = max(122, send.frame.width + 8)
        add(send, NSRect(x: 985 - sw, y: H - 46, width: sw, height: 28))
        dont.bezelStyle = .push; dont.keyEquivalent = "\u{1b}"; dont.target = self; dont.action = #selector(dontPressed)
        add(dont, NSRect(x: 985 - sw - 1 - 121, y: H - 46, width: 121, height: 28))

        for x: NSView in [comment, details, ct, dt, send, dont] { x.focusRingType = .none }
        showText()
        initialFirstResponder = ct
        center()
    }

    static func label(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = font; l.textColor = color; return l
    }

    /// The exact text that is sent: the crash, plus the feedback item when there is a comment.
    func showText() {
        let crash = model.crash?.text ?? ""
        (details.documentView as! NSTextView).string = model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? crash : crash + "\n\n" + model.payload
    }

    func textDidChange(_ notification: Notification) {
        model.text = (comment.documentView as! NSTextView).string
        showText()
    }

    @objc func sendPressed() {
        send.isEnabled = false; dont.isEnabled = false
        Task {
            await model.send()
            if case .failed(let message) = model.phase {
                note.stringValue = message
                send.isEnabled = true; dont.isEnabled = true
            } else {
                close()
            }
        }
    }

    @objc func dontPressed() { close() }

    /// Every way out deletes what is left, so the same crash never asks again; a sent one is gone already.
    override func close() {
        model.crash?.discard()
        super.close()
        closed()
    }
}

private final class Flipped: NSView { override var isFlipped: Bool { true } }
#endif
