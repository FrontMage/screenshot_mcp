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
#if canImport(AppKit)
import AppKit
#endif

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
private let cliLogger = DebugLogger(source: "CLI")

@MainActor
private func initializeWindowServerConnection() {
    #if canImport(AppKit)
    _ = NSApplication.shared
    #endif
    _ = CGMainDisplayID()
}

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
        case "list-shareable-windows":
            let windows = try await listShareableWindows()
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
          screenshot_mcp list-shareable-windows
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

private func listShareableWindows() async throws -> [WindowInfo] {
    if #available(macOS 13.0, *) {
        await initializeWindowServerConnection()
        let content = try await SCShareableContent.current
        return content.windows.map { window in
            let owner = window.owningApplication
            let ownerPid: Int?
            if let processID = owner?.processID {
                ownerPid = Int(processID)
            } else {
                ownerPid = nil
            }
            let frame = window.frame
            return WindowInfo(
                windowId: Int(window.windowID),
                ownerName: owner?.applicationName,
                ownerPid: ownerPid,
                title: window.title,
                bounds: Rect(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.size.width),
                    height: Double(frame.size.height)
                ),
                layer: nil,
                isOnScreen: nil,
                alpha: nil,
                displayId: nil
            )
        }
    }
    throw CLIError("list-shareable-windows requires macOS 13 or later")
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
    cliLogger.info("record-window start windowId=\(windowId) fps=\(fps) systemAudio=\(includeSystemAudio) output=\(outputPath)")
    let url = URL(fileURLWithPath: outputPath)
    let dirUrl = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
        cliLogger.info("record-window removed existing output \(url.path)")
    }

    let recorder: RecordingController
    if #available(macOS 13.0, *) {
        recorder = WindowStreamRecorder(
            windowId: CGWindowID(windowId),
            outputURL: url,
            fps: fps,
            includeSystemAudio: includeSystemAudio
        )
    } else {
        if includeSystemAudio {
            throw CLIError("System audio recording requires macOS 13.0 or newer.")
        }
        recorder = WindowFrameRecorder(
            windowId: CGWindowID(windowId),
            outputURL: url,
            fps: fps,
            includeSystemAudio: includeSystemAudio
        )
    }
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
    cliLogger.info("record-window finished windowId=\(windowId)")
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
protocol RecordingController: AnyObject {
    func start() async throws
    func requestStop()
}

@available(macOS 12.3, *)
final class WindowFrameRecorder: RecordingController {
    private let windowId: CGWindowID
    private let outputURL: URL
    private let fps: Int
    private let captureQueue = DispatchQueue(label: "screenshot_mcp.window_capture")
    private let writerQueue = DispatchQueue(label: "screenshot_mcp.writer")
    private let audioQueue = DispatchQueue(label: "screenshot_mcp.window_audio")
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
    private var frameDropCount = 0
    private var nilImageCount = 0
    private var sizeMismatchCount = 0
    private var audioSampleCount = 0

    init(windowId: CGWindowID, outputURL: URL, fps: Int, includeSystemAudio: Bool) {
        self.windowId = windowId
        self.outputURL = outputURL
        self.fps = max(1, fps)
        self.includeSystemAudio = includeSystemAudio
    }

    func start() async throws {
        guard let firstImage = captureImage() else {
            cliLogger.error("captureImage failed windowId=\(windowId)")
            throw CLIError("Unable to capture window \(windowId).")
        }
        width = firstImage.width
        height = firstImage.height
        if width <= 0 || height <= 0 {
            cliLogger.error("invalid window size windowId=\(windowId) width=\(width) height=\(height)")
            throw CLIError("Window \(windowId) has invalid bounds.")
        }

        cliLogger.info("record setup windowId=\(windowId) size=\(width)x\(height)")
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
                let audioCapture = SystemAudioCapture(queue: audioQueue) { [weak self] sampleBuffer in
                    self?.handleAudioSample(sampleBuffer)
                }
                self.audioCapture = audioCapture
                cliLogger.info("starting system audio capture windowId=\(windowId)")
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
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard let image = self.captureImage() else {
                self.nilImageCount += 1
                if self.nilImageCount % self.fps == 0 {
                    cliLogger.error("captureImage returned nil windowId=\(self.windowId) count=\(self.nilImageCount)")
                }
                return
            }
            if image.width != self.width || image.height != self.height {
                self.sizeMismatchCount += 1
                if self.sizeMismatchCount % self.fps == 0 {
                    cliLogger.error("size mismatch windowId=\(self.windowId) count=\(self.sizeMismatchCount)")
                }
                return
            }
            if !self.writerStarted {
                self.startWriterIfNeeded(at: .zero)
            }
            self.appendFrameWithNextTime(image: image)
        }
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

