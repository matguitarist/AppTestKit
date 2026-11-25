import AppKit
import ImageIO
import Testing
@testable import AppTestKit

@Suite("Snapshot groups, keys and once-only shots")
struct SnapshotGroupTests {
    let folder = URL(fileURLWithPath: "/tmp/s", isDirectory: true)

    @Test("a group on the list shoots every page in it; a name still shoots alone")
    func groups() {
        let request = SnapshotRequest(folder: folder, pages: ["states", "repair-billing"])
        #expect(request.wants("parts-low", in: "states"))
        #expect(request.wants("repair-billing", in: "sheets"))
        #expect(!request.wants("part-edit-sheet", in: "sheets"))
        #expect(!request.wants("parts-low", in: nil))
        #expect(SnapshotRequest(folder: folder).wants("anything", in: "sheets"))
    }

    @Test("a shot taken once is <name>.png")
    func onceName() {
        let request = SnapshotRequest(folder: folder)
        #expect(request.url("settings-sync-server-stop").path == "/tmp/s/settings-sync-server-stop.png")
    }
}

@MainActor
@Suite("SnapshotRun groups, keys and settle", .serialized)
struct SnapshotRunGroupTests {
    @Test("shoot(_:when:) asks the list for its key, not its file name")
    func key() async {
        _ = NSApplication.shared
        let run = SnapshotRun(request: SnapshotRequest(folder: URL(fileURLWithPath: "/tmp/s"), pages: ["apps-progress"]),
                              output: { _ in }, quit: {})
        var shown: [String] = []
        await run.shoot("apps-progress", when: "progress", show: { shown.append("progress") })
        await run.shoot("setup-summary", in: "sheets", show: { shown.append("setup") })
        #expect(shown.isEmpty)
    }

    @Test("shootPages takes a group and a settle time per page")
    func pagesInGroup() async {
        _ = NSApplication.shared
        var lines: [String] = []
        let run = SnapshotRun(request: SnapshotRequest(folder: FileManager.default.temporaryDirectory
                                  .appending(path: "AppTestKit-\(UUID())"), pages: ["states"]),
                              output: { lines.append($0) }, quit: {})
        var shown: [String] = []
        var settled: [String] = []
        let saved = WindowShot.output
        WindowShot.output = { lines.append($0) }
        defer { WindowShot.output = saved }
        await run.shootPages(["parts-low", "parts-restock"], in: "states",
                             window: { _ in nil }, settle: { settled.append($0); return .zero }) { shown.append($0) }
        await run.shootPages(["log"]) { shown.append($0) }
        #expect(shown == ["parts-low", "parts-restock", "parts-low", "parts-restock"])
        #expect(settled == shown)
        #expect(lines.count == 4)
    }

    @Test("capture without a look writes <name>.png, or says there is no window")
    func captureOnce() async {
        _ = NSApplication.shared
        var lines: [String] = []
        let run = SnapshotRun(request: SnapshotRequest(folder: URL(fileURLWithPath: "/tmp/s")), output: { lines.append($0) }, quit: {})
        #expect(run.url("board-print").path == "/tmp/s/board-print.png")
        if WindowShot.mainWindow() == nil {
            #expect(await run.capture("board-print") == .noWindow)
            #expect(lines == ["SNAPSHOT no window"])
        }
    }
}
