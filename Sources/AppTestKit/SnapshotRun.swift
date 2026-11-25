import AppKit

/// A snapshot run: the app started with `APP_SNAPSHOT=<folder>` shoots its pages, states and Settings tabs in light
/// and dark, prints one line per PNG, then "SNAPSHOT done <folder>", and quits. An app keeps what it shows and how
/// it gets there; this does the rest.
///
///     guard let run = SnapshotRun.requested(layout: { GridProbes.shared.write(to: $0.path, window: $1) }) else { return }
///     Task {
///         await run.start()
///         await run.shootPages(SidebarItem.allCases.map(\.rawValue)) { model.sidebar = SidebarItem(rawValue: $0)! }
///         await run.shoot("library-empty", show: { model.games = [] }, hide: { model.games = saved })
///         await run.shootSettings(tabs: SettingsTab.allCases.map(\.rawValue), open: { openSettings() },
///                                 select: { model.settingsTab = SettingsTab(rawValue: $0)! })
///         run.finish()
///     }
@MainActor
public final class SnapshotRun {
    /// What was asked for.
    public let request: SnapshotRequest
    /// How long a page gets to draw after it changes, before its capture.
    public var settle: Duration = .seconds(0.8)
    /// Writes the grid probes' file for each PNG: (layout file, window content size). The app's `GridProbes`.
    public var layout: (@MainActor (URL, CGSize) -> Void)?

    private let output: @MainActor (String) -> Void
    private let quit: @MainActor () -> Void
    private var wake: DisplayWake?

    /// A run for `request`. `output` gets each line of the run's own; `quit` ends the app.
    public init(request: SnapshotRequest,
                layout: (@MainActor (URL, CGSize) -> Void)? = nil,
                output: @escaping @MainActor (String) -> Void = { print($0) },
                quit: @escaping @MainActor () -> Void = SnapshotRun.terminateApp) {
        self.request = request
        self.layout = layout
        self.output = output
        self.quit = quit
    }

    /// The run asked for in `env`, or nil when `APP_SNAPSHOT` isn't set. Snapshots never run against real data:
    /// without `APP_STORE` in /tmp, prints "SNAPSHOT refused: <refusal>", quits, and returns nil.
    public static func requested(env: [String: String] = ProcessInfo.processInfo.environment,
                                 refusal: String = "set APP_STORE to a file in /tmp",
                                 layout: (@MainActor (URL, CGSize) -> Void)? = nil,
                                 output: @escaping @MainActor (String) -> Void = { print($0) },
                                 quit: @escaping @MainActor () -> Void = SnapshotRun.terminateApp) -> SnapshotRun? {
        guard let request = SnapshotRequest(env: env) else { return nil }
        guard TestRun.hasTestStore(env: env) else {
            output("SNAPSHOT refused: \(refusal)")
            quit()
            return nil
        }
        return SnapshotRun(request: request, layout: layout, output: output, quit: quit)
    }

    /// True when `page` should be shot (`APP_SNAPSHOT_PAGES`).
    public func wants(_ page: String) -> Bool { request.wants(page) }

    /// True when `name`, or its `group` ("states", "sheets"), should be shot.
    public func wants(_ name: String, in group: String?) -> Bool { request.wants(name, in: group) }

    /// True when any of these should be shot.
    public func wantsAny(_ pages: [String]) -> Bool { request.wantsAny(pages) }

    /// The PNG for `name` in `appearance`.
    public func url(_ name: String, _ appearance: Appearance) -> URL { request.url(name, appearance) }

    /// `<name>.png`, with no look in its name.
    public func url(_ name: String) -> URL { request.url(name) }

    // MARK: Steps

