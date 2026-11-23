import Foundation
@testable import IndieCrumbCore
@testable import IndieCrumbCrash
@testable import IndieCrumbFeedback
@testable import IndieCrumbUsage
@testable import IndieCrumbUI
import AppKit
import XCTest

/// Answers from a list (default 202) and records every request.
final class Mock: @unchecked Sendable {
    var replies: [(Int, TimeInterval?)?] = []
    var sent: [URLRequest] = []
    let lock = NSLock()

    var transport: IndieCrumb.Transport {
        { req in
            self.lock.withLock {
                self.sent.append(req)
                return self.replies.isEmpty ? (202, nil) : self.replies.removeFirst()
            }
        }
    }

    func json(_ i: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: sent[i].httpBody!) as! [String: Any]
    }
}

final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 20_415 * 86400 + 3600) } // 2025-11-23

func tempDir(_ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("indiecrumb-\(name)-\(randomHex(4))")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func core(_ dir: URL, _ m: Mock, _ clock: Clock = Clock()) -> IndieCrumb {
    IndieCrumb(endpoint: URL(string: "https://x.test/")!, key: "ic_pub_test", enabled: true, version: "1.2.3",
               build: "45", directory: dir, transport: m.transport, now: { clock.t })
}

final class CoreTests: XCTestCase {
    func testInstallIDIs32HexAndStable() {
        let d = tempDir("install")
        let a = core(d, Mock()).installID
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(a, core(d, Mock()).installID)
    }

    func testQueueKeepsItemOnFailureAndSendsLater() {
        let m = Mock()
        m.replies = [nil]
        let c = core(tempDir("queue"), m)
        XCTAssertEqual(c.enqueueAndFlush(route: "/ic/v1/x", body: Data("{}".utf8), install: false), .queued)
        XCTAssertEqual(c.flush(), 0) // backoff
        c.setRetryAt(.distantPast)
        XCTAssertEqual(c.flush(), 1)
        XCTAssertEqual(c.queuedCount, 0)
        XCTAssertEqual(m.sent[1].url?.absoluteString, "https://x.test/ic/v1/x")
        XCTAssertNil(m.sent[1].value(forHTTPHeaderField: "X-IC-Install"))
        XCTAssertEqual(m.sent[1].value(forHTTPHeaderField: "X-IC-Key"), "ic_pub_test")
    }

    func testQueueCaps() {
        let c = core(tempDir("caps"), Mock())
        c.setRetryAt(.distantFuture)
        for _ in 0..<15 { _ = c.enqueueAndFlush(route: "/ic/v1/x", body: Data(count: 1000), install: false) }
        XCTAssertEqual(c.queuedCount, 10)
        for _ in 0..<4 { _ = c.enqueueAndFlush(route: "/ic/v1/x", body: Data(count: 300 << 10), install: false) }
        XCTAssertLessThanOrEqual(c.queueItems().reduce(0) { $0 + $1.1 }, 1 << 20)
    }

    func testRejectedDroppedAndRevokedPauses() {
        let m = Mock()
        m.replies = [(400, nil), (410, nil)]
        let c = core(tempDir("drop"), m)
        XCTAssertEqual(c.sendNow(route: "/ic/v1/x", body: Data(), install: true), .rejected(400))
        XCTAssertEqual(c.sendNow(route: "/ic/v1/x", body: Data(), install: true), .rejected(410))
        XCTAssertEqual(c.sendNow(route: "/ic/v1/x", body: Data(), install: true), .queued)
        XCTAssertEqual(m.sent.count, 2)
    }

    func testOffClearsAndSendsNothing() {
        let m = Mock()
        m.replies = [nil]
        let d = tempDir("off")
        let c = core(d, m)
        _ = c.enqueueAndFlush(route: "/ic/v1/x", body: Data("{}".utf8), install: false)
        try! Data("{}".utf8).write(to: d.appendingPathComponent("usage.json"))
        c.isEnabled = false
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path), ["state.json"])
        XCTAssertEqual(c.enqueueAndFlush(route: "/ic/v1/x", body: Data(), install: false), .off)
        XCTAssertEqual(Usage(c).pingIfDue(pro: false), .off)
        XCTAssertEqual(m.sent.count, 1)
    }

    func testScrub() {
        XCTAssertEqual(scrub("open /Users/alice/Library/x.txt failed"), "open ~/Library/x.txt failed")
        XCTAssertEqual(scrub(NSHomeDirectory() + "/a"), "~/a")
        XCTAssertEqual(scrub("abcdef", max: 3), "abc")
    }
}

