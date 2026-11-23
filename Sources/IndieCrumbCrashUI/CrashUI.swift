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
import SwiftUI

/// Ask mode: after a crash, the next launch shows the report in the "Report a Problem" sheet with a
/// Send button. Nothing is sent unless the person presses Send; closing the window deletes the report.
@MainActor public enum CrashAsk {
    static var window: NSWindow?
    static var closing: NSObjectProtocol?

    /// Call once, early at launch, instead of `reporter.start()`. Shows the prompt now when a crash
    /// waits on disk, or later in this run when MetricKit delivers one.
    public static func start(_ reporter: CrashReporter, core: IndieCrumb, pro: Bool = false) {
        reporter.onNewCrash = { Task { @MainActor in show(reporter, core: core, pro: pro) } }
        reporter.start()
        show(reporter, core: core, pro: pro)
    }

    static func show(_ reporter: CrashReporter, core: IndieCrumb, pro: Bool) {
        guard window == nil, let crash = ReportCrash.latest(reporter) else { return }
        let model = ReportProblemModel(core: core, pro: pro, crash: crash, asking: true)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = model.appName
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ReportProblemView(model: model) { window?.close() })
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            crash.discard()
            MainActor.assumeIsolated {
                closing.map(NotificationCenter.default.removeObserver)
                closing = nil
                window = nil
            }
        }
        w.center()
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }   // never activates the app
        window = w
    }
}
#endif
