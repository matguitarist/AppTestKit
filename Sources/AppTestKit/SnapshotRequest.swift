import Foundation

/// What a snapshot run was asked for, read from the environment:
///
/// - `APP_SNAPSHOT=<folder>` where the PNGs go; without it there is no snapshot run.
/// - `APP_SNAPSHOT_PAGES=library,settings` only these pages and states; all of them when unset or empty.
/// - `APP_SNAPSHOT_MIN=1` the main window at its smallest size first.
/// - `APP_SNAPSHOT_SIZE=1600x1000` the main window's content at that size first.
public struct SnapshotRequest: Sendable, Equatable {
    public static let folderKey = "APP_SNAPSHOT"
    public static let pagesKey = "APP_SNAPSHOT_PAGES"
    public static let smallestKey = "APP_SNAPSHOT_MIN"
    public static let sizeKey = "APP_SNAPSHOT_SIZE"

    /// Where the PNGs and layout files go.
    public var folder: URL
    /// The pages and states asked for, or nil for all of them.
    public var pages: Set<String>?
    /// Shrink the main window to its smallest size first.
    public var smallest: Bool
    /// The main window's content size to shoot at, if asked.
    public var size: CGSize?

    public init(folder: URL, pages: Set<String>? = nil, smallest: Bool = false, size: CGSize? = nil) {
        self.folder = folder
        self.pages = pages
        self.smallest = smallest
        self.size = size
    }

    /// The request in `env`, or nil when `APP_SNAPSHOT` isn't set.
    public init?(env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let folder = env[Self.folderKey], !folder.isEmpty else { return nil }
        self.folder = URL(fileURLWithPath: folder, isDirectory: true)
        self.pages = Self.pages(env[Self.pagesKey])
        self.smallest = !(env[Self.smallestKey] ?? "").isEmpty && env[Self.smallestKey] != "0"
        self.size = env[Self.sizeKey].flatMap(Self.size)
    }

    /// True when `page` should be shot: no list was given, or it is on the list.
    public func wants(_ page: String) -> Bool {
        pages?.contains(page) ?? true
    }

    /// True when `name` should be shot because it, or its `group` ("states", "sheets"), is on the list, or there is
    /// no list. A group name shoots every page in it without naming each one.
    public func wants(_ name: String, in group: String?) -> Bool {
        guard let group, let pages else { return wants(name) }
        return pages.contains(name) || pages.contains(group)
    }

    /// True when any of these pages should be shot.
    public func wantsAny(_ pages: [String]) -> Bool {
        pages.contains(where: wants)
    }

    /// `<folder>/<name>-light.png` or `-dark.png`.
    public func url(_ name: String, _ appearance: Appearance) -> URL {
        folder.appending(path: "\(name)-\(appearance.rawValue).png")
    }

    /// `<folder>/<name>.png`: one PNG with no look in its name, for a shot taken once.
    public func url(_ name: String) -> URL {
        folder.appending(path: "\(name).png")
    }

    /// "a,b, c" as a set; nil when empty, which means every page.
    public static func pages(_ text: String?) -> Set<String>? {
        let names = (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : Set(names)
    }

    /// "1600x1000" as a size; nil when it isn't two positive numbers.
    public static func size(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}
