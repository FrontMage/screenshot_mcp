import CoreGraphics
import Foundation
import ImageIO
import CoreServices

struct DisplayInfo: Codable {
    let id: UInt32
    let uuid: String?
    let bounds: Rect
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double?
    let isMain: Bool
}

struct WindowInfo: Codable {
    let windowId: Int
    let ownerName: String?
    let ownerPid: Int?
    let title: String?
    let bounds: Rect?
    let layer: Int?
    let isOnScreen: Bool?
    let alpha: Double?
    let displayId: UInt32?
}

struct Rect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

@main
struct ScreenshotMcpCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        switch command {
        case "list-displays":
            let displays = try listDisplays()
            try writeJSON(displays)
        case "list-windows":
            let windows = try listWindows()
            try writeJSON(windows)
        case "screenshot-display":
            guard args.count >= 3 else { printUsageAndExit() }
            let displayId = try parseUInt32(args[1], name: "display_id")
            let outputPath = args[2]
            try screenshotDisplay(displayId: displayId, outputPath: outputPath)
        case "screenshot-window":
            guard args.count >= 3 else { printUsageAndExit() }
            let windowId = try parseUInt32(args[1], name: "window_id")
            let outputPath = args[2]
            try screenshotWindow(windowId: windowId, outputPath: outputPath)
        default:
            printUsage()
            exit(1)
        }
    }
}

private func printUsage() {
    print(
        """
        Usage:
          screenshot_mcp list-displays
          screenshot_mcp list-windows
          screenshot_mcp screenshot-display <display_id> <output_path>
          screenshot_mcp screenshot-window <window_id> <output_path>
        """
    )
}

private func printUsageAndExit() -> Never {
    printUsage()
    exit(1)
}

private func listDisplays() throws -> [DisplayInfo] {
    var displayCount: UInt32 = 0
    var result = CGGetActiveDisplayList(0, nil, &displayCount)
    guard result == .success else {
        throw CLIError("CGGetActiveDisplayList failed: \(result)")
    }

    var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
    result = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
    guard result == .success else {
        throw CLIError("CGGetActiveDisplayList (second call) failed: \(result)")
    }

    return displays.map { displayId in
        let bounds = CGDisplayBounds(displayId)
        let pixelWidth = Int(CGDisplayPixelsWide(displayId))
        let pixelHeight = Int(CGDisplayPixelsHigh(displayId))
        let scale = bounds.width > 0 ? Double(pixelWidth) / Double(bounds.width) : nil
        return DisplayInfo(
            id: displayId,
            uuid: nil,
            bounds: Rect(
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y),
                width: Double(bounds.size.width),
                height: Double(bounds.size.height)
            ),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale,
            isMain: CGDisplayIsMain(displayId) != 0
        )
    }
}

private func listWindows() throws -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        throw CLIError("CGWindowListCopyWindowInfo returned empty")
    }

    let displays = try listDisplays()
    return windowInfoList.map { info in
        let windowId = info[kCGWindowNumber as String] as? Int
        let ownerName = info[kCGWindowOwnerName as String] as? String
        let ownerPid = info[kCGWindowOwnerPID as String] as? Int
        let title = info[kCGWindowName as String] as? String
        let layer = info[kCGWindowLayer as String] as? Int
        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool
        let alpha = info[kCGWindowAlpha as String] as? Double

        var boundsRect: Rect?
        if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
           let x = boundsDict["X"] as? Double,
           let y = boundsDict["Y"] as? Double,
           let width = boundsDict["Width"] as? Double,
           let height = boundsDict["Height"] as? Double {
            boundsRect = Rect(x: x, y: y, width: width, height: height)
        }

        let displayId: UInt32?
        if let boundsRect = boundsRect {
            displayId = displayForWindow(bounds: boundsRect, displays: displays)
        } else {
            displayId = nil
        }

        return WindowInfo(
            windowId: windowId ?? -1,
            ownerName: ownerName,
            ownerPid: ownerPid,
            title: title,
            bounds: boundsRect,
            layer: layer,
            isOnScreen: isOnScreen,
            alpha: alpha,
            displayId: displayId
        )
    }
}

private func displayForWindow(bounds: Rect, displays: [DisplayInfo]) -> UInt32? {
    let windowRect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    var bestDisplay: UInt32?
    var bestArea: CGFloat = 0

    for display in displays {
        let displayRect = CGRect(
            x: display.bounds.x,
            y: display.bounds.y,
            width: display.bounds.width,
            height: display.bounds.height
        )
        let intersection = windowRect.intersection(displayRect)
        if intersection.isNull { continue }
        let area = intersection.width * intersection.height
        if area > bestArea {
            bestArea = area
            bestDisplay = display.id
        }
    }

    return bestDisplay
}

private func screenshotDisplay(displayId: UInt32, outputPath: String) throws {
    guard let image = CGDisplayCreateImage(displayId) else {
        throw CLIError("Unable to capture display \(displayId)")
    }
    try writeImage(image: image, outputPath: outputPath)
}

private func screenshotWindow(windowId: UInt32, outputPath: String) throws {
    let image = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowId,
        [.bestResolution]
    )
    guard let cgImage = image else {
        throw CLIError("Unable to capture window \(windowId)")
    }
    try writeImage(image: cgImage, outputPath: outputPath)
}

private func writeImage(image: CGImage, outputPath: String) throws {
    let url = URL(fileURLWithPath: outputPath)
    let dirUrl = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)

    let uti = outputUTI(for: url)
    let emptyProperties: CFDictionary? = nil
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, emptyProperties) else {
        throw CLIError("Unable to create image destination at \(outputPath)")
    }
    CGImageDestinationAddImage(destination, image, emptyProperties)
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError("Failed to write image to \(outputPath)")
    }
}

private func outputUTI(for url: URL) -> CFString {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "jpg", "jpeg":
        return kUTTypeJPEG
    case "heic":
        return kUTTypeJPEG
    case "tiff", "tif":
        return kUTTypeTIFF
    default:
        return kUTTypePNG
    }
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func parseUInt32(_ value: String, name: String) throws -> UInt32 {
    guard let parsed = UInt32(value) else {
        throw CLIError("Invalid \(name): \(value)")
    }
    return parsed
}

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
