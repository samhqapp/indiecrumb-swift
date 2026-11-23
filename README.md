# IndieCrumb (Swift)

The IndieCrumb client for Mac apps: in-app feedback, a daily usage ping, and crash reports.
macOS 14+, MIT licensed, no dependencies beyond the system frameworks. Small on purpose, so you can
read all of it before you ship it.

## One product per module

| Product | What it adds | Frameworks |
|---|---|---|
| `IndieCrumbCore` | `IndieCrumb`: transport, ingest key, install id, on/off switch, offline queue | Foundation |
| `IndieCrumbFeedback` | `sendFeedback(kind:text:email:screenshot:pro:)` | ImageIO |
| `IndieCrumbUsage` | `Usage`: `recordUse()`, `add(_:_:)`, `start(pro:)`, `pingIfDue(pro:)` | Foundation |
| `IndieCrumbCrash` | `CrashReporter`: `start()`, `pending`, `send(_:)`, `discard(_:)`, `sendAll()` | MetricKit |
| `IndieCrumbUI` | `ReportProblemView` sheet, `PrivacySection` (Settings), `PrivacyAboutLine` (About) | SwiftUI |
| `IndieCrumbCrashUI` | `ReportCrash.latest(reporter)`: offers the last crash in the sheet | SwiftUI, MetricKit |

Link only the products you use; the others never enter your binary. Check:
`Samples/FeedbackOnly` links only `IndieCrumbFeedback`; its release binary has no `IndieCrumbUsage`
or `IndieCrumbCrash` symbol and does not load MetricKit.

## Use

```swift
import IndieCrumbCore
import IndieCrumbFeedback
import IndieCrumbUsage

let ic = IndieCrumb(endpoint: URL(string: "https://crumb.samhq.app")!,
                    key: "ic_pub_...",                         // public, ships in the app, can only submit
                    enabled: Settings.shareReports)            // the Settings switch
let usage = Usage(ic)
usage.start(pro: { License.isPro })                            // at launch: pings when due, checks hourly
usage.recordUse()
try await ic.sendFeedback(kind: .bug, text: text, screenshot: png)
ic.isEnabled = false                                           // turned off: queue, crashes, counts deleted
```

Version and build default to `CFBundleShortVersionString` and `CFBundleVersion`. Data lives in
`Application Support/<bundle id>/IndieCrumb` unless you pass `directory`.

Crash reports: create one `CrashReporter(ic)` and call `start()` early at launch. macOS delivers the
last run's crash through MetricKit in the next run; the reporter writes it to disk. Then either ask
the user (`pending`, `send(id)`, `discard(id)`) or call `sendAll()` off the main thread.

UI: `IndieCrumbUI` never links MetricKit; add `IndieCrumbCrashUI` only when the app reports crashes.

```swift
.sheet(isPresented: $reporting) {
    ReportProblemView(model: ReportProblemModel(core: ic, pro: License.isPro,
                                                crash: .latest(crashReporter)),   // IndieCrumbCrashUI
                      layout: .form) { reporting = false }
}
Form { ...; PrivacySection(isOn: $shareReports, shares: [.usage, .crash], appName: "Task Manager Pro") }
```

The sheet shows the exact JSON in "What gets sent" and the exact crash report text. Nothing in the UI
opens by itself after a crash. With the switch off, Send is disabled and a note says why.

## When anything is sent

| What | When |
|---|---|
| Usage ping | at most once per UTC day: at `start` and then on its hourly check. A failed ping keeps its counts for the next try and is never queued. |
| Feedback | only when the user submits it. Offline, it waits in the queue and goes with the next `flush()`. |
| Crash report | never from the crashing process. MetricKit hands it over at the next launch; it is written to disk and sent only by `send(_:)` or `sendAll()`. |

Queue: one file per request in `<directory>/queue/`, at most 10 files, 1 MB and 7 days (oldest goes first).
Crash files: `<directory>/crashes/`, at most 10, deleted after 7 days.
Backoff: `429`, `5xx` and network errors wait `Retry-After` or 1 minute doubling to 6 hours. `410`
(key revoked) stops all sends for 7 days. Any other `4xx` deletes the item.

Off switch: `enabled: false` or `isEnabled = false` sends nothing and deletes the queue, the crash
files and the usage counts. Only `state.json` (the install id and the backoff time) stays.

## Every field sent

Headers on every request: `Content-Type: application/json`, `X-IC-Key: <ingest key>`.
`X-IC-Install: <32 hex>`: a random id made on the device (not from hardware, user or account), renewed
every 90 days. It is sent with the ping, feedback and `sendAll()` crash reports, never with a crash
report the user sent with `send(_:)`. The server keeps it in memory only, for per-install limits, and
never stores it. The default transport is an ephemeral `URLSession`: no cookies, no cache.

Nothing sends an IP address on purpose (the server sees the connection's address and keeps it in
memory only), a hostname, a user name, or a file path. Crash text has the home folder and
`/Users/<name>` parts replaced with `~`.

### `POST /ic/v1/ping` (`IndieCrumbUsage`), at most 2 KB

| Field | Value |
|---|---|
| `version` | the app version, digits and dots (`1.4.2`) |
| `build` | the build number, digits only; checked, not stored |
| `os` | `macos` |
| `os_major` | the macOS major version (`15`) |
| `arch` | `arm64` or `x86_64` |
| `d` | `1`: the first ping of a UTC day (one ping a day) |
| `m` | `1` on the first ping of a UTC month, else `0` |
| `uses` | uses counted with `recordUse()` since the last ping, capped at 1023 |
| `pro` | the paid tier, `true` or `false` |
| `counters` | `{name: n}` from `add(_:_:)` since the last ping, at most 16 names; the server drops names the project did not define |

The server stores only daily totals per app, version, OS and arch.

### `POST /ic/v1/feedback` (`IndieCrumbFeedback`)

| Field | Value |
|---|---|
| `kind` | `bug`, `idea` or `question` |
| `text` | what the user typed, 1 to 4,000 characters |
| `email` | only when the user typed one |
| `screenshot` | only when the user attached one: base64 PNG or JPEG, at most 300 KB and 2,000 x 2,000 pixels (larger images are scaled down to a JPEG first, which also drops their metadata) |
| `version`, `build` | as above |
| `os` | such as `macOS 15.1` |
| `device` | the Mac model id, such as `Mac15,3` |
| `pro` | the paid tier |

### `POST /ic/v1/crash` (`IndieCrumbCrash`)

The server route is not built yet; this is the planned shape (at most 64 KB, 200 frames, strings
at most 256 characters).

| Field | Value |
|---|---|
| `kind` | `crash` |
| `message` | exception and signal names plus the termination or exception reason, home paths replaced with `~` |
| `file`, `line` | empty and `0` (for Rust panics only) |
| `time` | Unix seconds of the crash |
| `version`, `build` | the crashed run's version and build, from MetricKit |
| `os`, `os_major`, `arch` | as in the ping |
| `frames` | up to 200 `{image, offset, debug_id}` of the crashed thread: the binary's name only, the hex offset into its text segment, and its UUID |

## Tests

```sh
swift test
IC_E2E_URL=http://127.0.0.1:18480 IC_KEY=ic_pub_... EDGE_SECRET=... swift test --filter E2ETests
```
