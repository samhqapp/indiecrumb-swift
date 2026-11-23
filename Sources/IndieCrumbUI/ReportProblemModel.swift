#if os(macOS)
import AppKit
public typealias ReportImage = NSImage
#else
import UIKit
public typealias ReportImage = UIImage
#endif
import IndieCrumbCore
import IndieCrumbFeedback
import Observation

/// The last crash, as "Report a problem" offers it. `IndieCrumbCrashUI` makes one from a `CrashReporter`,
/// so this module never links MetricKit.
public struct ReportCrash: Sendable {
    public var time: Date
    public var version: String
    /// The exact JSON body that is sent, pretty printed.
    public var text: String
    /// Sends it, blocking; called off the main thread.
    public var send: @Sendable () -> Delivery
    /// Deletes it unsent; the Ask prompt calls it when it closes.
    public var discard: @Sendable () -> Void

    public init(time: Date, version: String, text: String, send: @escaping @Sendable () -> Delivery,
                discard: @escaping @Sendable () -> Void = {}) {
        self.time = time; self.version = version; self.text = text; self.send = send; self.discard = discard
    }
}

/// One attached image, already scaled to what is sent.
public struct ReportScreenshot {
    public var name: String
    public var data: Data
    public var image: ReportImage
}

/// State of one "Report a problem" sheet.
@MainActor @Observable
public final class ReportProblemModel {
    public enum Phase: Equatable { case editing, sending, sent(queued: Bool), failed(String) }

    public var kind: FeedbackKind = .bug
    public var text = ""
    public var email = ""
    public var screenshot: ReportScreenshot?
    public var includeCrash: Bool
    public var phase: Phase = .editing
    public let crash: ReportCrash?
    public let appName: String
    /// Opened by itself after a crash: the message is optional and closing deletes the crash.
    public let asking: Bool
    @ObservationIgnored let core: IndieCrumb
    @ObservationIgnored let pro: Bool

    /// - Parameters:
    ///   - crash: the last crash, when the app links IndieCrumbCrashUI (`.latest(reporter)`). Included by default.
    ///   - pro: the paid tier, so the dashboard marks the item.
    ///   - asking: the after-crash prompt (`CrashAsk`), not the Help menu sheet.
    public init(core: IndieCrumb, pro: Bool = false, crash: ReportCrash? = nil, appName: String? = nil, asking: Bool = false) {
        self.core = core
        self.pro = pro
        self.crash = crash
        self.asking = asking
        includeCrash = crash != nil && (asking || core.isEnabled)   // switch off: the user may still turn it on
        self.appName = appName ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
    }

    var trimmedEmail: String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? nil : e
    }

    /// The switch never blocks this: the user pressed Send.
    public var canSend: Bool { (hasText || (includeCrash && crash != nil)) && phase != .sending }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What gets sent: the real feedback body, with the screenshot shown as its size instead of its base64.
    public var payload: String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (try? core.feedbackBody(kind: kind, text: message.isEmpty ? "…" : message, email: trimmedEmail,
                                           screenshot: nil, pro: pro))
            ?? (try? core.feedbackBody(kind: kind, text: "…", email: nil, screenshot: nil, pro: pro))
        guard let body, var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        if let s = screenshot {
            let type = s.data.starts(with: [0x89, 0x50]) ? "PNG" : "JPEG"
            json["screenshot"] = "<\(type), \(s.data.count.formatted(.byteCount(style: .file))), base64>"
        }
        let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return out.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    #if os(macOS)
    /// The app's own windows that can be attached as a screenshot (not sheets or panels).
    public var windows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !$0.isSheet && !($0 is NSPanel) && $0.contentView != nil }
    }

    /// Draws one of the app's own windows into a PNG; no screen-recording permission needed.
    public func attach(window: NSWindow) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        attach(data: png, name: window.title.isEmpty ? appName : window.title)
    }
    #endif

    /// An image file the user picked or dropped. False when it is not an image.
    @discardableResult public func attach(file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return attach(data: data, name: file.lastPathComponent)
    }

    @discardableResult public func attach(data: Data, name: String) -> Bool {
        guard let fit = fitScreenshot(data), let image = ReportImage(data: fit) else { return false }
        screenshot = ReportScreenshot(name: name, data: fit, image: image)
        return true
    }

    public func send() async {
        guard canSend else { return }
        phase = .sending
        do {
            var results: [Delivery] = []
            if hasText {   // a crash alone sends no feedback item
                results.append(try await core.sendFeedback(kind: kind, text: text, email: trimmedEmail,
                                                           screenshot: screenshot?.data, pro: pro))
            }
            if includeCrash, let crash {
                results.append(await Task.detached(priority: .utility) { crash.send() }.value)
            }
            if results.allSatisfy({ $0 == .sent || $0 == .queued }) {
                phase = .sent(queued: results.contains(.queued))
            } else {
                phase = .failed("The report could not be sent. Try again later.")
            }
        } catch FeedbackError.badEmail {
            phase = .failed("Check the email address.")
        } catch FeedbackError.textTooLong {
            phase = .failed("The message is longer than 4,000 characters.")
        } catch {
            phase = .failed("The screenshot could not be read.")
        }
    }
}
