import CoreGraphics
import Foundation
import ImageIO
import CoreServices
import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import UniformTypeIdentifiers

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

private let defaultRecordingFps = 10

@main
struct ScreenshotMcpCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
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
        case "record-window-duration":
            guard args.count >= 4 else { printUsageAndExit() }
            let windowId = try parseUInt32(args[1], name: "window_id")
            let outputPath = args[2]
            let durationSeconds = try parseDouble(args[3], name: "duration_seconds")
            let fps = try parseOptionalInt(args: args, index: 4, name: "fps") ?? defaultRecordingFps
            try await recordWindow(windowId: windowId, outputPath: outputPath, durationSeconds: durationSeconds, fps: fps)
        case "record-window-start":
            guard args.count >= 3 else { printUsageAndExit() }
            let windowId = try parseUInt32(args[1], name: "window_id")
            let outputPath = args[2]
            let fps = try parseOptionalInt(args: args, index: 3, name: "fps") ?? defaultRecordingFps
            try await recordWindow(windowId: windowId, outputPath: outputPath, durationSeconds: nil, fps: fps)
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
          screenshot_mcp record-window-duration <window_id> <output_path> <duration_seconds> [fps]
          screenshot_mcp record-window-start <window_id> <output_path> [fps]
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
        return UTType.jpeg.identifier as CFString
    case "heic":
        return UTType.heic.identifier as CFString
    case "tiff", "tif":
        return UTType.tiff.identifier as CFString
    default:
        return UTType.png.identifier as CFString
    }
}

private func recordWindow(windowId: UInt32, outputPath: String, durationSeconds: Double?, fps: Int) async throws {
    guard #available(macOS 12.3, *) else {
        throw CLIError("Window recording requires macOS 12.3 or newer.")
    }
    if let durationSeconds = durationSeconds, durationSeconds <= 0 {
        throw CLIError("duration_seconds must be greater than 0.")
    }
    if fps <= 0 {
        throw CLIError("fps must be greater than 0.")
    }

    try await recordWindowAvailable(
        windowId: windowId,
        outputPath: outputPath,
        durationSeconds: durationSeconds,
        fps: fps
    )
}

@available(macOS 12.3, *)
private func recordWindowAvailable(
    windowId: UInt32,
    outputPath: String,
    durationSeconds: Double?,
    fps: Int
) async throws {
    let url = URL(fileURLWithPath: outputPath)
    let dirUrl = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)

    let recorder = WindowFrameRecorder(windowId: CGWindowID(windowId), outputURL: url, fps: fps)
    let signalWatcher = SignalWatcher {
        recorder.requestStop()
    }
    signalWatcher.start()

    if let durationSeconds = durationSeconds {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + durationSeconds
        ) {
            recorder.requestStop()
        }
    }

    try await recorder.start()
    signalWatcher.stop()
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

private func parseDouble(_ value: String, name: String) throws -> Double {
    guard let parsed = Double(value) else {
        throw CLIError("Invalid \(name): \(value)")
    }
    return parsed
}

private func parseOptionalInt(args: [String], index: Int, name: String) throws -> Int? {
    guard args.count > index else { return nil }
    let value = args[index]
    guard let parsed = Int(value) else {
        throw CLIError("Invalid \(name): \(value)")
    }
    return parsed
}

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class SignalWatcher {
    private let handler: () -> Void
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }
}

@available(macOS 12.3, *)
final class WindowFrameRecorder {
    private let windowId: CGWindowID
    private let outputURL: URL
    private let fps: Int
    private let captureQueue = DispatchQueue(label: "screenshot_mcp.window_capture")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var frameCount: Int64 = 0
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var width: Int = 0
    private var height: Int = 0

    init(windowId: CGWindowID, outputURL: URL, fps: Int) {
        self.windowId = windowId
        self.outputURL = outputURL
        self.fps = max(1, fps)
    }

    func start() async throws {
        guard let firstImage = captureImage() else {
            throw CLIError("Unable to capture window \(windowId).")
        }
        width = firstImage.width
        height = firstImage.height
        if width <= 0 || height <= 0 {
            throw CLIError("Window \(windowId) has invalid bounds.")
        }

        try setupWriter(width: width, height: height)
        appendFrame(image: firstImage, time: .zero)

        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(1000 / fps)))
        timer.setEventHandler { [weak self] in
            self?.captureFrame()
        }
        timer.resume()
        self.timer = timer

        await waitForStop()
        timer.cancel()
        try await finishWriting()
    }

    func requestStop() {
        if stopRequested {
            return
        }
        stopRequested = true
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func waitForStop() async {
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            if stopRequested {
                continuation.resume()
                stopContinuation = nil
            }
        }
    }

    private func captureFrame() {
        if stopRequested {
            return
        }
        guard let image = captureImage() else {
            return
        }
        if image.width != width || image.height != height {
            return
        }
        let time = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        appendFrame(image: image, time: time)
    }

    private func captureImage() -> CGImage? {
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowId,
            [.bestResolution]
        )
    }

    private func setupWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw CLIError("Unable to add video input to writer.")
        }
        writer.add(input)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func appendFrame(image: CGImage, time: CMTime) {
        guard let input = input, let adaptor = adaptor else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = makePixelBuffer(from: image, width: width, height: height) else {
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: time)
        frameCount += 1
    }

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        let data = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue

        if let context = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func finishWriting() async throws {
        input?.markAsFinished()
        if let writer = writer {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            if writer.status == .failed {
                let message = writer.error?.localizedDescription ?? "Unknown error"
                throw CLIError("Recording failed: \(message)")
            }
        }
    }
}

@available(macOS 12.3, *)
extension WindowFrameRecorder: @unchecked Sendable {}
