import AppKit
import ImageIO
import ProcessKit
import UniformTypeIdentifiers

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
        /// an alert, a popover or a menu over it. Only this app's windows: the window is taken with what is attached
        /// to it and a menu over it is added, so a terminal or another app's window over this one stays out, and so
        /// do this app's windows behind it. Where no window is, the PNG is clear.
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
        let plan = prepare(window, to: url, area: area, layout: layout)
        for attempt in 1...3 {
            if await Self.shoot(plan, to: url) {
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
        let plan = prepare(window, to: url, area: area, layout: layout)
        for attempt in 1...3 {
            if Self.shootNow(plan, to: url) {
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

    /// Shows the window, writes the layout file, removes an older PNG, and says how to take it.
    private static func prepare(_ window: NSWindow, to url: URL, area: Area,
                                layout: (@MainActor (URL, CGSize) -> Void)?) -> Plan {
        // Another app can hide this one while snapshots run (computer use hides apps it doesn't control).
        // A hidden window can't be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        layout?(layoutURL(for: url), window.contentView?.bounds.size ?? .zero)
        try? FileManager.default.removeItem(at: url)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = screenRect(of: window, area: area)
        return Plan(window: window.windowNumber,
                    arguments: arguments(windowNumber: window.windowNumber, screenRect: rect, primaryScreenTop: top, path: url.path),
                    area: rect.map { topLeft($0, primaryScreenTop: top) },
                    known: Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)),
                    scale: window.backingScaleFactor)
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

    // MARK: Screen areas

    /// One of the app's windows in a screen area: its number and frame, counted from the top of the main screen.
    public struct Piece: Sendable, Equatable {
        public var number: Int
        public var frame: CGRect

        public init(number: Int, frame: CGRect) {
            self.number = number
            self.frame = frame
        }
    }

    /// How long one screencapture may take before it is stopped and tried again.
    public nonisolated static let screencaptureTimeout: Duration = .seconds(10)

    /// The windows a screen-area shot is made of, back to front: `target` and this app's windows in front of it
    /// that reach into `area` (its sheet, a popover, an alert, a menu). `windows` is the window server's list,
    /// front to back, as `CGWindowListCopyWindowInfo` gives it. Other apps' windows and this app's windows behind
    /// `target` are left out. `known` is the numbers of the app's own visible `NSWindow`s: a window of the app's
    /// that isn't one of them is left out too (AppKit's helper windows, such as the one a sheet animates in), unless
    /// it is a menu (menus aren't `NSWindow`s). Nil takes every window of the app's. Empty when `target` isn't on
    /// screen.
    public nonisolated static func pieces(target: Int, area: CGRect, pid: pid_t, windows: [[String: Any]],
                                          known: Set<Int>? = nil) -> [Piece] {
        var front: [Piece] = []
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if number == target { return [Piece(number: number, frame: frame)] + front.reversed() }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let ours = known.map { $0.contains(number) || layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) } ?? true
            if ours, alpha > 0, frame.width > 1, frame.height > 1, frame.intersects(area) {
                front.append(Piece(number: number, frame: frame))
            }
        }
        return []
    }

    /// Draws `images`, back to front, each at its frame, into one PNG of `area` (frames and area counted from the
    /// top of the main screen). `scale` is pixels per point; nothing else shows where no window is.
    public nonisolated static func compose(_ images: [(image: CGImage, frame: CGRect)], area: CGRect,
                                           scale: CGFloat) -> Data? {
        let width = Int((area.width * scale).rounded()), height = Int((area.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        for (image, frame) in images {
            // The context counts y up from the bottom; the frames count it down from the top.
            context.draw(image, in: CGRect(x: (frame.minX - area.minX) * scale, y: (area.maxY - frame.maxY) * scale,
                                           width: frame.width * scale, height: frame.height * scale))
        }
        guard let composed = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// AppKit's frame counted from the top of the main screen, as the window server counts.
    nonisolated static func topLeft(_ frame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenTop - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The window to take, screencapture's arguments for it, and the screen area when one is taken instead.
    struct Plan: Sendable {
        var window: Int
        var arguments: [String]
        var area: CGRect?
        var known: Set<Int>
        var scale: CGFloat
    }

    /// Takes `plan` on a thread of its own, never the main one or one of Swift's, since screencapture can take
    /// seconds; true when the PNG is there afterwards.
    private nonisolated static func shoot(_ plan: Plan, to url: URL) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread { done.resume(returning: shootNow(plan, to: url)) }
        }
    }

    /// Takes `plan` on this thread. A screen area is made of this app's windows only, each taken alone and put
    /// together, so another app's window over this one stays out; when that can't be done, the area is taken
    /// as the screen shows it.
    private nonisolated static func shootNow(_ plan: Plan, to url: URL) -> Bool {
        guard let area = plan.area else { return screencapture(plan.arguments, writing: url) }
        if let data = composeArea(area, target: plan.window, known: plan.known, scale: plan.scale), (try? data.write(to: url)) != nil { return true }
        return screencapture(plan.arguments, writing: url)
    }

    /// The screen area of this app's windows only. screencapture `-l` takes a window with the windows attached to
    /// it (its sheet, its popovers) and nothing of other apps', so the target window is taken that way and placed
    /// where its group is; a menu over it, a window of its own, is taken alone and drawn on top. Nil when the target
    /// window can't be taken (no Screen Recording permission) or isn't on screen.
    private nonisolated static func composeArea(_ area: CGRect, target: Int, known: Set<Int>, scale: CGFloat) -> Data? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let pieces = pieces(target: target, area: area, pid: getpid(), windows: list, known: known)
        guard let first = pieces.first else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "AppTestKit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = pieces.map(\.frame).reduce(first.frame) { $0.union($1) }
        var images: [(image: CGImage, frame: CGRect)] = []
        for piece in pieces {
            // A window of the target's group is already in the target's picture.
            if piece.number != target, known.contains(piece.number), images.contains(where: { $0.frame.contains(piece.frame) }) {
                continue
            }
            let file = folder.appending(path: "\(piece.number).png")
            guard screencapture(["-x", "-o", "-l", String(piece.number), file.path], writing: file),
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let frame = coverage(width: image.width, height: image.height, scale: scale,
                                       candidates: [piece.frame, group, first.frame.union(piece.frame)]) else {
                if piece.number == target { return nil }
                continue
            }
            images.append((image, frame))
        }
        let whole = images.map(\.frame).reduce(area) { $0.union($1) }
        return compose(images, area: whole, scale: scale)
    }

    /// Which of `candidates` a picture of `width` by `height` pixels covers at `scale` pixels per point: a window
    /// taken alone covers its frame, one taken with its sheet or popovers covers their union. Nil when none fits.
    public nonisolated static func coverage(width: Int, height: Int, scale: CGFloat, candidates: [CGRect]) -> CGRect? {
        candidates.first { abs($0.width * scale - CGFloat(width)) <= 2 && abs($0.height * scale - CGFloat(height)) <= 2 }
    }

    /// Runs screencapture through ProcessKit, stopped past `screencaptureTimeout`; true when the file is there
    /// afterwards.
    nonisolated static func screencapture(_ arguments: [String], writing url: URL) -> Bool {
        _ = try? Shell.runSync("/usr/sbin/screencapture", arguments, timeout: screencaptureTimeout)
        return FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent
    private nonisolated static func write(_ data: Data, to url: URL) async -> Bool {
        (try? data.write(to: url)) != nil
    }
}
