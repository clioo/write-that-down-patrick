import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation
import WriteThatDownKit

@MainActor
final class GlobalDictationController {
    struct Snapshot: Sendable {
        let isEnabled: Bool
        let accessibilityGranted: Bool
        let phase: LocalDictationPhase
        let targetApplicationName: String?
        let engineName: String
        let errorMessage: String?
    }

    private struct TextTarget {
        let pid: pid_t
        let applicationName: String
        let element: AXUIElement
    }

    private struct ActiveResources {
        let microphone: MicrophoneCapturer
        let continuation: AsyncStream<AudioBuffer>.Continuation
        let processingTask: Task<Error?, Never>
        let session: LocalDictationSession
        let target: TextTarget
        let engineName: String
    }

    static let enabledDefaultsKey = "globalLocalDictationEnabled"

    private let config: AppConfiguration
    private let selectedOption: @Sendable () -> TranscriptionEngineOption
    private let makeEngine: @Sendable (EngineKind) -> any TranscriptionEngine
    private let meetingIsActive: @Sendable () async -> Bool
    private let onSnapshot: @MainActor (Snapshot) -> Void

    private var isEnabled = false
    private var phase: LocalDictationPhase = .idle
    private var targetApplicationName: String?
    private var engineName = ""
    private var errorMessage: String?
    private var startTask: Task<Void, Never>?
    private var meetingGuardTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var resources: ActiveResources?

