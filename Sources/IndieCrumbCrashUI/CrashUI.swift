import Foundation
import IndieCrumbCrash
import IndieCrumbUI

extension ReportCrash {
    /// The newest crash waiting on disk, for "Report a problem"; nil when there is none.
    /// Sent with `send(_:)`, so it carries no install id.
    public static func latest(_ reporter: CrashReporter) -> ReportCrash? {
        guard let report = reporter.pending.last else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let id = report.id
        return ReportCrash(time: Date(timeIntervalSince1970: TimeInterval(report.time)), version: report.version,
                           text: text, send: { reporter.send(id) })
    }
}
