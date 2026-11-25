# AppTestKit

How my Mac apps test themselves. It gathers what each app copied on its own: the `APP_STORE` guard that keeps test
runs away from real data, the self-test's PASS and FAIL lines and its exit code, and the snapshot run that shoots
every page and Settings tab in light and dark with screencapture.

- **TestRun**: the test store from `APP_STORE`, refused outside /tmp; seed data with `APP_SEED=1`.
- **SelfTest**: `check`, `skip`, `finish`; the summary line tools/selftest.sh and people read, and exit 0 or 1.
- **SnapshotRun**: `APP_SNAPSHOT` and its options, pages, states, Settings tabs, "SNAPSHOT done".
- **WindowShot**: one window to one PNG, drawn from its views when Screen Recording is off.

macOS 14 or later. AppKit only.

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/AppTestKit", from: "0.1.0"),
// in the app target:
.product(name: "AppTestKit", package: "AppTestKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  AppTestKit:
    url: https://github.com/matguitarist/AppTestKit
    from: 0.1.0
targets:
  App:
    dependencies:
      - package: AppTestKit
```

## The test store

```swift
import AppTestKit

enum Store {
    /// True in tests, snapshots and the self-test: keep secrets in memory, send no notifications.
    static var isOverridden: Bool { TestRun.isTestRun() }

    /// APP_STORE in /tmp, or the real library. Exits with 1 when APP_STORE points anywhere else.
    static var url: URL { TestRun.store() ?? folder.appending(path: "library.json") }
}

if TestRun.isSeeded() { SeedData.fill(model) }   // APP_SEED=1 with APP_STORE set
```

A store counts as in /tmp when it is a file inside /tmp or /private/tmp, after `..` and links are followed.

## The self-test

`--selftest` runs it. Checks print as they go, a summary closes the run, and the app quits through
`NSApp.terminate` with 0 or 1:

```
PASS the library opens
FAIL a game is added: 0 games
SKIP the real download: set APP_SELFTEST_INSTALL=1
SELFTEST FAIL 1 of 42 checks
```

The app keeps its checks in an extension; `check` reports to the shared run:

```swift
import AppTestKit

extension SelfTest {
    static func runIfRequested(model: AppModel) {
        run(refusal: "set APP_STORE to a file in /tmp so the test never touches the real library") {
            check("the library opens", model.library != nil, model.libraryError ?? "")
            await check("the sample containers load", within: .seconds(5)) { model.containers.count == 7 }
            await moreChecks(model)
        }   // then "SELFTEST PASS n checks" and quit
    }
}

// AppDelegate, after the app's own work:
func applicationWillTerminate(_ notification: Notification) {
    Store.log.flushFile()
    SelfTest.exitIfRequested()
}
```

- `run(refusal:allowed:)` refuses ("SELFTEST refused: …", exit 1) unless `APP_STORE` is in /tmp and `allowed`
  holds, the app's own condition: a sample tree in place, a pretend backend.
- `finish(code: 1)` stops a run that can't go on, with no summary.
- `SelfTest.wait(upTo:until:)` waits for state that settles later.
- In a unit test, make your own `SelfTest(output:quit:)` and read the lines and the exit code.

## Snapshots

`APP_SNAPSHOT=<folder>` shoots `<page>-light.png` and `<page>-dark.png`, each with its grid probes'
`<page>-<look>-layout.json`, then prints "SNAPSHOT done <folder>" and quits. `APP_SNAPSHOT_PAGES=library,settings`
limits the pages, `APP_SNAPSHOT_MIN=1` shrinks the main window to its smallest size first, `APP_SNAPSHOT_SIZE=1600x1000`
sizes it.

```swift
import AppTestKit

enum Snapshot {
    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        // Refuses ("SNAPSHOT refused: …") and quits without APP_STORE in /tmp.
        guard let run = SnapshotRun.requested(layout: { GridProbes.shared.write(to: $0.path, window: $1) }) else { return }
        Task {
            await run.start()   // wakes the display, waits for the window, applies APP_SNAPSHOT_MIN or _SIZE
            await run.shootPages(SidebarItem.allCases.map(\.rawValue)) { model.sidebar = SidebarItem(rawValue: $0)! }
            await run.shoot("library-empty", show: { model.games = [] }, hide: { model.games = saved })
            await run.shoot("launch-error", window: { WindowShot.mainWindow()?.attachedSheet },
                            show: { model.launchError = sample }, hide: { model.launchError = nil })
            await run.shootSettings(tabs: SettingsTab.allCases.map(\.rawValue), open: { openSettings() },
                                    select: { model.settingsTab = SettingsTab(rawValue: $0)! })
            run.finish()
        }
    }
}
```

- `run.start(mainFrame:)` puts the main window at a fixed frame first and forgets its saved one, so every run starts
  the same whatever the person's own window was.
- `run.forEachAppearance { look in … }` and `run.capture(name, look, window:, area:)` for anything the helpers don't
  cover: a window of its own, a tall page, a panel.
- `area: .screen` takes the window's area of the screen, so an alert sheet or a popover over it shows; `.automatic`
  does that only when a sheet or popover is open.
- `WindowShot.captureNow` blocks the main thread, for a menu shot from a timer while it is open.

Captures need Screen Recording permission for the app that started this one (the terminal, or Claude). Without it, the
window is drawn from its views and the line says "(fallback: no Screen Recording permission, sidebars and glass are
blank)".

## License

MIT
