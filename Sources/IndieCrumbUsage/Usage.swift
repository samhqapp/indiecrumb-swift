import Foundation
import IndieCrumbCore

/// The daily usage ping: one `POST /ic/v1/ping` per UTC day with the uses and counters since the last
/// ping. Counts live in a small file, so the core's off switch deletes them with everything else.
public final class Usage: @unchecked Sendable {
    static let route = "/ic/v1/ping"

    struct Counts: Codable {
        var lastDay: Int?
        var lastMonth: Int?
        var uses = 0
        var counters: [String: Int] = [:]
    }

    let core: IndieCrumb
    let lock = NSLock()
    let queue = DispatchQueue(label: "IndieCrumbUsage", qos: .utility)
    var timer: DispatchSourceTimer?
    var file: URL { core.directory.appendingPathComponent("usage.json") }

    public init(_ core: IndieCrumb) { self.core = core }

    /// Counts one use of the app's main action. Cheap; safe from any thread.
    public func recordUse() { change { $0.uses += 1 } }

    /// Adds to a named counter. The project defines the names on the dashboard; the server drops others.
    /// At most 16 names are kept.
    public func add(_ name: String, _ n: Int = 1) {
        change { c in
            guard n > 0, c.counters[name] != nil || c.counters.count < 16 else { return }
            c.counters[name, default: 0] += n
        }
    }

    /// Pings now when due, then checks every hour while the app runs. `pro` is read at each ping.
    public func start(pro: @escaping @Sendable () -> Bool = { false }) {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 3600, leeway: .seconds(60))
            t.setEventHandler { [weak self] in self?.pingIfDue(pro: pro()) }
            t.resume()
            timer = t
        }
    }

    /// Sends the ping when none went today (UTC). Nil when not due. Blocking. A failed ping keeps its
    /// counts for the next try; it is never queued, so a late ping can't count for the wrong day.
    @discardableResult public func pingIfDue(pro: Bool) -> Delivery? {
        guard core.isEnabled else { return .off }
        let t = core.now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = Int(t.timeIntervalSince1970 / 86400)
        let ym = cal.dateComponents([.year, .month], from: t)
        let month = ym.year! * 12 + ym.month! - 1
        let c = lock.withLock { load() }
        if c.lastDay == day { return nil }
        let body: [String: Any] = [
            "version": core.version, "build": core.build, "os": Platform.os, "os_major": Platform.osMajor,
            "arch": Platform.arch, "d": 1, "m": c.lastMonth == month ? 0 : 1, "uses": min(c.uses, 1023),
            "pro": pro, "counters": c.counters,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        let res = core.sendNow(route: Self.route, body: data, install: true)
        switch res {
        case .sent, .rejected:
            change { now in
                now.lastDay = day
                now.lastMonth = month
                now.uses = max(0, now.uses - c.uses)
                for (k, v) in c.counters {
                    let left = (now.counters[k] ?? 0) - v
                    now.counters[k] = left > 0 ? left : nil
                }
            }
        default: break
        }
        return res
    }

    /// Caller holds `lock`.
    func load() -> Counts {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Counts.self, from: $0) } ?? Counts()
    }

    func change(_ f: (inout Counts) -> Void) {
        guard core.isEnabled else { return }
        lock.withLock {
            var c = load()
            f(&c)
            if let d = try? JSONEncoder().encode(c) { try? writePrivate(d, to: file) }
        }
    }
}