final class FeedbackTests: XCTestCase {
    func testChecksFields() async {
        let c = core(tempDir("fbcheck"), Mock())
        for (text, email, shot, err) in [("  ", nil, nil, FeedbackError.emptyText),
                                         (String(repeating: "a", count: 4001), nil, nil, .textTooLong),
                                         ("hi", "nope", nil, .badEmail),
                                         ("hi", nil, Data("GIF".utf8), .badScreenshot)] as [(String, String?, Data?, FeedbackError)] {
            do {
                _ = try await c.sendFeedback(kind: .bug, text: text, email: email, screenshot: shot)
                XCTFail("expected \(err)")
            } catch { XCTAssertEqual(error as? FeedbackError, err) }
        }
    }

    func testSendsTheDocumentedBody() async throws {
        let m = Mock()
        let c = core(tempDir("fbsend"), m)
        let png = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/screenshot", withExtension: "png")!)
        let r = try await c.sendFeedback(kind: .idea, text: " Dark mode please ", email: "a@b.co", screenshot: png, pro: true)
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(m.sent[0].url?.absoluteString, "https://x.test/ic/v1/feedback")
        XCTAssertEqual(m.sent[0].value(forHTTPHeaderField: "X-IC-Install")?.count, 32)
        let v = m.json(0)
        XCTAssertEqual(Set(v.keys), ["build", "device", "email", "kind", "os", "pro", "screenshot", "text", "version"])
        XCTAssertEqual(v["text"] as? String, "Dark mode please")
        XCTAssertEqual(Data(base64Encoded: v["screenshot"] as! String), png) // fits already: sent as is
    }

    func testFitScreenshotShrinksLargeImages() throws {
        let png = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/screenshot", withExtension: "png")!)
        let small = try XCTUnwrap(fitScreenshot(png, maxBytes: 8000, maxSide: 300))
        XCTAssertLessThanOrEqual(small.count, 8000)
        XCTAssertTrue(small.starts(with: [0xFF, 0xD8, 0xFF]))
    }
}

final class UsageTests: XCTestCase {
    func testOnePingADayWithDocumentedBody() {
        let m = Mock()
        let clock = Clock()
        let u = Usage(core(tempDir("ping"), m, clock))
        for _ in 0..<3 { u.recordUse() }
        u.add("processes_ended", 2)
        XCTAssertEqual(u.pingIfDue(pro: true), .sent)
        clock.t += 3600
        XCTAssertNil(u.pingIfDue(pro: true))
        XCTAssertEqual(m.sent.count, 1)
        XCTAssertEqual(m.sent[0].url?.absoluteString, "https://x.test/ic/v1/ping")
        XCTAssertEqual(m.sent[0].value(forHTTPHeaderField: "X-IC-Install")?.count, 32)
        let v = m.json(0)
        XCTAssertEqual(Set(v.keys), ["arch", "build", "counters", "d", "m", "os", "os_major", "pro", "uses", "version"])
        XCTAssertEqual(v["d"] as? Int, 1)
        XCTAssertEqual(v["m"] as? Int, 1)
        XCTAssertEqual(v["uses"] as? Int, 3)
        XCTAssertEqual((v["counters"] as? [String: Int])?["processes_ended"], 2)
        clock.t += 86400
        XCTAssertEqual(u.pingIfDue(pro: false), .sent)
        XCTAssertEqual(m.json(1)["m"] as? Int, 0)
        XCTAssertEqual(m.json(1)["uses"] as? Int, 0)
    }

    func testFailedPingKeepsCounts() {
        let m = Mock()
        m.replies = [nil]
        let u = Usage(core(tempDir("pingfail"), m))
        u.recordUse()
        XCTAssertEqual(u.pingIfDue(pro: false), .queued)
        XCTAssertEqual(u.lock.withLock { u.load() }.uses, 1)
        XCTAssertNil(u.lock.withLock { u.load() }.lastDay)
    }
}

