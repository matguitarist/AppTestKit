import AppKit
import Testing
@testable import AppTestKit

@Suite("Screen areas hold only this app's windows")
struct ScreenAreaTests {
    func info(_ number: Int, pid: Int32, _ frame: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: number), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary, kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    @Test("other apps' windows and this app's windows behind are left out; back to front")
    func pieces() {
        let area = CGRect(x: 100, y: 100, width: 800, height: 600)
        let list = [
            info(1, pid: 99, CGRect(x: 0, y: 0, width: 2000, height: 2000)),    // a terminal over everything
            info(2, pid: 7, CGRect(x: 300, y: 50, width: 200, height: 120)),    // a popover reaching past the top
            info(3, pid: 7, CGRect(x: 2000, y: 2000, width: 50, height: 50)),   // a window elsewhere
            info(4, pid: 7, CGRect(x: 300, y: 150, width: 400, height: 300), alpha: 0),
            info(5, pid: 7, CGRect(x: 250, y: 100, width: 500, height: 300)),   // the sheet
            info(6, pid: 7, area),                                              // the window
            info(8, pid: 7, CGRect(x: 120, y: 120, width: 400, height: 400)),   // Settings, behind
        ]
        let pieces = WindowShot.pieces(target: 6, area: area, pid: 7, windows: list)
        #expect(pieces.map(\.number) == [6, 5, 2])
        #expect(WindowShot.pieces(target: 42, area: area, pid: 7, windows: list).isEmpty)
        // A helper window AppKit keeps for a sheet isn't one of the app's NSWindows; a menu is kept all the same.
        var menu = info(9, pid: 7, CGRect(x: 400, y: 300, width: 150, height: 200))
        menu[kCGWindowLayer as String] = NSNumber(value: 101)
        #expect(WindowShot.pieces(target: 6, area: area, pid: 7, windows: [menu] + list, known: [6, 2]).map(\.number) == [6, 2, 9])
    }

    @Test("pieces are drawn at their place, the front one on top, clear where no window is")
    func compose() throws {
        func solid(_ red: UInt8, _ width: Int, _ height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let area = CGRect(x: 10, y: 10, width: 100, height: 50)
        let data = try #require(WindowShot.compose([(solid(100, 160, 80), CGRect(x: 10, y: 10, width: 80, height: 40)),
                                                    (solid(250, 40, 20), CGRect(x: 20, y: 10, width: 20, height: 10))],
                                                   area: area, scale: 2))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 200 && image.pixelsHigh == 100)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var values = [Int](repeating: 0, count: image.samplesPerPixel)
            image.getPixel(&values, atX: x, y: y)
            return values
        }
        func red(_ x: Int, _ y: Int) -> Int { pixel(x, y)[0] }
        func alpha(_ x: Int, _ y: Int) -> Int { pixel(x, y).last ?? -1 }
        #expect(red(30, 5) > 240)        // the front piece, top left (rows count down from the top)
        #expect(abs(red(100, 50) - 100) < 20)
        #expect(alpha(190, 90) == 0)     // no window there
    }

    @Test("screencapture through ProcessKit says false when it wrote nothing")
    func failedCapture() {
        let url = URL(fileURLWithPath: "/nonexistent-AppTestKit/\(UUID()).png")
        #expect(!WindowShot.screencapture(["-x", "-l", "0", url.path], writing: url))
    }

    @Test("a window taken with its popover covers their union; alone, its frame")
    func coverage() {
        let window = CGRect(x: 200, y: 432, width: 600, height: 428)
        let group = window.union(CGRect(x: 127, y: 513, width: 286, height: 146))
        #expect(WindowShot.coverage(width: 1346, height: 856, scale: 2, candidates: [window, group]) == group)
        #expect(WindowShot.coverage(width: 1200, height: 856, scale: 2, candidates: [window, group]) == window)
        #expect(WindowShot.coverage(width: 500, height: 500, scale: 2, candidates: [window, group]) == nil)
    }

    @Test("an AppKit frame is counted from the top of the main screen")
    func topLeft() {
        #expect(WindowShot.topLeft(CGRect(x: 80, y: 200, width: 1080, height: 720), primaryScreenTop: 1117)
                == CGRect(x: 80, y: 197, width: 1080, height: 720))
    }
}
