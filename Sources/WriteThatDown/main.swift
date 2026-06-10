import AppKit
import AVFoundation
import CoreGraphics
import WriteThatDownKit

// Headless self-test: `WriteThatDown --check-model <folder>` loads the WhisperKit
// model from a local folder and runs offline inference, then exits — no UI.
if let idx = CommandLine.arguments.firstIndex(of: "--check-model") {
    guard idx + 1 < CommandLine.arguments.count else {
        // A bare `--check-model` must report usage, not fall through and
        // silently boot the menu-bar app (which would hang a script/CI run).
        FileHandle.standardError.write(Data("usage: WriteThatDown --check-model <model-folder>\n".utf8))
        exit(2)
    }
    EngineSelfTest.run(modelFolder: CommandLine.arguments[idx + 1])
}

// Headless one-time download + self-test of a model variant by name.
if let idx = CommandLine.arguments.firstIndex(of: "--download-model") {
    guard idx + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: WriteThatDown --download-model <model-name>\n".utf8))
        exit(2)
    }
    EngineSelfTest.runDownload(model: CommandLine.arguments[idx + 1])
}

// Print the current TCC permission state AS SEEN BY THIS BINARY and exit.
// Faithful for the installed app because TCC keys off the code signature.
// Synchronous queries only — UNUserNotificationCenter hangs from a CLI run.
if CommandLine.arguments.contains("--check-permissions") {
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    let micText: String
    switch mic {
    case .authorized: micText = "granted"
    case .denied, .restricted: micText = "denied"
    case .notDetermined: micText = "notDetermined"
    @unknown default: micText = "unknown"
    }
    let screen = CGPreflightScreenCaptureAccess()
    print("microphone:      \(micText)")
    print("screenCapture:   \(screen ? "granted" : "denied")")
    print("canStartSession: \(micText == "granted" && screen)")
    exit(0)
}

// Print the resolved configuration (defaults < config file < env vars) and exit.
if CommandLine.arguments.contains("--print-config") {
    let c = AppEnvironment.loadConfiguration()
    print("Resolved configuration:")
    print("  config file:      \(AppEnvironment.configFileURL.path)")
    print("  engine:           \(c.engine.rawValue)")
    print("  language:         \(c.language)")
    print("  output_dir:       \(c.outputDir.path)")
    print("  inactivity_ms:    \(c.inactivityTimeoutMs)")
    print("  poll_ms:          \(c.pollIntervalMs)")
    print("  start_confirm_ms: \(c.startConfirmMs)")
    print("  whisper_model:    \(c.whisperModel)")
    print("  model_folder:     \(c.whisperModelFolder?.path ?? "(none — will download on first run)")")
    do {
        _ = try c.validated()
        print("  validation:       OK")
        exit(0)
    } catch {
        // Nonzero exit so scripted install checks can gate on this (matches
        // --check-model's 0/1 convention).
        print("  validation:       FAILED — \(error.localizedDescription)")
        exit(1)
    }
}

// Entry point for the menu-bar application. Using an explicit `main.swift` (no
// `@main`) keeps the AppKit run-loop bootstrap simple and lets the delegate own
// all wiring. `setActivationPolicy(.accessory)` is also set in the delegate.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