    /// Gets the screen ready: wakes the display and keeps it on, makes the folder, gives the window `wait` to
    /// appear, and activates the app, since a first capture of an inactive window comes out dim. Then sizes the
    /// main window: `mainFrame` first when given (the saved frame is forgotten, so every run starts the same,
    /// whatever size or tiling the person's own window was saved with), then `APP_SNAPSHOT_MIN` (the window clamps
    /// to its content's smallest size) or `APP_SNAPSHOT_SIZE`.
    public func start(wait: Duration = .seconds(1.5), mainFrame: NSRect? = nil) async {
        wake = DisplayWake()
        let folder = request.folder
        await Self.makeFolder(folder)
        NSApp.activate()
        WindowShot.mainWindow()?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: wait)
        guard let main = WindowShot.mainWindow() else { return }
        if let mainFrame {
            main.setFrameAutosaveName("")
            main.setFrame(mainFrame, display: true)
            try? await Task.sleep(for: .seconds(0.5))
        }
        if request.smallest {
            main.setContentSize(NSSize(width: 1, height: 1))
            try? await Task.sleep(for: .seconds(0.5))
        }
        if let size = request.size {
            main.setContentSize(size)
            main.center()
            try? await Task.sleep(for: .seconds(0.5))
        }
    }

    /// Waits `settle`, or `duration` when given.
    public func pause(_ duration: Duration? = nil) async {
        try? await Task.sleep(for: duration ?? settle)
    }

    /// Takes `<name>-<appearance>.png` of `window`, the main window when nil. Prints "SNAPSHOT no window" when
    /// there is none.
    @discardableResult
    public func capture(_ name: String, _ appearance: Appearance, window: NSWindow? = nil,
                        area: WindowShot.Area = .window, fallback: Bool = true) async -> WindowShot.Outcome {
        guard let window = window ?? WindowShot.mainWindow() else {
            output("SNAPSHOT no window")
            return .noWindow
        }
        return await WindowShot.capture(window, to: url(name, appearance), area: area, fallback: fallback, layout: layout)
    }

    /// Takes `<name>.png` of `window`, the main window when nil, in the look the app has now: a shot taken once,
    /// with no -light or -dark in its name (a confirmation over Settings, a printed page). Prints
    /// "SNAPSHOT no window" when there is none.
    @discardableResult
    public func capture(_ name: String, window: NSWindow? = nil, area: WindowShot.Area = .window,
                        fallback: Bool = true) async -> WindowShot.Outcome {
        guard let window = window ?? WindowShot.mainWindow() else {
            output("SNAPSHOT no window")
            return .noWindow
        }
        return await WindowShot.capture(window, to: url(name), area: area, fallback: fallback, layout: layout)
    }

    /// Runs `body` once in light and once in dark, with the look applied first.
    public func forEachAppearance(_ body: @MainActor (Appearance) async -> Void) async {
        for appearance in Appearance.allCases {
            appearance.apply()
            await body(appearance)
        }
    }

    /// Every page asked for, in light then in dark: `select` shows it, then it settles and is shot as
    /// `<page>-<appearance>.png`. `window` picks the window per page (the main one by default).
    /// `group` ("states") shoots them all when it is on `APP_SNAPSHOT_PAGES`, as well as each by its name.
    /// `settle` gives a page its own time to draw (a sheet, a page that loads pictures); nil keeps `settle`.
    public func shootPages(_ pages: [String],
                           in group: String? = nil,
                           window: @MainActor (String) -> NSWindow? = { _ in nil },
                           area: WindowShot.Area = .window,
                           settle: @MainActor (String) -> Duration? = { _ in nil },
                           select: @MainActor (String) async -> Void) async {
        let wanted = pages.filter { wants($0, in: group) }
        guard !wanted.isEmpty else { return }
        await forEachAppearance { appearance in
            for page in wanted {
                await select(page)
                await pause(settle(page))
                await capture(page, appearance, window: window(page), area: area)
            }
        }
    }

    /// One state, when asked for: in each look, `show` sets it up, it settles, it is shot as
    /// `<name>-<appearance>.png`, and `hide` puts things back. For a sheet, `window` returns
    /// `WindowShot.mainWindow()?.attachedSheet`.
    /// `when` is the name `APP_SNAPSHOT_PAGES` asks for when it isn't the file's (`"progress"` for
    /// `apps-progress-light.png`); `group` ("sheets") shoots it when the group is asked for too.
    public func shoot(_ name: String,
                      when key: String? = nil,
                      in group: String? = nil,
                      window: @MainActor () -> NSWindow? = { nil },
                      area: WindowShot.Area = .window,
                      settle: Duration = .seconds(1),
                      show: @MainActor () async -> Void = {},
                      hide: (@MainActor () async -> Void)? = nil) async {
        guard wants(key ?? name, in: group) else { return }
        await forEachAppearance { appearance in
            await show()
            await pause(settle)
            await capture(name, appearance, window: window(), area: area)
            if let hide {
                await hide()
                await pause(.seconds(0.6))
            }
        }
    }

    /// Every Settings tab, when "settings" is asked for: `open` opens the window, then in each look each tab is
    /// chosen with `select` and shot as `settings-<tab>-<appearance>.png`. `window` finds the Settings window;
    /// by default the front titled window that isn't the main one, a sheet or a panel.
    public func shootSettings(tabs: [String],
                              open: @MainActor () -> Void,
                              select: @MainActor (String) async -> Void,
                              window: (@MainActor () -> NSWindow?)? = nil) async {
        guard wants("settings") else { return }
        let main = WindowShot.mainWindow()
        open()
        await pause(.seconds(1))
        await forEachAppearance { appearance in
            for tab in tabs {
                await select(tab)
                await pause()
                let settings = window?() ?? WindowShot.otherWindow(excluding: [main])
                await capture("settings-\(tab)", appearance, window: settings)
            }
        }
    }

    /// Prints "SNAPSHOT done <folder>" and quits.
    public func finish() {
        output("SNAPSHOT done \(request.folder.path)")
        wake = nil
        quit()
    }

    /// Closes sheets, since an open sheet refuses terminate and the run would wait forever, then quits.
    public static func terminateApp() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    @concurrent
    private nonisolated static func makeFolder(_ folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
