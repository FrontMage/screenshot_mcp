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
    @Published var isRecording: Bool = false
    @Published var status: String = "Idle"

    private var recordingProcess: Process?

    func refreshWindows() {
        do {
            let data = try runCli(arguments: ["list-windows"])
            let decoded = try JSONDecoder().decode([WindowInfo].self, from: data)
            let filtered = decoded.filter { $0.windowId > 0 }
            windows = filtered
            if selectedWindowId == nil {
                selectedWindowId = filtered.first?.windowId
            }
        } catch {
            status = "Failed to load windows: \(error)"
        }
    }

    func startRecording() {
        guard let windowId = selectedWindowId else {
            status = "Select a window first."
            return
        }
        if isRecording {
            return
        }

        let arguments = buildRecordArguments(windowId: windowId, outputPath: outputPath)
        let process = Process()
        do {
            process.executableURL = URL(fileURLWithPath: try cliPath())
        } catch {
            status = "Failed to locate CLI: \(error)"
            return
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            recordingProcess = process
            isRecording = true
            status = "Recording..."
        } catch {
            status = "Failed to start: \(error)"
        }
    }

    func stopRecording() {
        guard isRecording, let process = recordingProcess else { return }
        process.interrupt()
        isRecording = false
        recordingProcess = nil
        status = "Stopped"
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
        }
    }

    private func buildRecordArguments(windowId: Int, outputPath: String) -> [String] {
        var args = ["record-window-start", String(windowId), outputPath]
        args.append(includeSystemAudio ? "true" : "false")
        return args
    }

    private func runCli(arguments: [String]) throws -> Data {
        let cli = try cliPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
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

struct ContentView: View {
    @StateObject private var model = RecorderViewModel()

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
