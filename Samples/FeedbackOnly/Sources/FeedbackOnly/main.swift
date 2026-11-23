import Foundation
import IndieCrumbCore
import IndieCrumbFeedback

let core = IndieCrumb(endpoint: URL(string: "https://crumb.samhq.app")!, key: "ic_pub_sample",
                      enabled: CommandLine.arguments.contains("--send"),
                      directory: FileManager.default.temporaryDirectory.appendingPathComponent("indiecrumb-sample"))
print(try await core.sendFeedback(kind: .idea, text: "sample"))
