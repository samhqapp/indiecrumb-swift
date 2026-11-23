import Foundation
import IndieCrumbCore
import MetricKit

/// One frame: the code offset inside its binary, which the server maps to a function with the
/// release's symbol file.
public struct CrashFrame: Codable, Equatable, Sendable {
    /// The binary's name only, such as `Task Manager Pro`.
    public var image: String
    /// `0x`-hex offset into the binary's text segment.
    public var offset: String
    /// The binary's UUID, to find its symbol file.
    public var debug_id: String?
}

/// Exactly the JSON body that is sent (`id` stays local).
public struct CrashReport: Codable, Sendable {
    public var id = ""
    public var kind = "crash"
    public var message: String
    public var file = ""
    public var line = 0
    public var time: Int
    public var version: String
    public var build: String
    public var os = Platform.os
    public var os_major = Platform.osMajor
    public var arch = Platform.arch
    public var frames: [CrashFrame]

    enum CodingKeys: String, CodingKey {
        case kind, message, file, line, time, version, build, os, os_major, arch, frames
    }
}

/// Crash reports through MetricKit. macOS hands the last run's crash to the app at its next launch;
/// the reporter writes it to `<directory>/crashes/` and sends nothing by itself. The app then asks the
/// user (`pending`, `send(_:)`, `discard(_:)`; no install id is sent) or sends all (`sendAll()`).
public final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let route = "/ic/v1/crash"
    static let spoolFiles = 10
    static let spoolAge: TimeInterval = 7 * 86400

    let core: IndieCrumb
    var dir: URL { core.directory.appendingPathComponent("crashes") }

    /// Called on MetricKit's queue after a new crash is written; MetricKit delivers it some seconds after launch.
    public var onNewCrash: (@Sendable () -> Void)?

    public init(_ core: IndieCrumb) { self.core = core }

    /// Subscribe early at launch, so the last run's crash arrives in this run.
    public func start() {
        #if os(macOS)
        CrashSignals.install(dir: dir, version: core.version, build: core.build)
        #endif
        MXMetricManager.shared.add(self)
    }

    /// Writes crashes to disk even with the switch off, so "Report a problem" can offer one; off never sends them by itself.
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        defer { if payloads.contains(where: { !($0.crashDiagnostics ?? []).isEmpty }) { onNewCrash?() } }
        for p in payloads {
            for d in p.crashDiagnostics ?? [] {
                var reason: String?
                if #available(macOS 14.0, *) { reason = d.exceptionReason?.composedMessage }
                let r = Self.report(version: d.applicationVersion, build: d.metaData.applicationBuildVersion,
                                    time: p.timeStampEnd, exceptionType: d.exceptionType?.intValue,
                                    signal: d.signal?.intValue, reason: reason ?? d.terminationReason,
                                    callStackTree: d.callStackTree.jsonRepresentation())
                write(r)
            }
        }
    }

    /// Reports waiting on disk, oldest first. Files older than 7 days are deleted.
    public var pending: [CrashReport] {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let t = Int(core.now().timeIntervalSince1970)
        return urls.compactMap { u in
            guard var r = (try? Data(contentsOf: u)).flatMap({ try? JSONDecoder().decode(CrashReport.self, from: $0) }),
                  TimeInterval(t - r.time) <= Self.spoolAge else {
                try? fm.removeItem(at: u)
                return nil
            }
            r.id = u.lastPathComponent
            return r
        }
    }

    /// Ask mode: sends one report the user approved, without the install id. Blocking.
    public func send(_ id: String) -> Delivery { sendSpooled(id, install: false, userSent: true) }

    /// Deletes one report the user declined.
    public func discard(_ id: String) {
        if let u = path(id) { try? FileManager.default.removeItem(at: u) }
    }

    /// Auto mode: sends every waiting report, with the install id. Blocking; call it off the main thread.
    @discardableResult public func sendAll() -> [Delivery] {
        guard core.isEnabled else { return [] }
        return pending.map { sendSpooled($0.id, install: true) }
    }

    func sendSpooled(_ id: String, install: Bool, userSent: Bool = false) -> Delivery {
        guard let u = path(id), let body = try? Data(contentsOf: u) else { return .rejected(404) }
        try? FileManager.default.removeItem(at: u) // the queue owns it now
        return core.enqueueAndFlush(route: Self.route, body: body, install: install, userSent: userSent)
    }

    func path(_ id: String) -> URL? {
        let ok = !id.isEmpty && !id.hasPrefix(".") && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return ok ? dir.appendingPathComponent(id) : nil
    }

    func write(_ r: CrashReport) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).count < Self.spoolFiles,
              let d = try? JSONEncoder().encode(r) else { return }
        try? writePrivate(d, to: dir.appendingPathComponent(String(format: "%010d-", r.time) + randomHex(4) + ".json"))
    }

    static let exceptionNames = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE",
                                 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
    static let signalNames = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]

    /// Builds the report from MetricKit's values; the frames are the crashed thread's, innermost first.
    static func report(version: String, build: String, time: Date, exceptionType: Int?, signal: Int?,
                       reason: String?, callStackTree: Data) -> CrashReport {
        var parts: [String] = []
        if let e = exceptionType { parts.append(exceptionNames[e] ?? "EXC_\(e)") }
        if let s = signal { parts.append(signalNames[s] ?? "SIG\(s)") }
        if let r = reason, !r.isEmpty { parts.append(r) }
        return CrashReport(message: scrub(parts.joined(separator: " / ")), time: Int(time.timeIntervalSince1970),
                           version: version, build: build, frames: frames(callStackTree))
    }

    static func frames(_ json: Data) -> [CrashFrame] {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        let crashed = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frame = (crashed?["callStackRootFrames"] as? [[String: Any]])?.first
        var out: [CrashFrame] = []
        while let f = frame, out.count < 200 {
            let name = (f["binaryName"] as? String).map { String($0.split(separator: "/").last ?? "") } ?? ""
            let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            out.append(CrashFrame(image: String(name.prefix(256)), offset: "0x" + String(offset, radix: 16),
                                  debug_id: f["binaryUUID"] as? String))
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }
}
