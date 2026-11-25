import AppKit

/// The self-test an app runs on itself with `--selftest`: one line per check, a summary line, and an exit code.
/// tools/selftest.sh reads the exit code; people and agents read the lines:
///
///     PASS the library opens
///     FAIL a game is added: 0 games
///     SKIP the real download: set APP_SELFTEST_INSTALL=1
///     SELFTEST FAIL 1 of 42 checks
///
/// An app keeps its own checks in `extension SelfTest { static func runIfRequested(model:) }` and calls the
/// static `check`, which reports to `SelfTest.shared`.
@MainActor
public final class SelfTest {
    /// The run an app's checks report to.
    public static let shared = SelfTest()

    /// True when the app was started with `--selftest`.
    public static var requested: Bool { requested(arguments: CommandLine.arguments) }

    /// True when these arguments ask for the self-test.
    public nonisolated static func requested(arguments: [String]) -> Bool {
        arguments.contains("--selftest")
    }

    /// Checks so far.
    public private(set) var count = 0
    /// Checks that failed so far.
    public private(set) var failures = 0
    /// 0 when every check passed, 1 otherwise. Set by `finish`.
    public private(set) var exitCode: Int32 = 0
    /// True once `finish` ran: later calls do nothing.
    public private(set) var isFinished = false

    private let output: @MainActor (String) -> Void
    private let quit: @MainActor (Int32) -> Void

    /// `output` gets each line; `quit` ends the run with the exit code. Tests pass their own; apps use the defaults,
    /// which print to stdout and quit through `NSApp.terminate`.
    public init(output: @escaping @MainActor (String) -> Void = SelfTest.printLine,
                quit: @escaping @MainActor (Int32) -> Void = SelfTest.terminateApp) {
        self.output = output
        self.quit = quit
    }

    // MARK: Checks

    /// Records one check: "PASS name", or "FAIL name: detail". Returns `ok`.
    @discardableResult
    public func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        count += 1
        if ok {
            output("PASS \(name)")
        } else {
            failures += 1
            let detail = detail()
            output("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return ok
    }

    /// Waits up to `timeout` for `condition`, then records it as a check. For state that settles a moment later.
    @discardableResult
    public func check(_ name: String, within timeout: Duration, _ condition: @MainActor () -> Bool,
                      detail: @MainActor () -> String = { "" }) async -> Bool {
        let ok = await Self.wait(upTo: timeout, until: condition)
        return check(name, ok, ok ? "" : detail())
    }

    /// Says a part of the test didn't run, and why: "SKIP what". Not a check.
    public func skip(_ what: String) {
        output("SKIP \(what)")
    }

    /// Prints the summary, "SELFTEST PASS n checks" or "SELFTEST FAIL f of n checks", and quits with 0 or 1.
    public func finish() {
        guard !isFinished else { return }
        output(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
        end(code: failures == 0 ? 0 : 1)
    }

    /// Quits with `code` and no summary: a run that can't go on.
    public func finish(code: Int32) {
        guard !isFinished else { return }
        end(code: code)
    }

    /// Refuses to run: "SELFTEST refused: reason", then quits with 1.
    public func refuse(_ reason: String) {
        guard !isFinished else { return }
        output("SELFTEST refused: \(reason)")
        end(code: 1)
    }

    private func end(code: Int32) {
        isFinished = true
        exitCode = code
        quit(code)
    }

    // MARK: Running

    /// Runs `body` when the app was started with `--selftest`, then prints the summary and quits.
    /// Refuses (exit 1) unless `APP_STORE` is a file in /tmp and `allowed` holds, an app's own extra condition
    /// (a sample tree in place, a pretend backend). Lines print at once, so a crash keeps the lines before it.
    /// Returns the task, or nil when the self-test wasn't asked for or was refused.
    @discardableResult
    public func run(refusal: String = "set APP_STORE to a file in /tmp",
                    allowed: Bool = true,
                    arguments: [String] = CommandLine.arguments,
                    env: [String: String] = ProcessInfo.processInfo.environment,
                    _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard Self.requested(arguments: arguments) else { return nil }
        Self.printLinesAtOnce()
        guard TestRun.hasTestStore(env: env), allowed else {
            refuse(refusal)
            return nil
        }
        return Task { @MainActor in
            await body()
            finish()
        }
    }

    // MARK: The shared run

    /// `check` on the shared run.
    @discardableResult
    public static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        shared.check(name, ok, detail())
    }

    /// `check(_:within:_:detail:)` on the shared run.
    @discardableResult
    public static func check(_ name: String, within timeout: Duration, _ condition: @MainActor () -> Bool,
                             detail: @MainActor () -> String = { "" }) async -> Bool {
        await shared.check(name, within: timeout, condition, detail: detail)
    }

    /// `skip` on the shared run.
    public static func skip(_ what: String) { shared.skip(what) }

    /// `finish()` on the shared run.
    public static func finish() { shared.finish() }

    /// `finish(code:)` on the shared run.
    public static func finish(code: Int32) { shared.finish(code: code) }

    /// `refuse` on the shared run.
    public static func refuse(_ reason: String) { shared.refuse(reason) }

    /// `run` on the shared run.
    @discardableResult
    public static func run(refusal: String = "set APP_STORE to a file in /tmp", allowed: Bool = true,
                           _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        shared.run(refusal: refusal, allowed: allowed, body)
    }

    /// The shared run's exit code. Read it in `applicationWillTerminate`, or call `exitIfRequested()`.
    public static var exitCode: Int32 { shared.exitCode }

    /// For `applicationWillTerminate`, after the app's own work (flushing its log): in a self-test run, exits with
    /// the result, since a normal quit would exit with 0 whatever failed.
    public static func exitIfRequested() {
        if requested { exit(shared.exitCode) }
    }

    // MARK: Helpers

    /// Waits until `condition` holds, checking every `interval`, for at most `timeout`. Returns whether it held.
    public static func wait(upTo timeout: Duration = .seconds(5), every interval: Duration = .milliseconds(100),
                            until condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    /// Prints a line to stdout.
    public static func printLine(_ line: String) {
        print(line)
    }

    /// Closes sheets, since an open sheet refuses terminate and the run would wait forever, then quits through
    /// `NSApp.terminate`, never `exit()`, so the app saves and flushes as usual.
    public static func terminateApp(_ code: Int32) {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    /// Makes stdout line-buffered, so every line reaches the script at once, the app's own prints included.
    public nonisolated static func printLinesAtOnce() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}
