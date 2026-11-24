# indiecrumb-swift

The IndieCrumb client for Mac and iPhone apps: in-app feedback, a daily usage ping, and crash reports.
Swift package, macOS 14+ and iOS 17+, MIT, public repo. No dependencies beyond system frameworks.

```text
Package.swift   one product per module, so an app links only what it uses
Sources/        IndieCrumbCore, IndieCrumbFeedback, IndieCrumbUsage, IndieCrumbCrash,
                IndieCrumbUI (SwiftUI sheet and Settings row), IndieCrumbCrashUI (after-crash prompt)
Tests/          IndieCrumbTests, with Fixtures/
Samples/FeedbackOnly   links only IndieCrumbFeedback; proves the other modules stay out of the binary
```

## Build and test

```sh
swift build
swift test
```

## Rules

- Keep modules separate. `IndieCrumbUI` must never link MetricKit; crash UI lives in
  `IndieCrumbCrashUI`. The feedback-only sample's release binary must hold no usage or crash symbol
  and must not load MetricKit.
- The library sends nothing by itself. Every request starts from a call the app makes.
- Setting `isEnabled = false` deletes the queue, crash files and counts.
- Crashes: MetricKit delivers the last run's crash at the next launch; on macOS the reporter also
  catches fatal signals. The user is asked before a crash is sent.
- Releases are git tags (`vX.Y.Z`), one per release. Apps depend on a tag.
- Public repo: no keys, no private paths, no private project names. The ingest key in examples is a
  placeholder.
