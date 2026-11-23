import Foundation
import ImageIO
import IndieCrumbCore
import UniformTypeIdentifiers

public enum FeedbackKind: String, Sendable { case bug, idea, question }

public enum FeedbackError: Error, Equatable {
    case emptyText, textTooLong, badEmail, badScreenshot
}

extension IndieCrumb {
    static let feedbackRoute = "/ic/v1/feedback"

    /// Sends one item the user submitted. It waits on disk when offline and goes with the next `flush()`.
    /// - Parameters:
    ///   - text: 1 to 4,000 characters.
    ///   - email: only when the user typed it, to get a reply.
    ///   - screenshot: any image ImageIO reads; it is scaled to fit 2,000 x 2,000 pixels and 300 KB first.
    ///   - pro: the paid tier, so the dashboard marks the item "Pro".
    public func sendFeedback(kind: FeedbackKind, text: String, email: String? = nil, screenshot: Data? = nil,
                             pro: Bool = false) async throws -> Delivery {
        let body = try feedbackBody(kind: kind, text: text, email: email, screenshot: screenshot, pro: pro)
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                done.resume(returning: self.enqueueAndFlush(route: Self.feedbackRoute, body: body, install: true))
            }
        }
    }

    /// The exact body `sendFeedback` posts; IndieCrumbUI shows it in "What gets sent".
    package func feedbackBody(kind: FeedbackKind, text: String, email: String?, screenshot: Data?, pro: Bool) throws -> Data {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FeedbackError.emptyText }
        guard text.count <= 4000 else { throw FeedbackError.textTooLong }
        var body: [String: Any] = [
            "kind": kind.rawValue, "text": text, "version": version, "build": build,
            "os": Platform.osLabel, "device": Platform.model, "pro": pro,
        ]
        if let e = email?.trimmingCharacters(in: .whitespaces), !e.isEmpty {
            let parts = e.split(separator: "@", omittingEmptySubsequences: false)
            guard e.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
                  !e.contains(where: \.isWhitespace) else { throw FeedbackError.badEmail }
            body["email"] = e
        }
        if let s = screenshot {
            guard let fit = fitScreenshot(s) else { throw FeedbackError.badScreenshot }
            body["screenshot"] = fit.base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// Returns a PNG or JPEG of at most 300 KB and 2,000 pixels a side: the input as it is when it already
/// fits, else a JPEG at falling quality and size. Nil when ImageIO can't read it.
package func fitScreenshot(_ data: Data, maxBytes: Int = 300 << 10, maxSide: Int = 2000) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let type = CGImageSourceGetType(src) as String?
    if data.count <= maxBytes, max(w, h) <= maxSide, w > 0, h > 0,
       type == UTType.png.identifier || type == UTType.jpeg.identifier {
        return data
    }
    var side = min(max(w, h), maxSide)
    while side >= 200 {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        for q in [0.8, 0.6, 0.4] {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            if CGImageDestinationFinalize(dst), out.length <= maxBytes { return out as Data }
        }
        side = side * 2 / 3
    }
    return nil
}
