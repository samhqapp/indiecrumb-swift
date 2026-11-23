import Foundation

/// What happened to one item.
public enum Delivery: Equatable, Sendable {
    /// The server took it.
    case sent
    /// It waits on disk and goes with the next `flush()`.
    case queued
    /// The server refused it for good (bad body, unknown key); it was deleted.
    case rejected(Int)
    /// The switch is off; nothing was stored or sent.
    case off
}

/// The core: transport, ingest key, install id, the on/off switch and the offline queue.
/// Every send blocks the calling thread; call it off the main thread (the module APIs do).
public final class IndieCrumb: @unchecked Sendable {
    /// Sends one POST and returns the status and `Retry-After` seconds, or nil on a network failure.
    public typealias Transport = @Sendable (URLRequest) -> (status: Int, retryAfter: TimeInterval?)?

    static let queueFiles = 10
    static let queueBytes = 1 << 20
    static let queueAge: TimeInterval = 7 * 86400
    static let installAge: TimeInterval = 90 * 86400
    static let revokedPause: TimeInterval = 7 * 86400

    struct State: Codable {
        var install = ""
        var installMade = Date.distantPast
        var retryAt = Date.distantPast
        var backoff: TimeInterval = 0
    }

    public let endpoint: URL
    public let key: String
    public let version: String
    public let build: String
    public let directory: URL
    let transport: Transport
    package let now: @Sendable () -> Date
    let lock = NSLock() // guards state and enabledFlag
    let sendLock = NSLock() // one send at a time
    var state: State
    var enabledFlag = true