final class CrashTests: XCTestCase {
    static let tree = """
    {"callStackPerThread":true,"callStacks":[
      {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem_kernel.dylib","offsetIntoBinaryTextSegment":1,"binaryUUID":"A"}]},
      {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Task Manager Pro","offsetIntoBinaryTextSegment":4660,
        "binaryUUID":"B1","address":99,"subFrames":[{"binaryName":"AppKit","offsetIntoBinaryTextSegment":255,"binaryUUID":"C2"}]}]}]}
    """

    func testReportFromMetricKitValues() {
        let r = CrashReporter.report(version: "2.0", build: "200", time: Date(timeIntervalSince1970: 1000), exceptionType: 1,
                                     signal: 11, reason: "bad file /Users/alice/x", callStackTree: Data(Self.tree.utf8))
        XCTAssertEqual(r.message, "EXC_BAD_ACCESS / SIGSEGV / bad file ~/x")
        XCTAssertEqual(r.frames, [CrashFrame(image: "Task Manager Pro", offset: "0x1234", debug_id: "B1"),
                                  CrashFrame(image: "AppKit", offset: "0xff", debug_id: "C2")])
    }

    func testSpoolAskAndAuto() throws {
        let m = Mock()
        let clock = Clock()
        let c = core(tempDir("crash"), m, clock)
        let cr = CrashReporter(c)
        for _ in 0..<2 {
            cr.write(CrashReporter.report(version: "1.2.3", build: "45", time: clock.t, exceptionType: 10, signal: 6,
                                          reason: nil, callStackTree: Data(Self.tree.utf8)))
        }
        XCTAssertTrue(m.sent.isEmpty)
        let p = cr.pending
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(cr.send("../state.json"), .rejected(404))
        XCTAssertEqual(cr.send(p[0].id), .sent)
        XCTAssertNil(m.sent[0].value(forHTTPHeaderField: "X-IC-Install"), "Ask mode sends no install id")
        XCTAssertEqual(m.sent[0].url?.absoluteString, "https://x.test/ic/v1/crash")
        XCTAssertEqual(Set(m.json(0).keys), ["arch", "build", "file", "frames", "kind", "line", "message", "os", "os_major", "time", "version"])
        XCTAssertEqual(cr.sendAll(), [.sent])
        XCTAssertNotNil(m.sent[1].value(forHTTPHeaderField: "X-IC-Install"))
        XCTAssertTrue(cr.pending.isEmpty)
    }
}

/// Live run against a local stack. Skipped unless IC_E2E_URL is set (with IC_KEY and EDGE_SECRET).
final class E2ETests: XCTestCase {
    func testPingAndFeedbackReachTheServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IC_E2E_URL"].flatMap(URL.init(string:)), let key = env["IC_KEY"], let edge = env["EDGE_SECRET"] else {
            throw XCTSkip("IC_E2E_URL not set")
        }
        let transport: IndieCrumb.Transport = { req in
            var req = req
            req.setValue(edge, forHTTPHeaderField: "X-Edge-Secret") // Cloudflare adds it in production
            return IndieCrumb.urlSession(req)
        }
        let dir = tempDir("e2e")
        let c = IndieCrumb(endpoint: url, key: key, enabled: true, version: "0.9.2", build: "92", directory: dir, transport: transport)
        let u = Usage(c)
        u.recordUse()
        XCTAssertEqual(u.pingIfDue(pro: true), .sent)
        let png = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/screenshot", withExtension: "png")!)
        let r = try await c.sendFeedback(kind: .bug, text: "e2e from indiecrumb-swift: the CPU column sorts wrong", screenshot: png, pro: true)
        XCTAssertEqual(r, .sent)
        try FileManager.default.removeItem(at: dir)
    }
}

@MainActor
final class ReportProblemTests: XCTestCase {
    /// "What gets sent" is the real feedback body, with the screenshot shown as a size, never as base64.
    func testPayloadMatchesBodyAndHidesScreenshotBytes() throws {
        let m = ReportProblemModel(core: core(tempDir("report"), Mock()), appName: "Test")
        m.text = "List jumps"
        m.email = "a@b.co"
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        XCTAssertTrue(m.attach(data: png, name: "shot.png"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(m.payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "List jumps")
        XCTAssertEqual(json["email"] as? String, "a@b.co")
        XCTAssertTrue((json["screenshot"] as? String)?.hasPrefix("<PNG, ") == true)
        XCTAssertTrue(m.canSend)
        m.core.isEnabled = false
        XCTAssertFalse(m.canSend)   // Off in Settings sends nothing, this report included
    }
}
