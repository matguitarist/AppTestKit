import AppKit

/// Takes a PNG of one of the app's windows with screencapture, so glass, sidebars and materials look exactly as on
/// screen. That needs Screen Recording permission for the app that started this one (the terminal, or Claude).
/// Without it, draws the view hierarchy instead, which leaves sidebars and glass blank, and says so.
///
/// Each capture prints one line tools/snap.sh and people read: "SNAPSHOT <path>", "SNAPSHOT <path> (fallback: …)",
/// "SNAPSHOT failed <path>" or "SNAPSHOT no window".
@MainActor
public enum WindowShot {
    /// What part of the screen a capture takes.
    public enum Area: Sendable, Equatable {
        /// The window alone, without its shadow.
        case window
        /// The window's area of the screen, popovers reaching past its edge included: shows an attached sheet,
        /// an alert or a menu over it.
        case screen
        /// `.screen` when a sheet is attached or a popover is open, `.window` otherwise.
        case automatic
    }

    /// How a capture went.
    public enum Outcome: Sendable, Equatable {
        /// screencapture took the window.
        case captured
        /// Drawn from the view hierarchy: no Screen Recording permission. Sidebars and glass are blank.
        case drawn
        /// Nothing was written.
        case failed
        /// There was no window to take.
        case noWindow
    }

    /// Where each line goes. stdout unless a test changes it.
    public static var output: @MainActor (String) -> Void = { print($0) }

    /// The line printed when a capture falls back to drawing.
    public static let fallbackNote = "(fallback: no Screen Recording permission, sidebars and glass are blank)"

    /// The app's main window: the first that can become main and isn't a sheet.
    public static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
    }

    /// The front visible window other than `excluded`: titled, not a sheet, not a panel (a menu bar icon has a panel
    /// of its own). Settings, a log window, a second window. `where` narrows it further.
    public static func otherWindow(excluding excluded: [NSWindow?] = [mainWindow()],
                                   where matches: (NSWindow) -> Bool = { _ in true }) -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && !window.isSheet && window.styleMask.contains(.titled) && !(window is NSPanel)
                && !excluded.contains { $0 === window } && matches(window)
        }
    }

    /// The grid probes' file next to a PNG: `page-light.png` → `page-light-layout.json`.
    public nonisolated static func layoutURL(for png: URL) -> URL {
        png.deletingLastPathComponent().appending(path: png.deletingPathExtension().lastPathComponent + "-layout.json")
    }

    /// Takes `window` to the PNG at `url`. Activates the app and brings the window to the front first, so it looks
    /// like a window someone is using: real accent colors and focus rings. `layout` writes the grid probes' file
    /// (`layoutURL(for:)`) with the window's content size, before the capture. screencapture runs off the main
    /// thread, three times at most, since the first capture of a run sometimes misses the window.
    @discardableResult
    public static func capture(_ window: NSWindow, to url: URL, area: Area = .window, fallback: Bool = true,
                               layout: (@MainActor (URL, CGSize) -> Void)? = nil) async -> Outcome {
        let arguments = prepare(window, to: url, area: area, layout: layout)
        for attempt in 1...3 {
            if await Self.screencapture(arguments, writing: url) {
                output("SNAPSHOT \(url.path)")
                return .captured
            }
            if attempt < 3 { try? await Task.sleep(for: .seconds(0.5)) }
        }
        return await drawInstead(window, to: url, fallback: fallback)
    }

    /// `capture` without leaving the main thread, for a moment that can't wait: a menu open in its own tracking loop
    /// shot from a timer. Blocks while screencapture runs.
    @discardableResult
    public static func captureNow(_ window: NSWindow, to url: URL, area: Area = .window, fallback: Bool = true,
                                  layout: (@MainActor (URL, CGSize) -> Void)? = nil) -> Outcome {
        let arguments = prepare(window, to: url, area: area, layout: layout)
        for attempt in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = arguments
            if (try? shot.run()) != nil { shot.waitUntilExit() }
            if FileManager.default.fileExists(atPath: url.path) {
                output("SNAPSHOT \(url.path)")
                return .captured
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
        }
        guard fallback, let data = drawPNG(window), (try? data.write(to: url)) != nil else {
            output("SNAPSHOT failed \(url.path)")
            return .failed
        }
        output("SNAPSHOT \(url.path) \(fallbackNote)")
        return .drawn
    }

    /// The window drawn from its views, as PNG data. Sidebars and glass come out blank.
    public static func drawPNG(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// screencapture's arguments: the window by number, or a screen rectangle.
    public nonisolated static func arguments(windowNumber: Int, screenRect: CGRect?, primaryScreenTop: CGFloat,
                                             path: String) -> [String] {
        guard let rect = screenRect else { return ["-x", "-o", "-l", String(windowNumber), path] }
        return ["-x", "-R", rectangle(rect, primaryScreenTop: primaryScreenTop), path]
    }

    /// "x,y,w,h" for screencapture -R: AppKit counts y up from the bottom of the main screen, screencapture down
    /// from its top.
    public nonisolated static func rectangle(_ frame: CGRect, primaryScreenTop: CGFloat) -> String {
        "\(Int(frame.minX)),\(Int(primaryScreenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    }

    // MARK: Private

    /// Shows the window, writes the layout file, removes an older PNG, and returns screencapture's arguments.
    private static func prepare(_ window: NSWindow, to url: URL, area: Area,
                                layout: (@MainActor (URL, CGSize) -> Void)?) -> [String] {
        // Another app can hide this one while snapshots run (computer use hides apps it doesn't control).
        // A hidden window can't be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        layout?(layoutURL(for: url), window.contentView?.bounds.size ?? .zero)
        try? FileManager.default.removeItem(at: url)
        return arguments(windowNumber: window.windowNumber, screenRect: screenRect(of: window, area: area),
                         primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0, path: url.path)
    }

    private static func screenRect(of window: NSWindow, area: Area) -> CGRect? {
        let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        switch area {
        case .window: return nil
        case .automatic where window.attachedSheet == nil && popovers.isEmpty: return nil
        case .screen, .automatic:
            guard !NSScreen.screens.isEmpty else { return nil }
            // Popovers can reach past the window's edge: take them in too.
            return popovers.reduce(window.frame) { $0.union($1.frame) }
        }
    }

    private static func drawInstead(_ window: NSWindow, to url: URL, fallback: Bool) async -> Outcome {
        guard fallback, let data = drawPNG(window), await write(data, to: url) else {
            output("SNAPSHOT failed \(url.path)")
            return .failed
        }
        output("SNAPSHOT \(url.path) \(fallbackNote)")
        return .drawn
    }

    /// Runs screencapture off the main thread; true when the file is there afterwards.
    @concurrent
    private nonisolated static func screencapture(_ arguments: [String], writing url: URL) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = arguments
            shot.terminationHandler = { _ in done.resume() }
            do { try shot.run() } catch { done.resume() }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent
    private nonisolated static func write(_ data: Data, to url: URL) async -> Bool {
        (try? data.write(to: url)) != nil
    }
}