        if includeSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            } else {
                cliLogger.error("unable to add default audio input windowId=\(windowId)")
                throw CLIError("Unable to add default audio input to writer.")
            }
        }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func appendFrame(image: CGImage, time: CMTime) {
        guard let input = input, let adaptor = adaptor else { return }
        guard input.isReadyForMoreMediaData else {
            frameDropCount += 1
            if frameDropCount % fps == 0 {
                cliLogger.error("video backpressure windowId=\(windowId) drops=\(frameDropCount)")
            }
            return
        }
        guard let pixelBuffer = makePixelBuffer(from: image, width: width, height: height) else {
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: time)
        frameCount += 1
        if frameCount % Int64(fps) == 0 {
            cliLogger.info("frameCount windowId=\(windowId) frames=\(frameCount)")
        }
    }

    private func appendFrameWithNextTime(image: CGImage) {
        let offset = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        let time = CMTimeAdd(baseTime, offset)
        appendFrame(image: image, time: time)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            self?.handleAudioSampleOnWriter(sampleBuffer)
        }
    }

    private func handleAudioSampleOnWriter(_ sampleBuffer: CMSampleBuffer) {
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
            startWriterIfNeeded(at: startTime.isValid ? startTime : .zero)
            if let image = captureImage(), image.width == width, image.height == height {
                appendInitialFrame(image: image)
            }
        }

        guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else {
            return
        }
        audioInput.append(sampleBuffer)
        audioSampleCount += 1
        if audioSampleCount % 100 == 0 {
            cliLogger.info("audio samples windowId=\(windowId) count=\(audioSampleCount)")
        }
    }

    private func setupAudioInput(using sampleBuffer: CMSampleBuffer) throws {
        guard let writer = writer else {
            throw CLIError("Writer not initialized.")
        }
        if audioInput != nil {
            return
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

        var audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: formatDescription
        )
        audioInput.expectsMediaDataInRealTime = true

        if !writer.canAdd(audioInput) {
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            audioInput.expectsMediaDataInRealTime = true
        }

        guard writer.canAdd(audioInput) else {
            let formatID = fourCC(asbd.mFormatID)
            throw CLIError(
                "Unable to add audio input to writer. format=\(formatID) " +
                "sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame)"
            )
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
        cliLogger.info("writer started windowId=\(windowId) baseTime=\(baseTime.seconds)")
    }

    private func appendInitialFrame(image: CGImage) {
        appendFrame(image: image, time: baseTime)
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

private func fourCC(_ code: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    return bytes.map { byte in
        let scalar = UnicodeScalar(byte)
        if scalar.isASCII && scalar.value >= 32 {
            return Character(scalar)
        }
        return "?"
    }.map(String.init).joined()
}

@available(macOS 13.0, *)
final class WindowStreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, RecordingController {
    private let windowId: CGWindowID
    private let outputURL: URL
    private let fps: Int
    private let includeSystemAudio: Bool
    private let writerQueue = DispatchQueue(label: "screenshot_mcp.stream_writer")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var recordingError: Error?
    private var frameCount: Int64 = 0
    private var audioSampleCount = 0
    private var videoDropCount = 0
    private var audioDropCount = 0
    private var pendingVideoSample: CMSampleBuffer?
    private var pendingAudioSample: CMSampleBuffer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastVideoTime: CMTime = .invalid
    private var frameStatusCounts: [Int: Int] = [:]
    private var lastStatusLogTime: CFAbsoluteTime = 0

    private enum FrameStatus: Int {
        case complete = 0
        case idle = 1
        case blank = 2
        case suspended = 3
    }

    init(windowId: CGWindowID, outputURL: URL, fps: Int, includeSystemAudio: Bool) {
        self.windowId = windowId
        self.outputURL = outputURL
        self.fps = max(1, fps)
        self.includeSystemAudio = includeSystemAudio
        super.init()
    }

    private func evenDimension(_ value: Int) -> Int {
        let adjusted = value - (value % 2)
        return adjusted > 0 ? adjusted : value
    }

    func start() async throws {
        await initializeWindowServerConnection()
        let content = try await SCShareableContent.current
        logShareableContentSummary(content)
        guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
            throw CLIError("Window \(windowId) not found for stream capture.")
        }

        logWindowDiagnostics(window: window, allWindows: content.windows)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.capturesAudio = includeSystemAudio
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        if window.frame.width > 0, window.frame.height > 0 {
            let targetWidth = Int(window.frame.width)
            let targetHeight = Int(window.frame.height)
            let evenWidth = evenDimension(targetWidth)
            let evenHeight = evenDimension(targetHeight)
            if evenWidth != targetWidth || evenHeight != targetHeight {
                cliLogger.info(
                    "stream resize windowId=\(windowId) from \(targetWidth)x\(targetHeight) to \(evenWidth)x\(evenHeight)"
                )
            }
            config.width = evenWidth
            config.height = evenHeight
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        if includeSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        }

        cliLogger.info("stream recorder start windowId=\(windowId) fps=\(fps) audio=\(includeSystemAudio)")
        try await stream.startCapture()

        await waitForStop()
        try await stream.stopCapture()
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cliLogger.error("stream stopped windowId=\(windowId) error=\(error.localizedDescription)")
        setError(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopRequested else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleAudioSample(sampleBuffer)
        default:
            return
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        if recordingError != nil {
            return
        }

        let status = frameStatus(from: sampleBuffer)
        recordFrameStatus(status, sampleBuffer: sampleBuffer)
        if let status = status, status != .complete {
            handleNonCompleteVideoSample(sampleBuffer, status: status)
            return
        }

        if includeSystemAudio, !writerStarted {
            if pendingVideoSample == nil {
                pendingVideoSample = sampleBuffer
            }
            if pendingAudioSample != nil {
                startWriterWithPendingSamples()
            }
            return
        }

        do {
            try ensureWriterForVideo(sampleBuffer)
        } catch {
            setError(error)
            return
        }

        guard let videoInput = videoInput else { return }
        if !writerStarted {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startWriterIfNeeded(at: time.isValid ? time : .zero)
        }
        appendVideoSample(sampleBuffer, to: videoInput)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        if recordingError != nil {
            return
        }
        guard includeSystemAudio else { return }

        if !writerStarted {
            if pendingAudioSample == nil {
                pendingAudioSample = sampleBuffer
            }
            if pendingVideoSample != nil {
                startWriterWithPendingSamples()
            }
            return
        }

        guard let writer = writer, writer.status == .writing else {
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

        guard let audioInput = audioInput else { return }
        appendAudioSample(sampleBuffer, to: audioInput)
    }

    private func ensureWriterForVideo(_ sampleBuffer: CMSampleBuffer) throws {
        if writer != nil {
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CLIError("Missing video format description.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        if width <= 0 || height <= 0 {
            throw CLIError("Invalid video dimensions \(width)x\(height).")
        }
        if width % 2 != 0 || height % 2 != 0 {
            cliLogger.error("odd video dimensions windowId=\(windowId) size=\(width)x\(height)")
            throw CLIError("Video dimensions must be even: \(width)x\(height)")
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CLIError("Unable to add video input to writer.")
        }
        writer.add(input)

        let pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription)
        let adaptorAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttributes
        )

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
        cliLogger.info("stream writer setup windowId=\(windowId) size=\(width)x\(height)")
    }

    private func startWriterWithPendingSamples() {
        guard let videoSample = pendingVideoSample else { return }
        guard let audioSample = pendingAudioSample else { return }

        do {
            try ensureWriterForVideo(videoSample)
            try setupAudioInput(using: audioSample)
        } catch {
            setError(error)
            return
        }

        let videoTime = CMSampleBufferGetPresentationTimeStamp(videoSample)
        let audioTime = CMSampleBufferGetPresentationTimeStamp(audioSample)
        let startTime = min(videoTime, audioTime)
        startWriterIfNeeded(at: startTime.isValid ? startTime : .zero)

        if let videoInput = videoInput {
            appendVideoSample(videoSample, to: videoInput)
        }
        if let audioInput = audioInput {
            appendAudioSample(audioSample, to: audioInput)
        }

        pendingVideoSample = nil
        pendingAudioSample = nil
    }

    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer, to videoInput: AVAssetWriterInput) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logMissingPixelBuffer(sampleBuffer)
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if appendPixelBuffer(pixelBuffer, at: time, videoInput: videoInput, sampleBuffer: sampleBuffer) {
            stashLastPixelBuffer(from: pixelBuffer)
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer, to audioInput: AVAssetWriterInput) {
        guard audioInput.isReadyForMoreMediaData else {
            audioDropCount += 1
            if audioDropCount % 100 == 0 {
                cliLogger.error("audio backpressure windowId=\(windowId) drops=\(audioDropCount)")
            }
            return
        }
        if audioInput.append(sampleBuffer) {
            audioSampleCount += 1
            if audioSampleCount % 100 == 0 {
                cliLogger.info("stream audio samples windowId=\(windowId) count=\(audioSampleCount)")
            }
        } else {
            logWriterFailure(kind: "audio", sampleBuffer: sampleBuffer, pixelBuffer: nil)
        }
    }

    private func logWriterFailure(
        kind: String,
        sampleBuffer: CMSampleBuffer?,
        pixelBuffer: CVPixelBuffer?
    ) {
        let writerStatus = writer?.status
        let statusValue = writerStatus?.rawValue ?? -1
        let statusText = writerStatus.map { String(describing: $0) } ?? "unknown"
        let error = writer?.error as NSError?
        let errorDesc = error?.localizedDescription ?? "Unknown error"
        let errorDomain = error?.domain ?? "Unknown domain"
        let errorCode = error?.code ?? -1
        let errorInfo = error?.userInfo ?? [:]
        cliLogger.error(
            "\(kind) append failed windowId=\(windowId) status=\(statusValue) (\(statusText)) error=\(errorDesc) domain=\(errorDomain) code=\(errorCode) info=\(errorInfo)"
        )

        guard let sampleBuffer = sampleBuffer else {
            return
        }
        let pts = timeString(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let dur = timeString(CMSampleBufferGetDuration(sampleBuffer))
        let valid = CMSampleBufferIsValid(sampleBuffer)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let formatInfo = CMSampleBufferGetFormatDescription(sampleBuffer).map(formatDescriptionInfo) ?? "unknown"
        let pixelInfo = pixelBuffer.map(pixelBufferInfo) ?? "none"
        cliLogger.error(
            "\(kind) sample windowId=\(windowId) pts=\(pts) dur=\(dur) valid=\(valid) samples=\(numSamples) format=\(formatInfo) pixel=\(pixelInfo)"
        )
    }

    private func logMissingPixelBuffer(_ sampleBuffer: CMSampleBuffer) {
        let pts = timeString(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let dur = timeString(CMSampleBufferGetDuration(sampleBuffer))
        let valid = CMSampleBufferIsValid(sampleBuffer)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let formatInfo = CMSampleBufferGetFormatDescription(sampleBuffer).map(formatDescriptionInfo) ?? "unknown"
        let dataLength: Int
        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            dataLength = CMBlockBufferGetDataLength(dataBuffer)
        } else {
            dataLength = 0
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let attachmentInfo = attachments.map { String(describing: $0) } ?? "none"
        let parsed = parseSampleAttachments(attachments)
        cliLogger.error(
            "missing pixel buffer windowId=\(windowId) pts=\(pts) dur=\(dur) valid=\(valid) samples=\(numSamples) format=\(formatInfo) dataLength=\(dataLength) \(parsed) attachments=\(attachmentInfo)"
        )
    }

    private func handleNonCompleteVideoSample(_ sampleBuffer: CMSampleBuffer, status: FrameStatus) {
        guard status == .idle else {
            return
        }
        guard writerStarted, let videoInput = videoInput else {
            return
        }
        guard let lastPixelBuffer = lastPixelBuffer else {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        _ = appendPixelBuffer(lastPixelBuffer, at: time, videoInput: videoInput, sampleBuffer: sampleBuffer)
    }

    private func appendPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime,
        videoInput: AVAssetWriterInput,
        sampleBuffer: CMSampleBuffer?
    ) -> Bool {
        guard let adaptor = adaptor else {
            cliLogger.error("missing adaptor windowId=\(windowId)")
            return false
        }
        guard videoInput.isReadyForMoreMediaData else {
            videoDropCount += 1
            if videoDropCount % fps == 0 {
                cliLogger.error("video backpressure windowId=\(windowId) drops=\(videoDropCount)")
            }
            return false
        }
        let pts = time.isValid ? time : .zero
        if lastVideoTime.isValid && pts <= lastVideoTime {
            cliLogger.error(
                "non-monotonic video pts windowId=\(windowId) pts=\(timeString(pts)) last=\(timeString(lastVideoTime))"
            )
            return false
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            logWriterFailure(kind: "video", sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)
            return false
        }
        lastVideoTime = pts
        frameCount += 1
        if frameCount % Int64(fps) == 0 {
            cliLogger.info("stream frames windowId=\(windowId) count=\(frameCount)")
        }
        return true
    }

    private func stashLastPixelBuffer(from pixelBuffer: CVPixelBuffer) {
        guard let copied = copyPixelBuffer(pixelBuffer) else {
            return
        }
        lastPixelBuffer = copied
    }

    private func copyPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var copy: CVPixelBuffer?

        if let pool = adaptor?.pixelBufferPool {
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy)
            if status != kCVReturnSuccess {
                cliLogger.error("pixel buffer pool copy failed windowId=\(windowId) status=\(status)")
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let status = CVPixelBufferCreate(
                nil,
                width,
                height,
                format,
                attrs as CFDictionary,
                &copy
            )
            if status != kCVReturnSuccess {
                cliLogger.error("pixel buffer copy failed windowId=\(windowId) status=\(status)")
                return nil
            }
        }

        guard let copyBuffer = copy else {
            return nil
        }
        copyPixelBufferData(from: pixelBuffer, to: copyBuffer)
        return copyBuffer
    }

    private func copyPixelBufferData(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    continue
                }
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                let rowBytes = min(srcBytesPerRow, dstBytesPerRow)
                if rowBytes <= 0 || height <= 0 { continue }
                for row in 0..<height {
                    let srcPtr = srcBase.advanced(by: row * srcBytesPerRow)
                    let dstPtr = dstBase.advanced(by: row * dstBytesPerRow)
                    memcpy(dstPtr, srcPtr, rowBytes)
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(destination) else {
                return
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let height = CVPixelBufferGetHeight(source)
            let rowBytes = min(srcBytesPerRow, dstBytesPerRow)
            if rowBytes <= 0 || height <= 0 { return }
            for row in 0..<height {
                let srcPtr = srcBase.advanced(by: row * srcBytesPerRow)
                let dstPtr = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstPtr, srcPtr, rowBytes)
            }
        }
    }

    private func parseSampleAttachments(_ attachments: CFArray?) -> String {
        guard let attachments = attachments as? [[String: Any]], let first = attachments.first else {
            return "attachmentParsed=none"
        }
        let statusKeys = [
            "SCStreamUpdateFrameStatus",
            "SCStreamFrameStatus",
            "SCFrameStatus",
            "SCStreamFrameInfoStatus",
        ]
        let displayTimeKeys = [
            "SCStreamUpdateFrameDisplayTime",
            "SCStreamFrameDisplayTime",
            "SCFrameDisplayTime",
            "SCStreamFrameInfoDisplayTime",
        ]
        let statusValue = statusKeys.compactMap { first[$0] }.first
        let displayTimeValue = displayTimeKeys.compactMap { first[$0] }.first
        let emptyMediaKey = "kCMSampleAttachmentKey_EmptyMedia"
        let emptyMediaValue = first[emptyMediaKey]
        return "attachmentParsed=status=\(String(describing: statusValue)) displayTime=\(String(describing: displayTimeValue)) emptyMedia=\(String(describing: emptyMediaValue))"
    }

    private func frameStatus(from sampleBuffer: CMSampleBuffer) -> FrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[String: Any]],
              let first = attachments.first else {
            return nil
        }
        let statusKeys = [
            "SCStreamUpdateFrameStatus",
            "SCStreamFrameStatus",
            "SCFrameStatus",
            "SCStreamFrameInfoStatus",
        ]
        for key in statusKeys {
            if let value = first[key] {
                let raw: Int?
                if let number = value as? NSNumber {
                    raw = number.intValue
                } else if let intValue = value as? Int {
                    raw = intValue
                } else {
                    raw = nil
                }
                if let raw = raw {
                    return FrameStatus(rawValue: raw)
                }
            }
        }
        return nil
    }

    private func recordFrameStatus(_ status: FrameStatus?, sampleBuffer: CMSampleBuffer) {
        let rawValue = status?.rawValue ?? -1
        frameStatusCounts[rawValue, default: 0] += 1
        let now = CFAbsoluteTimeGetCurrent()
        if lastStatusLogTime == 0 {
            lastStatusLogTime = now
        }
        if now - lastStatusLogTime < 5 {
            return
        }
        let pts = timeString(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let summary = frameStatusCounts
            .sorted { $0.key < $1.key }
            .map { "\(frameStatusName($0.key))=\($0.value)" }
            .joined(separator: " ")
        cliLogger.info("frame status windowId=\(windowId) pts=\(pts) \(summary)")
        lastStatusLogTime = now
    }

    private func frameStatusName(_ rawValue: Int) -> String {
        switch rawValue {
        case FrameStatus.complete.rawValue:
            return "complete"
        case FrameStatus.idle.rawValue:
            return "idle"
        case FrameStatus.blank.rawValue:
            return "blank"
        case FrameStatus.suspended.rawValue:
            return "suspended"
        case -1:
            return "unknown"
        default:
            return "status\(rawValue)"
        }
    }

    private func logWindowDiagnostics(window: SCWindow, allWindows: [SCWindow]) {
        let owner = window.owningApplication
        let ownerName = owner?.applicationName ?? "unknown"
        let ownerBundle = owner?.bundleIdentifier ?? "unknown"
        let ownerPid = owner?.processID ?? 0
        let title = window.title ?? ""
        let frame = window.frame
        cliLogger.info(
            "stream target windowId=\(windowId) title=\(title) owner=\(ownerName) bundle=\(ownerBundle) pid=\(ownerPid) frame=\(Int(frame.origin.x))x\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))"
        )

        let sameOwner = allWindows.filter { $0.owningApplication?.processID == ownerPid }
        if sameOwner.count > 1 {
            let ids = sameOwner.map { String($0.windowID) }.joined(separator: ",")
            cliLogger.info("stream owner windows pid=\(ownerPid) count=\(sameOwner.count) ids=\(ids)")
            for candidate in sameOwner {
                let title = candidate.title ?? ""
                let frame = candidate.frame
                cliLogger.info(
                    "stream owner window windowId=\(candidate.windowID) title=\(title) frame=\(Int(frame.origin.x))x\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))"
                )
            }
        }

        logCgWindowsForOwner(ownerPid: Int(ownerPid), ownerName: ownerName)

        if let windowInfoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]],
           let info = windowInfoList.first {
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "unknown"
            let title = info[kCGWindowName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool
            let alpha = info[kCGWindowAlpha as String] as? Double
            let boundsText: String
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let x = boundsDict["X"] as? Double,
               let y = boundsDict["Y"] as? Double,
               let width = boundsDict["Width"] as? Double,
               let height = boundsDict["Height"] as? Double {
                boundsText = "\(Int(x))x\(Int(y)) \(Int(width))x\(Int(height))"
            } else {
                boundsText = "unknown"
            }
            cliLogger.info(
                "stream cgwindow windowId=\(windowId) title=\(title) owner=\(ownerName) layer=\(layer) onScreen=\(String(describing: isOnScreen)) alpha=\(String(describing: alpha)) bounds=\(boundsText)"
            )
        }
    }

    private func logCgWindowsForOwner(ownerPid: Int, ownerName: String) {
        guard ownerPid > 0 else {
            return
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let ownerWindows = windowInfoList.filter { info in
            (info[kCGWindowOwnerPID as String] as? Int) == ownerPid
        }
        guard !ownerWindows.isEmpty else {
            return
        }
        let sorted = ownerWindows.sorted { windowAreaFromBounds($0) > windowAreaFromBounds($1) }
        cliLogger.info("cgwindow owner windows pid=\(ownerPid) owner=\(ownerName) count=\(sorted.count)")
        for info in sorted {
            let windowId = info[kCGWindowNumber as String] as? Int ?? -1
            let title = info[kCGWindowName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool
            let alpha = info[kCGWindowAlpha as String] as? Double
            let boundsText: String
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let x = boundsDict["X"] as? Double,
               let y = boundsDict["Y"] as? Double,
               let width = boundsDict["Width"] as? Double,
               let height = boundsDict["Height"] as? Double {
                boundsText = "\(Int(x))x\(Int(y)) \(Int(width))x\(Int(height))"
            } else {
                boundsText = "unknown"
            }
            cliLogger.info(
                "cgwindow owner window windowId=\(windowId) title=\(title) layer=\(layer) onScreen=\(String(describing: isOnScreen)) alpha=\(String(describing: alpha)) bounds=\(boundsText)"
            )
        }
    }

    private func windowAreaFromBounds(_ info: [String: Any]) -> Double {
        guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let width = boundsDict["Width"] as? Double,
              let height = boundsDict["Height"] as? Double else {
            return 0
        }
        return max(0, width) * max(0, height)
    }

    private func logShareableContentSummary(_ content: SCShareableContent) {
        cliLogger.info(
            "shareable content windows=\(content.windows.count) displays=\(content.displays.count) apps=\(content.applications.count)"
        )
        let sortedWindows = content.windows.sorted { windowArea($0) > windowArea($1) }
        for window in sortedWindows.prefix(12) {
            let owner = window.owningApplication
            let ownerName = owner?.applicationName ?? "unknown"
            let ownerPid = owner?.processID ?? 0
            let title = window.title ?? ""
            let frame = window.frame
            cliLogger.info(
                "shareable window windowId=\(window.windowID) title=\(title) owner=\(ownerName) pid=\(ownerPid) frame=\(Int(frame.origin.x))x\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))"
            )
        }
    }

    private func windowArea(_ window: SCWindow) -> Double {
        let frame = window.frame
        return max(0, frame.size.width) * max(0, frame.size.height)
    }

    private func formatDescriptionInfo(_ formatDescription: CMFormatDescription) -> String {
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        var details = "type=\(fourCCString(mediaType)) subtype=\(fourCCString(mediaSubType))"
        if mediaType == kCMMediaType_Video {
            let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
            details += " \(dims.width)x\(dims.height)"
        }
        return details
    }

    private func pixelBufferInfo(_ pixelBuffer: CVPixelBuffer) -> String {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return "\(width)x\(height) format=\(fourCCString(format))"
    }

    private func timeString(_ time: CMTime) -> String {
        guard time.isValid else {
            return "invalid"
        }
        guard time.isNumeric else {
            return "non-numeric"
        }
        return String(format: "%.6f", CMTimeGetSeconds(time))
    }

    private func fourCCString(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if let string = String(bytes: bytes, encoding: .macOSRoman) {
            let trimmed = string.trimmingCharacters(in: .controlCharacters)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return String(format: "0x%08X", value)
    }

    private func setupAudioInput(using sampleBuffer: CMSampleBuffer) throws {
        guard let writer = writer else {
            return
        }
        if audioInput != nil {
            return
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

        var audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: formatDescription
        )
        audioInput.expectsMediaDataInRealTime = true

        if !writer.canAdd(audioInput) {
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            audioInput.expectsMediaDataInRealTime = true
        }

        guard writer.canAdd(audioInput) else {
            let formatID = fourCC(asbd.mFormatID)
            throw CLIError(
                "Unable to add audio input to writer. format=\(formatID) " +
                "sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame)"
            )
        }
        writer.add(audioInput)
        self.audioInput = audioInput
    }

    private func startWriterIfNeeded(at time: CMTime) {
        guard let writer = writer, !writerStarted else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: time)
        writerStarted = true
        cliLogger.info("stream writer started windowId=\(windowId) baseTime=\(time.seconds)")
    }

    private func finishWriting() async throws {
        guard let writer = writer else {
            throw CLIError("No video frames captured for window \(windowId).")
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
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

    private func setError(_ error: Error) {
        recordingError = error
        requestStop()
    }
}

@available(macOS 13.0, *)
extension WindowStreamRecorder: @unchecked Sendable {}

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

final class DebugLogger {
    private let source: String
    private let fileURL: URL
    private let queue = DispatchQueue(label: "screenshot_mcp.cli.logger")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(source: String) {
        self.source = source
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let logDir = documents.appendingPathComponent("screenshot_mcp")
        self.fileURL = logDir.appendingPathComponent("debug.log")
        try? manager.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: nil)
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        queue.async {
            let timestamp = self.formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] [\(self.source)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: self.fileURL, options: .atomic)
                }
            }
        }
    }
}

extension DebugLogger: @unchecked Sendable {}
