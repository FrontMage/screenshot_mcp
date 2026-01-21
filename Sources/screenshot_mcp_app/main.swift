import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WindowInfo: Identifiable, Decodable {
    let windowId: Int
    let ownerName: String?
    let title: String?

    var id: Int { windowId }

    var displayName: String {
        let owner = ownerName?.isEmpty == false ? ownerName! : "Unknown App"
        let windowTitle = title?.isEmpty == false ? title! : "Untitled"
        return "\(owner) — \(windowTitle) (#\(windowId))"
    }
}

final class RecorderViewModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selectedWindowId: Int?
    @Published var includeSystemAudio: Bool = true
    @Published var outputPath: String = RecorderViewModel.defaultOutputPath()
    @Published var fps: Int = 30
    @Published var isRecording: Bool = false
    @Published var status: String = "Idle"

    private var recordingProcess: Process?
    private let logger = DebugLogger()
    private let defaultOutputDirectory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

    func refreshWindows() {
        do {
            logger.info("Refreshing window list.")
            let data = try runCli(arguments: ["list-windows"])
            let decoded = try JSONDecoder().decode([WindowInfo].self, from: data)
            let filtered = decoded.filter { $0.windowId > 0 }
            windows = filtered
            if selectedWindowId == nil {
                selectedWindowId = filtered.first?.windowId
            }
            logger.info("Loaded \(filtered.count) windows.")
        } catch {
            status = "Failed to load windows: \(error)"
            logger.error("Failed to load windows: \(error)")
        }
    }

    func startRecording() {
        guard let windowId = selectedWindowId else {
            status = "Select a window first."
            logger.error("Start failed: window not selected.")
            return
        }
        if isRecording {
            return
        }
        guard fps > 0 else {
            status = "FPS must be greater than 0."
            logger.error("Start failed: invalid fps \(fps).")
            return
        }

        let arguments = buildRecordArguments(windowId: windowId, outputPath: outputPath)
        let process = Process()
        do {
            process.executableURL = URL(fileURLWithPath: try cliPath())
        } catch {
            status = "Failed to locate CLI: \(error)"
            logger.error("Start failed: \(error)")
            return
        }
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            recordingProcess = process
            isRecording = true
            status = "Recording..."
            logger.info("Recording started for window \(windowId) at \(fps) fps. Output: \(outputPath)")
            process.terminationHandler = { [weak self] proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: outData, encoding: .utf8), !output.isEmpty {
                    self?.logger.info("CLI stdout: \(output)")
                }
                if let errorOutput = String(data: errData, encoding: .utf8), !errorOutput.isEmpty {
                    self?.logger.error("CLI stderr: \(errorOutput)")
                }
                if proc.terminationStatus != 0 {
                    DispatchQueue.main.async {
                        self?.status = "Recording failed (exit \(proc.terminationStatus))."
                    }
                }
            }
        } catch {
            status = "Failed to start: \(error)"
            logger.error("Start failed: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording, let process = recordingProcess else { return }
        process.interrupt()
        isRecording = false
        recordingProcess = nil
        status = "Stopped"
        outputPath = RecorderViewModel.defaultOutputPath()
        logger.info("Recording stopped.")
    }

    @MainActor
    func chooseOutputPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (outputPath as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (outputPath as NSString).deletingLastPathComponent)

        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
            logger.info("Output path set to \(outputPath)")
        }
    }

    private func buildRecordArguments(windowId: Int, outputPath: String) -> [String] {
        var args = ["record-window-start", String(windowId), outputPath]
        args.append(String(fps))
        args.append(includeSystemAudio ? "true" : "false")
        return args
    }

    private func runCli(arguments: [String]) throws -> Data {
        let cli = try cliPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            if let errorMessage = String(data: errData, encoding: .utf8), !errorMessage.isEmpty {
                logger.error("CLI stderr: \(errorMessage)")
            }
            throw CLIError("CLI failed with status \(process.terminationStatus)")
        }

        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func cliPath() throws -> String {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let buildDir = currentExecutable.deletingLastPathComponent()
        let cli = buildDir.appendingPathComponent("screenshot_mcp")
        if FileManager.default.isExecutableFile(atPath: cli.path) {
            return cli.path
        }
        throw CLIError("Unable to locate screenshot_mcp binary. Build it with `swift build`.")
    }

    private static func defaultOutputPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "\(formatter.string(from: Date())).mp4"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return downloads?.appendingPathComponent(filename).path ?? filename
    }
}

extension RecorderViewModel: @unchecked Sendable {}

struct ContentView: View {
    @StateObject private var model = RecorderViewModel()
    private let fpsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 240
        formatter.allowsFloats = false
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Window")
                    .frame(width: 80, alignment: .leading)
                Picker("Window", selection: $model.selectedWindowId) {
                    ForEach(model.windows) { window in
                        Text(window.displayName).tag(Optional(window.windowId))
                    }
                }
                .pickerStyle(.menu)
                Button("Refresh") {
                    model.refreshWindows()
                }
            }

            HStack {
                Text("System Audio")
                    .frame(width: 80, alignment: .leading)
                Toggle("Record system audio", isOn: $model.includeSystemAudio)
                    .labelsHidden()
            }

            HStack {
                Text("FPS")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $model.fps, formatter: fpsFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            HStack {
                Text("Output")
                    .frame(width: 80, alignment: .leading)
                TextField("", text: $model.outputPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose") {
                    model.chooseOutputPath()
                }
            }

            HStack {
                Button("Start") {
                    model.startRecording()
                }
                .disabled(model.isRecording)

                Button("Stop") {
                    model.stopRecording()
                }
                .disabled(!model.isRecording)
            }

            Text(model.status)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 720)
        .onAppear {
            model.refreshWindows()
        }
    }
}

@main
struct RecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class DebugLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "screenshot_mcp_app.logger")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init() {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        let logDir = documents?.appendingPathComponent("screenshot_mcp")
        let logFile = logDir?.appendingPathComponent("debug.log")
        self.fileURL = logFile ?? URL(fileURLWithPath: "debug.log")

        if let logDir = logDir {
            try? manager.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: nil)
        }
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
            let line = "[\(timestamp)] [\(level)] \(message)\n"
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
