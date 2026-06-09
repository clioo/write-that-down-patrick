import AppKit

// Headless self-test: `WriteThatDown --check-model <folder>` loads the WhisperKit
// model from a local folder and runs offline inference, then exits — no UI.
if let idx = CommandLine.arguments.firstIndex(of: "--check-model"),
   idx + 1 < CommandLine.arguments.count {
    EngineSelfTest.run(modelFolder: CommandLine.arguments[idx + 1])
}

// Print the resolved configuration (defaults < config file < env vars) and exit.
if CommandLine.arguments.contains("--print-config") {
    let c = AppEnvironment.loadConfiguration()
    print("Resolved configuration:")
    print("  config file:   \(AppEnvironment.configFileURL.path)")
    print("  engine:        \(c.engine.rawValue)")
    print("  language:      \(c.language)")
    print("  output_dir:    \(c.outputDir.path)")
    print("  inactivity_ms: \(c.inactivityTimeoutMs)")
    print("  poll_ms:       \(c.pollIntervalMs)")
    print("  whisper_model: \(c.whisperModel)")
    print("  model_folder:  \(c.whisperModelFolder?.path ?? "(none — will download on first run)")")
    if let validated = try? c.validated() {
        print("  validation:    OK")
        _ = validated
    } else {
        print("  validation:    FAILED")
    }
    exit(0)
}

// Entry point for the menu-bar application. Using an explicit `main.swift` (no
// `@main`) keeps the AppKit run-loop bootstrap simple and lets the delegate own
// all wiring. `setActivationPolicy(.accessory)` is also set in the delegate.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
