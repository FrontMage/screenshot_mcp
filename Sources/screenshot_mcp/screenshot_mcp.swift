import CoreGraphics
import Foundation
import ImageIO
import CoreServices
import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

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
            let options = try parseRecordingOptions(args: args, startIndex: 4)
            try await recordWindow(
                windowId: windowId,
                outputPath: outputPath,
                durationSeconds: durationSeconds,
                fps: options.fps,
                includeSystemAudio: options.includeSystemAudio
            )
        case "record-window-start":
            guard args.count >= 3 else { printUsageAndExit() }
            let windowId = try parseUInt32(args[1], name: "window_id")
            let outputPath = args[2]
            let options = try parseRecordingOptions(args: args, startIndex: 3)
            try await recordWindow(
                windowId: windowId,
                outputPath: outputPath,
                durationSeconds: nil,
                fps: options.fps,
                includeSystemAudio: options.includeSystemAudio
            )
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
          screenshot_mcp record-window-duration <window_id> <output_path> <duration_seconds> [fps] [system_audio=true|false]
          screenshot_mcp record-window-start <window_id> <output_path> [fps] [system_audio=true|false]
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

private func recordWindow(
    windowId: UInt32,
    outputPath: String,
    durationSeconds: Double?,
    fps: Int,
    includeSystemAudio: Bool
) async throws {
    guard #available(macOS 12.3, *) else {
        throw CLIError("Window recording requires macOS 12.3 or newer.")
    }
    if includeSystemAudio {
        guard #available(macOS 13.0, *) else {
            throw CLIError("System audio recording requires macOS 13.0 or newer.")
        }
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
        fps: fps,
        includeSystemAudio: includeSystemAudio
    )
}

@available(macOS 12.3, *)
private func recordWindowAvailable(
    windowId: UInt32,
    outputPath: String,
    durationSeconds: Double?,
    fps: Int,
    includeSystemAudio: Bool
) async throws {
    let url = URL(fileURLWithPath: outputPath)
    let dirUrl = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)

    let recorder = WindowFrameRecorder(
        windowId: CGWindowID(windowId),
        outputURL: url,
        fps: fps,
        includeSystemAudio: includeSystemAudio
    )
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

private func parseRecordingOptions(args: [String], startIndex: Int) throws -> (fps: Int, includeSystemAudio: Bool) {
    let extras = args.dropFirst(startIndex)
    var fps: Int?
    var includeSystemAudio: Bool?

    for value in extras {
        if let parsedBool = parseOptionalBool(value) {
            includeSystemAudio = parsedBool
            continue
        }
        if let parsedInt = Int(value) {
            if fps != nil {
                throw CLIError("fps specified more than once.")
            }
            fps = parsedInt
            continue
        }
        throw CLIError("Invalid recording option: \(value)")
    }

    return (
        fps: fps ?? defaultRecordingFps,
        includeSystemAudio: includeSystemAudio ?? false
    )
}

private func parseOptionalBool(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "true":
        return true
    case "false":
        return false
    default:
        return nil
    }
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
    private let includeSystemAudio: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var frameCount: Int64 = 0
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var width: Int = 0
    private var height: Int = 0
    private var writerStarted = false
    private var baseTime = CMTime.zero
    private var audioCapture: AnyObject?
    private var recordingError: Error?

    init(windowId: CGWindowID, outputURL: URL, fps: Int, includeSystemAudio: Bool) {
        self.windowId = windowId
        self.outputURL = outputURL
        self.fps = max(1, fps)
        self.includeSystemAudio = includeSystemAudio
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

        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(1000 / fps)))
        timer.setEventHandler { [weak self] in
            self?.captureFrame()
        }
        timer.resume()
        self.timer = timer

        if includeSystemAudio {
            if #available(macOS 13.0, *) {
                let audioCapture = SystemAudioCapture(queue: captureQueue) { [weak self] sampleBuffer in
                    self?.handleAudioSample(sampleBuffer)
                }
                self.audioCapture = audioCapture
                try await audioCapture.start()

                captureQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    if !self.writerStarted {
                        self.startWriterIfNeeded(at: .zero)
                        self.appendInitialFrame(image: firstImage)
                    }
                }
            } else {
                throw CLIError("System audio recording requires macOS 13.0 or newer.")
            }
        } else {
            captureQueue.sync {
                startWriterIfNeeded(at: .zero)
                appendInitialFrame(image: firstImage)
            }
        }

        await waitForStop()
        timer.cancel()
        if #available(macOS 13.0, *) {
            if let audioCapture = audioCapture as? SystemAudioCapture {
                await audioCapture.stop()
            }
        }
        try await finishWriting()

        if let recordingError = recordingError {
            throw recordingError
        }
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
        if !writerStarted {
            return
        }
        guard let image = captureImage() else {
            return
        }
        if image.width != width || image.height != height {
            return
        }
        let offset = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        let time = CMTimeAdd(baseTime, offset)
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

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        if stopRequested {
            return
        }
        if recordingError != nil {
            return
        }

        if audioInput == nil {
            do {
                try setupAudioInput(using: sampleBuffer)
            } catch {
                setError(error)
                return
            }
        }

        if !writerStarted {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startWriterIfNeeded(at: startTime)
            if let image = captureImage(), image.width == width, image.height == height {
                appendInitialFrame(image: image)
            }
        }

        guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else {
            return
        }
        audioInput.append(sampleBuffer)
    }

    private func setupAudioInput(using sampleBuffer: CMSampleBuffer) throws {
        guard let writer = writer else {
            throw CLIError("Writer not initialized.")
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw CLIError("Unable to read audio format description.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
            AVEncoderBitRateKey: 128_000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else {
            throw CLIError("Unable to add audio input to writer.")
        }
        writer.add(audioInput)
        self.audioInput = audioInput
    }

    private func startWriterIfNeeded(at time: CMTime) {
        guard let writer = writer, !writerStarted else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: time)
        baseTime = time
        writerStarted = true
        frameCount = 0
    }

    private func appendInitialFrame(image: CGImage) {
        let time = baseTime
        appendFrame(image: image, time: time)
    }

    private func setError(_ error: Error) {
        recordingError = error
        requestStop()
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

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
        audioInput?.markAsFinished()
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

@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private let handler: (CMSampleBuffer) -> Void
    private var stream: SCStream?

    init(queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) {
        self.queue = queue
        self.handler = handler
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CLIError("No display available for audio capture.")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        handler(sampleBuffer)
    }
}

@available(macOS 13.0, *)
extension SystemAudioCapture: @unchecked Sendable {}
