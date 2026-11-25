# AppTestKit

How my Mac apps test themselves: the `APP_STORE` guard that keeps test runs in /tmp, the self-test's checks and
summary line, and the snapshot run that shoots every page in light and dark. Shared by RenChan, BenchLog, Hangar,
Kamiro, SMLauncherPlus, AM2RLauncherPlus, UnbloatMyMac, Porthole and Outpost, and the next ones.
tools/selftest.sh and tools/snap.sh in every app read what it prints, so keep the lines exactly as they are, and keep
the API stable and additive.

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/AppTestKit/` macOS only (AppKit):
  - `TestRun`: `APP_STORE` and `APP_SEED`; `store(env:)` exits when the store is outside /tmp.
  - `SelfTest`: `check`, `skip`, `refuse`, `finish`, `run`, `wait`; a shared run behind static methods.
  - `SnapshotRequest`: `APP_SNAPSHOT`, `APP_SNAPSHOT_PAGES`, `APP_SNAPSHOT_MIN`, `APP_SNAPSHOT_SIZE`.
  - `SnapshotRun`: start, pages, states, Settings tabs, finish.
  - `WindowShot`: one window to one PNG with screencapture (through ProcessKit), or drawn when Screen Recording is
    off; a screen area holds only the app's own windows.
  - `Appearance`, `DisplayWake`.
- `Tests/AppTestKitTests/` Swift Testing. Nothing is written outside the system's temporary folder; /tmp paths in
  tests are only strings.

## Rules

- The lines are an interface: "PASS name", "FAIL name: detail", "SKIP what", "SELFTEST PASS n checks",
  "SELFTEST FAIL f of n checks", "SELFTEST refused: reason", "SNAPSHOT <path>", "SNAPSHOT <path> (fallback: …)",
  "SNAPSHOT failed <path>", "SNAPSHOT no window", "SNAPSHOT refused: reason", "SNAPSHOT done <folder>".
  A test covers each one.
- Nothing app-specific: no pages, no models, no grid probes. An app passes closures.
- Swift 6 strict concurrency, no warnings. The UI types are `@MainActor`; screencapture and file writes run off
  the main thread (`@concurrent`), except `WindowShot.captureNow`, which says it blocks.
- Quit through `NSApp.terminate` after closing sheets, never `exit()`, except `TestRun.store` before anything
  is opened and `SelfTest.exitIfRequested` in `applicationWillTerminate`.
- Add a test for every change. `swift build && swift test` pass with no warnings, then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.