    /// - Parameters:
    ///   - endpoint: base URL, such as `https://crumb.samhq.app`.
    ///   - key: the public ingest key, `ic_pub_...`.
    ///   - enabled: the app's Settings switch. Off: nothing is sent and the queue is deleted.
    ///   - directory: a folder the SDK owns; default `Application Support/<bundle id>/IndieCrumb`.
    public init(endpoint: URL, key: String, enabled: Bool, version: String? = nil, build: String? = nil,
                directory: URL? = nil, transport: Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.endpoint = endpoint
        self.key = key
        self.version = version ?? info["CFBundleShortVersionString"] as? String ?? "0"
        self.build = build ?? info["CFBundleVersion"] as? String ?? ""
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app").appendingPathComponent("IndieCrumb")
        self.transport = transport ?? IndieCrumb.urlSession
        self.now = now
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        state = (try? Data(contentsOf: self.directory.appendingPathComponent("state.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        isEnabled = enabled
    }

    /// The default transport: URLSession, 20 second timeout, no cookies or cache.
    public static let urlSession: Transport = { req in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Int, TimeInterval?)?
        var req = req
        req.timeoutInterval = 20
        session.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse {
                out = (h.statusCode, (h.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init))
            }
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    /// Wire this to the Settings switch. Off deletes the queue, crash reports and usage counts at once.
    public var isEnabled: Bool {
        get { lock.withLock { enabledFlag } }
        set {
            lock.withLock { enabledFlag = newValue }
            guard !newValue else { return }
            sendLock.withLock {
                let fm = FileManager.default
                for u in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where u.lastPathComponent != "state.json" {
                    try? fm.removeItem(at: u)
                }
            }
        }
    }

    /// The random 32-hex install id, made on this device and renewed every 90 days.
    public var installID: String {
        lock.withLock {
            if state.install.count != 32 || now().timeIntervalSince(state.installMade) > Self.installAge {
                state.install = randomHex(16)
                state.installMade = now()
                saveState()
            }
            return state.install
        }
    }

    // MARK: queue

    var queueDir: URL { directory.appendingPathComponent("queue") }

    /// Sends every queued item, oldest first, until one fails. Returns how many went.
    @discardableResult public func flush() -> Int { sendLock.withLock { flushLocked() }.sent }

    /// Caller holds `sendLock`. With the switch off, every item the user did not send is deleted unsent.
    func flushLocked() -> (sent: Int, dropped: [String: Int]) {
        var sent = 0
        var dropped: [String: Int] = [:]
        for (url, _) in queueItems() {
            guard let raw = try? Data(contentsOf: url), let nl = raw.firstIndex(of: 0x0A) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Header: "<route> <install 0|1> <user-sent 0|1>"
            let head = String(decoding: raw[raw.startIndex..<nl], as: UTF8.self).split(separator: " ")
            guard isEnabled || (head.count > 2 && head[2] == "1") else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let body = raw[raw.index(after: nl)...]
            switch post(route: String(head.first ?? ""), body: Data(body), install: head.count > 1 && head[1] == "1") {
            case .sent:
                try? FileManager.default.removeItem(at: url)
                sent += 1
            case .drop(let code):
                try? FileManager.default.removeItem(at: url)
                dropped[url.lastPathComponent] = code
            case .retry:
                return (sent, dropped)
            }
        }
        return (sent, dropped)
    }

    /// Stores one request in the queue, then sends the queue. The switch check and the write share
    /// `sendLock`, so turning the switch off cannot fall between them.
    /// - Parameter userSent: the user pressed Send on it, so it goes even with the switch off (without the install id).
    package func enqueueAndFlush(route: String, body: Data, install: Bool, userSent: Bool = false) -> Delivery {
        sendLock.withLock {
            guard isEnabled || userSent else { return .off }
            let name = String(format: "%010d-", Int(now().timeIntervalSince1970)) + randomHex(4)
            let file = queueDir.appendingPathComponent(name)
            // The install id is allowed only if sharing was on when queued; send time checks again.
            var data = Data("\(route) \(install && isEnabled ? 1 : 0) \(userSent ? 1 : 0)\n".utf8)
            data.append(body)
            guard data.count <= Self.queueBytes,
                  (try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])) != nil,
                  (try? writePrivate(data, to: file)) != nil else { return .rejected(413) }
            pruneQueue()
            let (_, dropped) = flushLocked()
            if let code = dropped[name] { return .rejected(code) }
            return FileManager.default.fileExists(atPath: file.path) ? .queued : .sent
        }
    }

    /// Sends one request now, without the queue (the usage ping: a late ping must not count for a later day).
    package func sendNow(route: String, body: Data, install: Bool) -> Delivery {
        sendLock.withLock {
            guard isEnabled else { return .off }
            switch post(route: route, body: body, install: install) {
            case .sent: return .sent
            case .retry: return .queued
            case .drop(let c): return .rejected(c)
            }
        }
    }

    enum Outcome { case sent, retry, drop(Int) }

    /// One POST with the backoff rules: 2xx sent; 410 key revoked, pause 7 days; 429, 5xx or no network,
    /// wait `Retry-After` or 1 minute doubling to 6 hours; any other status drops the item.
    func post(route: String, body: Data, install: Bool) -> Outcome {
        let t = now()
        guard lock.withLock({ state.retryAt <= t }) else { return .retry }
        let base = endpoint.absoluteString.hasSuffix("/") ? String(endpoint.absoluteString.dropLast()) : endpoint.absoluteString
        guard let url = URL(string: base + route) else { return .drop(400) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-IC-Key")
        if install, isEnabled { req.setValue(installID, forHTTPHeaderField: "X-IC-Install") }   // checked at send time
        let res = transport(req)
        return lock.withLock {
            defer { saveState() }
            switch res?.status {
            case let s? where (200..<300).contains(s):
                state.backoff = 0
                return .sent
            case 410?:
                state.retryAt = t.addingTimeInterval(Self.revokedPause)
                return .drop(410)
            case let s? where s != 429 && s < 500:
                return .drop(s)
            default:
                state.backoff = min(max(state.backoff * 2, 60), 6 * 3600)
                let wait = max(res?.retryAfter ?? 0, state.backoff)
                state.retryAt = t.addingTimeInterval(min(wait, Self.revokedPause))
                return .retry
            }
        }
    }

    /// Oldest first, with sizes.
    func queueItems() -> [(URL, Int)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            .sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    /// Deletes items older than 7 days, then the oldest until at most 10 files and 1 MB are left.
    func pruneQueue() {
        let t = now().timeIntervalSince1970
        var items = queueItems().filter { url, _ in
            let made = TimeInterval(url.lastPathComponent.prefix(10)) ?? 0
            if t - made > Self.queueAge { try? FileManager.default.removeItem(at: url); return false }
            return true
        }
        var total = items.reduce(0) { $0 + $1.1 }
        while items.count > Self.queueFiles || total > Self.queueBytes {
            let (url, size) = items.removeFirst()
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// Caller holds `lock`.
    func saveState() {
        if let d = try? JSONEncoder().encode(state) {
            try? writePrivate(d, to: directory.appendingPathComponent("state.json"))
        }
    }

    // For tests.
    package func setRetryAt(_ d: Date) { lock.withLock { state.retryAt = d } }
    package var queuedCount: Int { queueItems().count }
}

// MARK: helpers shared by the modules

package func randomHex(_ bytes: Int) -> String {
    var g = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
}

/// Atomic write, owner-only.
package func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

package enum Platform {
    #if os(iOS)
    package static let os = "ios"
    static let osName = "iOS"
    #else
    package static let os = "macos"
    static let osName = "macOS"
    #endif
    package static var osMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    package static var osLabel: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(osName) \(v.majorVersion).\(v.minorVersion)"
    }
    #if arch(arm64)
    package static let arch = "arm64"
    #else
    package static let arch = "x86_64"
    #endif
    /// The model id, such as `Mac15,3` or `iPhone16,1`. Names no person.
    package static var model: String {
        #if os(iOS)
        let key = "hw.machine"   // hw.model is the board id on iOS
        #else
        let key = "hw.model"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var buf = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname(key, &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Replaces the home folder and `/Users/<name>` parts with `~`, so no user name or home path leaves
/// the device, then cuts to `max` characters.
package func scrub(_ s: String, max: Int = 256) -> String {
    var out = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    for prefix in ["/Users/", "/home/"] {
        while let r = out.range(of: prefix) {
            let rest = out[r.upperBound...]
            let end = rest.firstIndex(where: { "/ \n\"'".contains($0) }) ?? rest.endIndex
            out.replaceSubrange(r.lowerBound..<end, with: "~")
        }
    }
    return String(out.prefix(max))
}