    private lazy var hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey)) { [weak self] in
        self?.toggle()
    }

    init(
        config: AppConfiguration,
        selectedOption: @escaping @Sendable () -> TranscriptionEngineOption,
        makeEngine: @escaping @Sendable (EngineKind) -> any TranscriptionEngine,
        meetingIsActive: @escaping @Sendable () async -> Bool,
        onSnapshot: @escaping @MainActor (Snapshot) -> Void
    ) {
        self.config = config
        self.selectedOption = selectedOption
        self.makeEngine = makeEngine
        self.meetingIsActive = meetingIsActive
        self.onSnapshot = onSnapshot
    }

    func install(enabled: Bool) {
        setEnabled(enabled, promptForAccessibility: false)
    }

    func setEnabled(_ enabled: Bool, promptForAccessibility: Bool = true) {
        resetTask?.cancel()
        errorMessage = nil
        if enabled {
            do {
                try hotKey.register()
                isEnabled = true
                UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
                if promptForAccessibility && !Self.accessibilityGranted(prompt: false) {
                    _ = Self.accessibilityGranted(prompt: true)
                }
            } catch {
                isEnabled = false
                phase = .failed
                errorMessage = error.localizedDescription
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            }
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            hotKey.unregister()
            cancelCurrentDictation()
        }
        publish()
    }

    func requestAccessibilityPermission() {
        guard isEnabled else { return }
        _ = Self.accessibilityGranted(prompt: true)
        publish()
    }

    func refreshAccessibilityStatus() {
        publish()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func shutdown() {
        hotKey.unregister()
        cancelCurrentDictation()
    }

    private func toggle() {
        guard isEnabled else { return }
        switch phase {
        case .idle, .inserted, .failed:
            beginDictation()
        case .loading:
            cancelCurrentDictation()
        case .listening:
            finishDictation()
        case .transcribing:
            break
        }
    }

    private func beginDictation() {
        resetTask?.cancel()
        errorMessage = nil

        guard Self.accessibilityGranted(prompt: false) else {
            fail(AppLanguage.current.text(
                "Allow Accessibility access in System Settings before using ⌘E.",
                spanish: "Permite acceso de Accesibilidad en Configuración del Sistema antes de usar ⌘E."
            ))
            return
        }
        guard let target = Self.captureFocusedTextTarget() else {
            fail(AppLanguage.current.text(
                "Select a writable text field in another app, then press ⌘E.",
                spanish: "Selecciona un campo de texto editable en otra app y presiona ⌘E."
            ))
            return
        }

        let option = selectedOption()
        phase = .loading
        targetApplicationName = target.applicationName
        engineName = option.title
        publish()

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            if await meetingIsActive() {
                fail(AppLanguage.current.text(
                    "Finish the active meeting recording before starting dictation.",
                    spanish: "Termina la grabación activa antes de iniciar el dictado."
                ))
                return
            }

            let engine = makeEngine(option.engine)
            let session = LocalDictationSession(
                engine: engine,
                configuration: EngineConfig(
                    language: config.language,
                    sampleRate: config.sampleRate,
                    windowSeconds: config.transcriptionWindowSeconds,
                    model: option.model,
                    modelFolder: option.modelFolder
                )
            )
            do {
                try await session.start()
                try Task.checkCancellation()

                let pair = AsyncStream<AudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(80))
                let processingTask = Task { () -> Error? in
                    do {
                        for await buffer in pair.stream {
                            try await session.ingest(buffer)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
                let microphone = MicrophoneCapturer(targetSampleRate: config.sampleRate)
                let sampleRate = config.sampleRate
                do {
                    try microphone.start { samples in
                        pair.continuation.yield(AudioBuffer(samples: samples, sampleRate: sampleRate))
                    }
                } catch {
                    pair.continuation.finish()
                    _ = await processingTask.value
                    _ = try? await session.finish()
                    throw error
                }
                try Task.checkCancellation()

                resources = ActiveResources(
                    microphone: microphone,
                    continuation: pair.continuation,
                    processingTask: processingTask,
                    session: session,
                    target: target,
                    engineName: option.title
                )
                startTask = nil
                phase = .listening
                publish()
                monitorForMeetingStart()
            } catch is CancellationError {
                _ = try? await session.finish()
                if phase == .loading {
                    phase = .idle
                    targetApplicationName = nil
                    publish()
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func finishDictation() {
        guard let resources else { return }
        meetingGuardTask?.cancel()
        meetingGuardTask = nil
        self.resources = nil
        resources.microphone.stop()
        resources.continuation.finish()
        phase = .transcribing
        publish()

        startTask = Task { [weak self] in
            guard let self else { return }
            if let processingError = await resources.processingTask.value {
                _ = try? await resources.session.finish()
                fail(processingError.localizedDescription)
                return
            }
            do {
                let text = try await resources.session.finish()
                try Task.checkCancellation()
                guard !text.isEmpty else {
                    fail(AppLanguage.current.text(
                        "No speech was detected.",
                        spanish: "No se detectó voz."
                    ))
                    return
                }
                guard Self.insert(text, into: resources.target) else {
                    fail(AppLanguage.current.text(
                        "The selected app did not accept the dictated text.",
                        spanish: "La app seleccionada no aceptó el texto dictado."
                    ))
                    return
                }
                startTask = nil
                phase = .inserted
                errorMessage = nil
                publish()
                scheduleIdleReset(after: 1.4)
            } catch is CancellationError {
                phase = .idle
                publish()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelCurrentDictation() {
        startTask?.cancel()
        startTask = nil
        meetingGuardTask?.cancel()
        meetingGuardTask = nil
        if let resources {
            resources.microphone.stop()
            resources.continuation.finish()
            resources.processingTask.cancel()
            Task { _ = try? await resources.session.finish() }
        }
        resources = nil
        phase = .idle
        targetApplicationName = nil
        errorMessage = nil
        publish()
    }

    private func fail(_ message: String) {
        startTask = nil
        meetingGuardTask?.cancel()
        meetingGuardTask = nil
        resources?.microphone.stop()
        resources?.continuation.finish()
        resources = nil
        phase = .failed
        errorMessage = message
        publish()
        scheduleIdleReset(after: 3)
    }

    private func monitorForMeetingStart() {
        meetingGuardTask?.cancel()
        meetingGuardTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, phase == .listening {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, phase == .listening else { return }
                if await meetingIsActive() {
                    cancelCurrentDictation()
                    fail(AppLanguage.current.text(
                        "Dictation stopped because a meeting recording started.",
                        spanish: "El dictado se detuvo porque inició una grabación."
                    ))
                    return
                }
            }
        }
    }

    private func scheduleIdleReset(after seconds: TimeInterval) {
        resetTask?.cancel()
        let expectedPhase = phase
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, phase == expectedPhase else { return }
            phase = .idle
            targetApplicationName = nil
            errorMessage = nil
            publish()
        }
    }

    private func publish() {
        onSnapshot(Snapshot(
            isEnabled: isEnabled,
            accessibilityGranted: Self.accessibilityGranted(prompt: false),
            phase: phase,
            targetApplicationName: targetApplicationName,
            engineName: engineName,
            errorMessage: errorMessage
        ))
    }

    private static func accessibilityGranted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func captureFocusedTextTarget() -> TextTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue
        else { return nil }

        let focused = focusedValue as! AXUIElement
        var selectedTextSettable = DarwinBoolean(false)
        let selectedStatus = AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )
        guard selectedStatus == .success, selectedTextSettable.boolValue else { return nil }
        return TextTarget(
            pid: application.processIdentifier,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "app",
            element: focused
        )
    }

    private static func insert(_ text: String, into target: TextTarget) -> Bool {
        let direct = AXUIElementSetAttributeValue(
            target.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if direct == .success { return true }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 32) {
            let end = min(start + 32, utf16.count)
            let chunk = Array(utf16[start..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            down.postToPid(target.pid)
            up.postToPid(target.pid)
        }
        return true
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .eventHandler(status): return "Could not install the global shortcut handler (\(status))."
        case let .registration(status): return "⌘E is already reserved by another global shortcut (\(status))."
        }
    }
}

@MainActor
private final class GlobalHotKey: @unchecked Sendable {
    private static let signature: OSType = 0x57544444 // WTDD
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @MainActor () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    func register() throws {
        guard hotKey == nil else { return }
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in owner.fire() }
                    return noErr
                },
                1,
                &type,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
            guard status == noErr else { throw GlobalHotKeyError.eventHandler(status) }
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw GlobalHotKeyError.registration(status)
        }
        hotKey = reference
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func fire() { action() }
}
