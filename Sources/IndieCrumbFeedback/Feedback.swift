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
                done.resume(returning: self.enqueueAndFlush(route: Self.feedbackRoute, body: body, install: true, userSent: true))
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

/// Returns a PNG or JPEG of at most 300 KB and 2,000 pixels a side, always freshly encoded from the
/// pixels with no properties copied, so no EXIF, GPS or TIFF metadata (such as the location) leaves the
/// device. A PNG stays PNG when it fits, else a JPEG at falling quality and size. Nil when ImageIO can't read it.
package func fitScreenshot(_ data: Data, maxBytes: Int = 300 << 10, maxSide: Int = 2000) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    guard w > 0, h > 0 else { return nil }
    let png = (CGImageSourceGetType(src) as String?) == UTType.png.identifier
    func encode(_ img: CGImage, _ type: UTType, _ opts: [CFString: Any]) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        let bytes = type == .jpeg ? dropJPEGMetadata(out as Data) : out as Data
        return bytes.count <= maxBytes ? bytes : nil
    }
    var side = min(max(w, h), maxSide)
    repeat {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if png, let out = encode(img, .png, [:]) { return out }
        for q in [0.8, 0.6, 0.4] {
            if let out = encode(img, .jpeg, [kCGImageDestinationLossyCompressionQuality: q]) { return out }
        }
        side = side * 2 / 3
    } while side >= 200
    return nil
}

/// Removes the APP1 (Exif, XMP) and APP13 (IPTC) segments that the JPEG encoder writes by itself.
func dropJPEGMetadata(_ d: Data) -> Data {
    let b = [UInt8](d)
    guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return d }
    var out: [UInt8] = [0xFF, 0xD8], i = 2
    while i + 4 <= b.count, b[i] == 0xFF {
        let marker = b[i + 1]
        if marker == 0xDA { break }   // start of scan: the rest is image data
        let end = i + 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        guard end <= b.count else { return d }
        if marker != 0xE1, marker != 0xED { out += b[i..<end] }
        i = end
    }
    return Data(out + b[i...])
}
