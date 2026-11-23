#if os(macOS)
import Darwin
import Foundation
import IndieCrumbCore
import MachO

/// Catches fatal signals (SEGV, BUS, ILL, FPE, TRAP, and ABRT, which uncaught exceptions and Swift
/// traps end in), saves the crash file the same way MetricKit's are saved, then ends with `_exit`.
/// The process never dies from a signal, so macOS makes no .ips report and shows no "quit
/// unexpectedly" alert; the app's own prompt asks at the next launch.
/// shortcut: crashes no handler can catch (SIGKILL from the OS, a watchdog or memory kill, a fault
/// on a thread without its own signal stack that overflows its stack) still go to Apple and to MetricKit.
/// shortcut: the handler calls dladdr and walks frame pointers; a crash inside dyld or with a broken
/// frame chain may end without a file. A dedicated crash library would cover it if that ever matters.
enum CrashSignals {
    static let signals = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT]
    static let capacity = 60_000
    nonisolated(unsafe) static var installed = false
    nonisolated(unsafe) static var head: [UInt8] = []   // the fixed fields, ending in ","
    nonisolated(unsafe) static var dir: [UInt8] = []    // "<crashes dir>/"
    nonisolated(unsafe) static var buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    nonisolated(unsafe) static var path = UnsafeMutablePointer<CChar>.allocate(capacity: 1100)
    nonisolated(unsafe) static var len = 0

    /// Prepares every byte the handler needs, then installs it. Once per process.
    static func install(dir url: URL, version: String, build: String) {
        guard !installed, url.path.utf8.count < 1000 else { return }
        installed = true
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixed: [String: Any] = ["kind": "crash", "file": "", "line": 0, "version": version, "build": build,
                                    "os": Platform.os, "os_major": Platform.osMajor, "arch": Platform.arch]
        guard let json = try? JSONSerialization.data(withJSONObject: fixed, options: [.sortedKeys]) else { return }
        head = Array(json.dropLast()) + Array(",".utf8)
        dir = Array(url.path.utf8) + Array("/".utf8)
        // Its own stack, so a stack overflow on the main thread still reaches the handler.
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: 131_072, alignment: 16),
                            ss_size: 131_072, ss_flags: 0)
        sigaltstack(&stack, nil)
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = onCrashSignal
        action.sa_flags = SA_SIGINFO | SA_ONSTACK
        sigemptyset(&action.sa_mask)
        for s in signals { sigaction(s, &action, nil) }
    }

    static func put(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
        guard len + count < capacity else { return }
        (buf + len).update(from: bytes, count: count)
        len += count
    }
    static func put(_ s: StaticString) { put(s.utf8Start, s.utf8CodeUnitCount) }
    static func put(_ a: [UInt8]) { a.withUnsafeBufferPointer { put($0.baseAddress!, $0.count) } }
    static func byte(_ b: UInt8) { if len < capacity { buf[len] = b; len += 1 } }
    static func hex(_ v: UInt64, digits: Int = 0, upper: Bool = false) {
        var n = 0, x = v
        repeat { n += 1; x >>= 4 } while x != 0
        for i in stride(from: max(n, digits) - 1, through: 0, by: -1) {
            let d = UInt8((v >> (UInt64(i) * 4)) & 0xf)
            byte(d < 10 ? 48 + d : (upper ? 55 : 87) + d)
        }
    }
    static func dec(_ v: Int, digits: Int = 0) {
        var n = 1, p = 1
        while v / p >= 10 { p *= 10; n += 1 }
        for _ in n..<max(n, digits) { byte(48) }
        while p > 0 { byte(UInt8(48 + (v / p) % 10)); p /= 10 }
    }

    static func message(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGSEGV: "EXC_BAD_ACCESS / SIGSEGV"
        case SIGBUS: "EXC_BAD_ACCESS / SIGBUS"
        case SIGILL: "EXC_BAD_INSTRUCTION / SIGILL"
        case SIGFPE: "EXC_ARITHMETIC / SIGFPE"
        case SIGTRAP: "EXC_BREAKPOINT / SIGTRAP"
        default: "EXC_CRASH / SIGABRT"
        }
    }

    /// One frame: the binary's name, the offset into it, and its UUID from LC_UUID.
    static func frame(_ address: UInt, first: Bool) -> Bool {
        var info = Dl_info()
        guard address > 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
              let base = info.dli_fbase, let name = info.dli_fname else { return false }
        if !first { byte(44) }
        put("{\"image\":\"")
        var start = name, p = name
        while p.pointee != 0 { if p.pointee == 47 { start = p + 1 }; p += 1 }
        var q = start
        while q.pointee != 0 && q - start < 200 {
            let c = UInt8(bitPattern: q.pointee)
            if c >= 0x20 && c != 34 && c != 92 { byte(c) }
            q += 1
        }
        put("\",\"offset\":\"0x")
        hex(UInt64(address - UInt(bitPattern: base)))
        byte(34)
        let header = base.assumingMemoryBound(to: mach_header_64.self)
        var cmd = UnsafeRawPointer(base) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_UUID {
                put(",\"debug_id\":\"")
                for i in 0..<16 {
                    if i == 4 || i == 6 || i == 8 || i == 10 { byte(45) }
                    hex(UInt64(cmd.load(fromByteOffset: 8 + i, as: UInt8.self)), digits: 2, upper: true)
                }
                byte(34)
                break
            }
            cmd += Int(lc.cmdsize)
        }
        byte(125)
        return true
    }

    /// Writes `<time>-<hex>.json` with the crashed thread's frames. Called inside the signal handler,
    /// so it uses only buffers made in `install`.
    static func save(_ sig: Int32, _ context: UnsafeMutablePointer<ucontext_t>?) {
        guard installed else { return }
        let now = time(nil)
        len = 0
        put(head)
        put("\"time\":"); dec(now)
        put(",\"message\":\""); put(message(sig)); put("\",\"frames\":[")
        if let mc = context?.pointee.uc_mcontext {
            #if arch(arm64)
            var pc = UInt(mc.pointee.__ss.__pc), fp = UInt(mc.pointee.__ss.__fp)
            #else
            var pc = UInt(mc.pointee.__ss.__rip), fp = UInt(mc.pointee.__ss.__rbp)
            #endif
            let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            let bottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
            var count = 0
            while count < 200 && len < capacity - 1000 {
                if frame(pc & 0x7FFF_FFFF_FFFF, first: count == 0) { count += 1 }   // the mask drops pointer-auth bits
                guard fp >= bottom, fp + 16 <= top, fp % 8 == 0,
                      let p = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = p[0]
                pc = p[1]
                guard next > fp else { break }
                fp = next
            }
        }
        put("]}")
        var n = 0
        for c in dir { path[n] = CChar(bitPattern: c); n += 1 }
        let saved = len   // the file name is built in the buffer after the body
        dec(now, digits: 10); byte(45)
        hex(UInt64(UInt32(truncatingIfNeeded: mach_absolute_time() ^ UInt64(getpid()))), digits: 8)
        put(".json")
        for i in saved..<len { path[n] = CChar(bitPattern: buf[i]); n += 1 }
        path[n] = 0
        len = saved
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        var off = 0
        while off < len {
            let w = write(fd, buf + off, len - off)
            if w <= 0 { break }
            off += w
        }
        close(fd)
    }
}

private func onCrashSignal(_ sig: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    CrashSignals.save(sig, context?.assumingMemoryBound(to: ucontext_t.self))
    _exit(128 + sig)
}
#endif
