import Foundation

/// A test run: the app started with `APP_STORE` pointing at a store in /tmp, so a self-test, snapshots or seed data
/// never touch the person's real data. An app reads its store path here instead of reading `APP_STORE` itself.
public enum TestRun {
    /// The variable that names the test store.
    public static let storeKey = "APP_STORE"
    /// The variable that asks for sample data (`APP_SEED=1`).
    public static let seedKey = "APP_SEED"
    /// The folders a test store may live in.
    public static let allowedFolders = ["/tmp/", "/private/tmp/"]

    /// Why a store path was refused.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// `APP_STORE` names a path outside /tmp.
        case outsideTemporaryFolder(String)

        public var description: String {
            switch self {
            case .outsideTemporaryFolder(let path): "APP_STORE must be a file in /tmp, not \(path)"
            }
        }
    }

    /// True when `APP_STORE` is set, whatever its value. Apps use it where they wrote `Store.isOverridden`:
    /// keep secrets in memory, skip notifications, don't save settings.
    public static func isTestRun(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(env[storeKey] ?? "").isEmpty
    }

    /// True in a test run that asked for sample data: `APP_SEED=1` with `APP_STORE` set.
    public static func isSeeded(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env[seedKey] == "1" && isTestRun(env: env)
    }

    /// True when `path` is a file inside /tmp or /private/tmp, after `..` and symbolic links are followed.
    /// "/tmp" itself, "/tmpfoo/x" and "/tmp/../Users/x" are not.
    public static func isInTemporaryFolder(_ path: String) -> Bool {
        isInTemporaryFolder(path, resolve: { $0.resolvingSymlinksInPath() })
    }

    /// `isInTemporaryFolder` with the way links are followed given, for tests.
    static func isInTemporaryFolder(_ path: String, resolve: (URL) -> URL) -> Bool {
        guard !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // The path as written and where it leads must both be inside: a link in /tmp can point anywhere.
        return [url.path, resolve(url).path].allSatisfy { candidate in
            allowedFolders.contains { candidate.hasPrefix($0) && candidate.count > $0.count }
        }
    }

    /// The test store, or nil in a normal run (no `APP_STORE`). Throws when `APP_STORE` points outside /tmp.
    public static func storeURL(env: [String: String] = ProcessInfo.processInfo.environment) throws(Refusal) -> URL? {
        guard let path = env[storeKey], !path.isEmpty else { return nil }
        guard isInTemporaryFolder(path) else { throw .outsideTemporaryFolder(path) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// The test store, or nil in a normal run. When `APP_STORE` points outside /tmp, says so on stderr and exits
    /// with 1 before anything is read or written: call it where the app decides where its data lives.
    public static func store(env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        do {
            return try storeURL(env: env)
        } catch {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            exit(1)
        }
    }

    /// True when the run may use a test store: `APP_STORE` is set and inside /tmp.
    public static func hasTestStore(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (try? storeURL(env: env)) != nil
    }
}
