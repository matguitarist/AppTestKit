import AppKit
import Testing
@testable import AppTestKit

@Suite("SnapshotRequest")
struct SnapshotRequestTests {
    @Test("no APP_SNAPSHOT, no run")
    func none() {
        #expect(SnapshotRequest(env: [:]) == nil)
        #expect(SnapshotRequest(env: ["APP_SNAPSHOT": ""]) == nil)
    }

    @Test("every page when APP_SNAPSHOT_PAGES is unset or empty")
    func allPages() throws {
        let request = try #require(SnapshotRequest(env: ["APP_SNAPSHOT": "/tmp/App-shots", "APP_SNAPSHOT_PAGES": ""]))
        #expect(request.pages == nil)
        #expect(request.wants("library") && request.wants("settings"))
        #expect(request.folder.path == "/tmp/App-shots")
        #expect(!request.smallest && request.size == nil)
    }

    @Test("APP_SNAPSHOT_PAGES limits the pages")
    func somePages() throws {
        let request = try #require(SnapshotRequest(env: ["APP_SNAPSHOT": "/tmp/s", "APP_SNAPSHOT_PAGES": "all, settings,,starred"]))
        #expect(request.pages == ["all", "settings", "starred"])
        #expect(request.wants("settings") && !request.wants("log"))
        #expect(request.wantsAny(["log", "starred"]) && !request.wantsAny(["log", "help"]))
    }

    @Test("APP_SNAPSHOT_MIN and APP_SNAPSHOT_SIZE size the main window")
    func sizes() throws {
        let request = try #require(SnapshotRequest(env: ["APP_SNAPSHOT": "/tmp/s", "APP_SNAPSHOT_MIN": "1",
                                                         "APP_SNAPSHOT_SIZE": "1600x1000"]))
        #expect(request.smallest)
        #expect(request.size == CGSize(width: 1600, height: 1000))
        #expect(SnapshotRequest(env: ["APP_SNAPSHOT": "/tmp/s", "APP_SNAPSHOT_MIN": "0"])?.smallest == false)
    }

    @Test("a size is two positive numbers", arguments: ["1600", "axb", "0x100", "-5x10", "10x10x10", ""])
    func badSize(text: String) {
        #expect(SnapshotRequest.size(text) == nil)
    }

    @Test("files are named <name>-light.png and <name>-dark.png")
    func names() {
        let request = SnapshotRequest(folder: URL(fileURLWithPath: "/tmp/s", isDirectory: true))
        #expect(request.url("settings-general", .light).path == "/tmp/s/settings-general-light.png")
        #expect(request.url("library", .dark).path == "/tmp/s/library-dark.png")
        #expect(Appearance.allCases.map(\.rawValue) == ["light", "dark"])
        #expect(Appearance.light.name == .aqua && Appearance.dark.name == .darkAqua)
    }
}

@MainActor
@Suite("SnapshotRun and WindowShot")
struct SnapshotRunTests {
    @Test("no APP_SNAPSHOT, no run and no output")
    func notRequested() {
        var lines: [String] = []
        var quits = 0
        #expect(SnapshotRun.requested(env: ["APP_STORE": "/tmp/x"], output: { lines.append($0) }, quit: { quits += 1 }) == nil)
        #expect(lines.isEmpty && quits == 0)
    }

    @Test("snapshots refuse to run without a test store in /tmp", arguments: [
        ["APP_SNAPSHOT": "/tmp/s"], ["APP_SNAPSHOT": "/tmp/s", "APP_STORE": "/Users/me/library.json"],
    ])
    func refused(env: [String: String]) {
        var lines: [String] = []
        var quits = 0
        #expect(SnapshotRun.requested(env: env, output: { lines.append($0) }, quit: { quits += 1 }) == nil)
        #expect(lines == ["SNAPSHOT refused: set APP_STORE to a file in /tmp"])
        #expect(quits == 1)
    }

    @Test("a run with a test store reads the request, and finish says done and quits")
    func finish() throws {
        var lines: [String] = []
        var quits = 0
        let made = SnapshotRun.requested(env: ["APP_SNAPSHOT": "/tmp/App-shots", "APP_STORE": "/tmp/App-test.json",
                                               "APP_SNAPSHOT_PAGES": "library"],
                                         output: { lines.append($0) }, quit: { quits += 1 })
        let run = try #require(made)
        #expect(run.wants("library") && !run.wants("settings"))
        #expect(run.url("library", .dark).path == "/tmp/App-shots/library-dark.png")
        run.finish()
        #expect(lines == ["SNAPSHOT done /tmp/App-shots"])
        #expect(quits == 1)
    }

    @Test("pages not asked for are skipped without touching a window")
    func skipped() async {
        let run = SnapshotRun(request: SnapshotRequest(folder: URL(fileURLWithPath: "/tmp/s"), pages: ["library"]),
                              output: { _ in }, quit: {})
        var shown: [String] = []
        await run.shootPages(["log", "help"]) { shown.append($0) }
        await run.shoot("library-empty", show: { shown.append("library-empty") })
        await run.shootSettings(tabs: ["general"], open: { shown.append("open") }, select: { shown.append($0) })
        #expect(shown.isEmpty)
    }

    @Test("the layout file sits next to its PNG")
    func layoutURL() {
        #expect(WindowShot.layoutURL(for: URL(fileURLWithPath: "/tmp/s/library-light.png")).path
                == "/tmp/s/library-light-layout.json")
        #expect(WindowShot.layoutURL(for: URL(fileURLWithPath: "/tmp/s/settings-general-dark.png")).path
                == "/tmp/s/settings-general-dark-layout.json")
    }

    @Test("screencapture takes the window by number, or a screen rectangle counted from the top")
    func arguments() {
        #expect(WindowShot.arguments(windowNumber: 42, screenRect: nil, primaryScreenTop: 1000, path: "/tmp/a.png")
                == ["-x", "-o", "-l", "42", "/tmp/a.png"])
        let rect = CGRect(x: 80, y: 200, width: 1080, height: 720)
        #expect(WindowShot.arguments(windowNumber: 42, screenRect: rect, primaryScreenTop: 1117, path: "/tmp/a.png")
                == ["-x", "-R", "80,197,1080,720", "/tmp/a.png"])
    }

    @Test("a window drawn from its views makes a PNG of its size")
    func drawn() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let data = try #require(WindowShot.drawPNG(window))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.size.width >= 320 && image.size.height >= 200)
        let file = FileManager.default.temporaryDirectory.appending(path: "AppTestKit-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        #expect(NSImage(contentsOf: file) != nil)
    }
}
