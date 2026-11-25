import Foundation
import Testing
@testable import AppTestKit

@Suite("TestRun")
struct TestRunTests {
    @Test("a file in /tmp or /private/tmp is a test store", arguments: [
        "/tmp/RenChan-self.json", "/private/tmp/BenchLog-self.sqlite", "/tmp/a/b/c.store", "/tmp/./x.json",
    ])
    func inTemporaryFolder(path: String) {
        #expect(TestRun.isInTemporaryFolder(path))
    }

    @Test("anything else is refused", arguments: [
        "", "/tmp", "/tmp/", "/private/tmp", "/tmpfoo/x.json", "/tmp/../Users/me/library.json",
        "/Users/me/Library/Application Support/RenChan/library.json", "/var/tmp/x.json", "tmp/x.json",
    ])
    func outsideTemporaryFolder(path: String) {
        #expect(!TestRun.isInTemporaryFolder(path))
    }

    @Test("the system's own temporary folder isn't /tmp")
    func temporaryDirectory() {
        let file = FileManager.default.temporaryDirectory.appending(path: "AppTestKit-\(UUID()).json")
        #expect(!TestRun.isInTemporaryFolder(file.path))
    }

    @Test("a link in /tmp that leads out of it is refused")
    func linkOutside() {
        // No file is made in /tmp: the links are pretend ones.
        let toHome: (URL) -> URL = { $0.path.hasPrefix("/tmp/link/") ? URL(fileURLWithPath: "/Users/me/library.json") : $0 }
        #expect(!TestRun.isInTemporaryFolder("/tmp/link/library.json", resolve: toHome))
        #expect(TestRun.isInTemporaryFolder("/tmp/other/library.json", resolve: toHome))
        // /tmp itself is a link to /private/tmp: both are inside.
        let toPrivate: (URL) -> URL = { URL(fileURLWithPath: "/private" + $0.path) }
        #expect(TestRun.isInTemporaryFolder("/tmp/App-self.json", resolve: toPrivate))
    }

    @Test("a link in the test's own temporary folder is followed")
    func realLink() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AppTestKit-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(!TestRun.isInTemporaryFolder(link.appending(path: "x.json").path))
    }

    @Test("no APP_STORE is a normal run")
    func normalRun() throws {
        #expect(try TestRun.storeURL(env: [:]) == nil)
        #expect(try TestRun.storeURL(env: ["APP_STORE": ""]) == nil)
        #expect(!TestRun.isTestRun(env: [:]))
        #expect(!TestRun.isTestRun(env: ["APP_STORE": ""]))
        #expect(!TestRun.hasTestStore(env: [:]))
    }

    @Test("APP_STORE in /tmp is the store")
    func testStore() throws {
        let env = ["APP_STORE": "/tmp/Hangar-self.json"]
        #expect(try TestRun.storeURL(env: env) == URL(fileURLWithPath: "/tmp/Hangar-self.json"))
        #expect(TestRun.isTestRun(env: env))
        #expect(TestRun.hasTestStore(env: env))
    }

    @Test("APP_STORE outside /tmp throws, and says where it pointed")
    func refused() {
        let env = ["APP_STORE": "/Users/me/library.json"]
        #expect(throws: TestRun.Refusal.outsideTemporaryFolder("/Users/me/library.json")) {
            try TestRun.storeURL(env: env)
        }
        #expect(TestRun.Refusal.outsideTemporaryFolder("/x").description == "APP_STORE must be a file in /tmp, not /x")
        // Still a test run, so app code that only asks "is this a test?" keeps real data out of reach.
        #expect(TestRun.isTestRun(env: env))
        #expect(!TestRun.hasTestStore(env: env))
    }

    @Test("seed data needs APP_SEED=1 and a test store")
    func seeded() {
        #expect(TestRun.isSeeded(env: ["APP_STORE": "/tmp/x.json", "APP_SEED": "1"]))
        #expect(!TestRun.isSeeded(env: ["APP_STORE": "/tmp/x.json", "APP_SEED": "0"]))
        #expect(!TestRun.isSeeded(env: ["APP_SEED": "1"]))
    }
}
