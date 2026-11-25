import Foundation
import Testing
@testable import AppTestKit

/// A self-test that writes its lines to an array and records its exit instead of quitting.
@MainActor
final class Recorder {
    var lines: [String] = []
    var exits: [Int32] = []
    lazy var test = SelfTest(output: { [unowned self] in self.lines.append($0) },
                             quit: { [unowned self] in self.exits.append($0) })
}

@MainActor
@Suite("SelfTest")
struct SelfTestTests {
    let testStore = ["APP_STORE": "/tmp/App-self.json"]

    @Test("a check prints PASS or FAIL with its detail")
    func checkLines() {
        let recorder = Recorder()
        #expect(recorder.test.check("the library opens", true))
        #expect(!recorder.test.check("a game is added", false, "0 games"))
        recorder.test.check("the log has the line", false)
        recorder.test.check("no detail on a pass", true, "ignored")
        #expect(recorder.lines == ["PASS the library opens", "FAIL a game is added: 0 games",
                                   "FAIL the log has the line", "PASS no detail on a pass"])
        #expect(recorder.test.count == 4)
        #expect(recorder.test.failures == 2)
    }

    @Test("a passing check doesn't build its detail")
    func lazyDetail() {
        let recorder = Recorder()
        var built = false
        func detail() -> String { built = true; return "x" }
        recorder.test.check("passes", true, detail())
        #expect(!built)
        recorder.test.check("fails", false, detail())
        #expect(built)
    }

    @Test("finish prints SELFTEST PASS and exits with 0 when every check passed")
    func finishPass() {
        let recorder = Recorder()
        recorder.test.check("one", true)
        recorder.test.check("two", true)
        recorder.test.finish()
        #expect(recorder.lines.last == "SELFTEST PASS 2 checks")
        #expect(recorder.exits == [0])
        #expect(recorder.test.exitCode == 0)
        #expect(recorder.test.isFinished)
    }

    @Test("finish prints SELFTEST FAIL and exits with 1 when a check failed")
    func finishFail() {
        let recorder = Recorder()
        recorder.test.check("one", true)
        recorder.test.check("two", false, "why")
        recorder.test.check("three", false)
        recorder.test.finish()
        #expect(recorder.lines.last == "SELFTEST FAIL 2 of 3 checks")
        #expect(recorder.exits == [1])
        #expect(recorder.test.exitCode == 1)
    }

    @Test("finish runs once")
    func finishOnce() {
        let recorder = Recorder()
        recorder.test.check("one", false)
        recorder.test.finish(code: 1)
        recorder.test.finish()
        recorder.test.refuse("late")
        #expect(recorder.exits == [1])
        #expect(!recorder.lines.contains { $0.hasPrefix("SELFTEST") })
    }

    @Test("skip says what didn't run, and isn't a check")
    func skip() {
        let recorder = Recorder()
        recorder.test.skip("the real download: set APP_SELFTEST_INSTALL=1")
        recorder.test.finish()
        #expect(recorder.lines == ["SKIP the real download: set APP_SELFTEST_INSTALL=1", "SELFTEST PASS 0 checks"])
    }

    @Test("refuse prints the reason and exits with 1")
    func refuse() {
        let recorder = Recorder()
        recorder.test.refuse("set APP_STORE to a file in /tmp")
        #expect(recorder.lines == ["SELFTEST refused: set APP_STORE to a file in /tmp"])
        #expect(recorder.exits == [1])
    }

    @Test("run does nothing without --selftest")
    func notRequested() {
        let recorder = Recorder()
        let task = recorder.test.run(arguments: ["App"], env: testStore) { recorder.test.check("never", true) }
        #expect(task == nil)
        #expect(recorder.lines.isEmpty && recorder.exits.isEmpty)
    }

    @Test("run refuses without a test store in /tmp", arguments: [[String: String](), ["APP_STORE": "/Users/me/x.json"]])
    func refusedStore(env: [String: String]) {
        let recorder = Recorder()
        var ran = false
        let task = recorder.test.run(arguments: ["App", "--selftest"], env: env) { ran = true }
        #expect(task == nil && !ran)
        #expect(recorder.lines == ["SELFTEST refused: set APP_STORE to a file in /tmp"])
        #expect(recorder.exits == [1])
    }

    @Test("run refuses when the app's own condition doesn't hold")
    func refusedCondition() {
        let recorder = Recorder()
        let task = recorder.test.run(refusal: "run tools/seed-tree.sh first", allowed: false,
                                     arguments: ["App", "--selftest"], env: testStore) {}
        #expect(task == nil)
        #expect(recorder.lines == ["SELFTEST refused: run tools/seed-tree.sh first"])
        #expect(recorder.exits == [1])
    }

    @Test("run runs the checks, then the summary and the exit")
    func runs() async {
        let recorder = Recorder()
        let task = recorder.test.run(arguments: ["App", "--selftest"], env: testStore) {
            recorder.test.check("before a pause", true)
            try? await Task.sleep(for: .milliseconds(10))
            recorder.test.check("after a pause", false, "late")
        }
        await task?.value
        #expect(recorder.lines == ["PASS before a pause", "FAIL after a pause: late", "SELFTEST FAIL 1 of 2 checks"])
        #expect(recorder.exits == [1])
    }

    @Test("a run that stops early keeps its own exit code")
    func stopsEarly() async {
        let recorder = Recorder()
        let task = recorder.test.run(arguments: ["--selftest"], env: testStore) {
            recorder.test.check("the catalog has the tweaks the test uses", false)
            recorder.test.finish(code: 1)
        }
        await task?.value
        #expect(recorder.lines == ["FAIL the catalog has the tweaks the test uses"])
        #expect(recorder.exits == [1])
    }

    @Test("--selftest anywhere in the arguments asks for the self-test")
    func requested() {
        #expect(SelfTest.requested(arguments: ["App", "-AppleLanguages", "(fr)", "--selftest"]))
        #expect(!SelfTest.requested(arguments: ["App", "--selftests"]))
    }

    @Test("wait returns when the condition holds, or false after the timeout")
    func wait() async {
        var ticks = 0
        let held = await SelfTest.wait(upTo: .seconds(2), every: .milliseconds(5)) { ticks += 1; return ticks >= 3 }
        #expect(held && ticks == 3)
        let never = await SelfTest.wait(upTo: .milliseconds(30), every: .milliseconds(5)) { false }
        #expect(!never)
    }

    @Test("check within waits for state that settles later")
    func checkWithin() async {
        let recorder = Recorder()
        let start = ContinuousClock.now
        await recorder.test.check("settles", within: .seconds(2)) { ContinuousClock.now - start > .milliseconds(20) }
        await recorder.test.check("never settles", within: .milliseconds(20), { false }, detail: { "still loading" })
        #expect(recorder.lines == ["PASS settles", "FAIL never settles: still loading"])
    }
}

/// The way an app writes its checks, in an extension calling the shared run. Compiled, never run: the shared run
/// prints to stdout and quits the app.
extension SelfTest {
    static func exampleChecks(count: Int) {
        run(refusal: "set APP_STORE to a file in /tmp so the test never touches the real library") {
            check("the library opens", count > 0, "\(count) games")
            await check("the games load", within: .seconds(1)) { count > 0 }
            skip("the real download: set APP_SELFTEST_INSTALL=1")
            if count > 100 { finish(code: 1) }
        }
    }
}
