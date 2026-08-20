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
        let shortcut: DictationShortcut
    }

    private struct TextTarget {
        let pid: pid_t
        let applicationName: String
        let element: AXUIElement
    }

    private struct ActiveResources {
        let id: UUID
        let microphone: MicrophoneCapturer
        let continuation: AsyncStream<AudioBuffer>.Continuation
        let processingTask: Task<Error?, Never>
        let session: LocalDictationSession
        let target: TextTarget
    }

    private enum InsertionMethod: String {
        case selectedText
        case valueAndRange
        case unicodeEvents
    }

    static let enabledDefaultsKey = "globalLocalDictationEnabled"
    static let shortcutDefaultsKey = "globalLocalDictationShortcut"

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
    private var setupTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var meetingGuardTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var resources: ActiveResources?
    private var hotKey: GlobalHotKey?
    private var shortcut: DictationShortcut
    private var isShortcutHeld = false
    private var finishRequested = false
    private var generation = UUID()

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
        self.shortcut = Self.loadShortcut()
    }

    func install(enabled: Bool) {
        setEnabled(enabled, promptForAccessibility: false)
    }

    func setEnabled(_ enabled: Bool, promptForAccessibility: Bool = true) {
        resetTask?.cancel()
        errorMessage = nil
        if enabled {
            do {
                try registerHotKey(for: shortcut)
                isEnabled = true
                UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
                if promptForAccessibility && !Self.accessibilityGranted(prompt: false) {
                    _ = Self.accessibilityGranted(prompt: true)
                }
                Log.dictation.notice("Global dictation enabled with shortcut \(self.shortcut.displayName, privacy: .public).")
            } catch {
                isEnabled = false
                phase = .failed
                errorMessage = error.localizedDescription
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                Log.dictation.error("Could not enable global dictation: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            hotKey?.unregister()
            hotKey = nil
            cancelCurrentDictation()
            Log.dictation.notice("Global dictation disabled.")
        }
        publish()
    }

    func setShortcut(_ requestedShortcut: DictationShortcut) {
        guard requestedShortcut.isValid else {
            errorMessage = AppLanguage.current.text(
                "Choose a key together with Command, Option, Control, or Shift.",
                spanish: "Elige una tecla junto con Command, Option, Control o Shift."
            )
            publish()
            return
        }
        guard requestedShortcut != shortcut else { return }
        guard !phase.isBusy else {
            errorMessage = AppLanguage.current.text(
                "Finish the current dictation before changing the shortcut.",
                spanish: "Termina el dictado actual antes de cambiar el atajo."
            )
            publish()
            return
        }

        let previous = shortcut
        if isEnabled {
            hotKey?.unregister()
            hotKey = nil
            do {
                try registerHotKey(for: requestedShortcut)
            } catch {
                try? registerHotKey(for: previous)
                errorMessage = AppLanguage.current.text(
                    "That shortcut is unavailable. Your previous shortcut is still active.",
                    spanish: "Ese atajo no está disponible. Tu atajo anterior sigue activo."
                )
                Log.dictation.error("Shortcut registration failed for \(requestedShortcut.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                publish()
                return
            }
        }

        shortcut = requestedShortcut
        Self.persistShortcut(requestedShortcut)
        errorMessage = nil
        Log.dictation.notice("Global dictation shortcut changed to \(requestedShortcut.displayName, privacy: .public).")
        publish()
    }

    func setShortcutRecording(_ recording: Bool) {
        guard isEnabled, !phase.isBusy else { return }
        if recording {
            hotKey?.unregister()
            hotKey = nil
        } else if hotKey == nil {
            do {
                try registerHotKey(for: shortcut)
            } catch {
                errorMessage = error.localizedDescription
                Log.dictation.error("Could not restore the global shortcut: \(error.localizedDescription, privacy: .public)")
                publish()
            }
        }
    }

    func requestAccessibilityPermission() {
        guard isEnabled else { return }
        _ = Self.accessibilityGranted(prompt: true)
        publish()
    }

    func refreshAccessibilityStatus() { publish() }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func shutdown() {
        hotKey?.unregister()
        hotKey = nil
        cancelCurrentDictation()
    }

    private func shortcutPressed() {
        guard isEnabled, !isShortcutHeld else { return }
        guard !phase.isBusy else { return }
        isShortcutHeld = true
        Log.dictation.notice("Dictation shortcut pressed.")
        beginDictation()
    }

    private func shortcutReleased() {
        guard isShortcutHeld else { return }
        isShortcutHeld = false
        Log.dictation.notice("Dictation shortcut released (phase=\(self.phase.rawValue, privacy: .public)).")
        guard phase == .loading || phase == .listening else { return }
        finishRequested = true
        phase = .transcribing
        publish()
        if resources != nil { finishDictation() }
    }

    private func beginDictation() {
        resetTask?.cancel()
        errorMessage = nil
        finishRequested = false
        generation = UUID()
        let requestID = generation

        guard Self.accessibilityGranted(prompt: false) else {
            isShortcutHeld = false
            fail(AppLanguage.current.text(
                "Allow Accessibility access in System Settings before using \(shortcut.displayName).",
                spanish: "Permite acceso de Accesibilidad en Configuración del Sistema antes de usar \(shortcut.displayName)."
            ))
            return
        }
        guard let target = Self.captureFocusedTextTarget() else {
            isShortcutHeld = false
            fail(AppLanguage.current.text(
                "Select a writable text field in another app, then hold \(shortcut.displayName).",
                spanish: "Selecciona un campo de texto editable en otra app y mantén presionado \(shortcut.displayName)."
            ))
            return
        }

        let option = selectedOption()
        phase = .loading
        targetApplicationName = target.applicationName
        engineName = option.title
        publish()
        Log.dictation.notice("Starting local dictation for target=\(target.applicationName, privacy: .public), engine=\(option.title, privacy: .public).")

        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            if await meetingIsActive() {
                isShortcutHeld = false
                fail(AppLanguage.current.text(
                    "Finish the active meeting recording before starting dictation.",
                    spanish: "Termina la grabación activa antes de iniciar el dictado."
                ))
                return
            }

            do {
                try Task.checkCancellation()
                guard generation == requestID else { return }

                let session = LocalDictationSession(
                    engine: makeEngine(option.engine),
                    configuration: EngineConfig(
                        language: config.language,
                        sampleRate: config.sampleRate,
                        windowSeconds: config.transcriptionWindowSeconds,
                        model: option.model,
                        modelFolder: option.modelFolder
                    )
                )

                // Capture immediately. This keeps speech while a cold local model
                // starts, including when the shortcut is released during loading.
                let pair = AsyncStream<AudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(1_200))
                let microphone = MicrophoneCapturer(targetSampleRate: config.sampleRate)
                let sampleRate = config.sampleRate
                do {
                    try microphone.start { samples in
                        pair.continuation.yield(AudioBuffer(samples: samples, sampleRate: sampleRate))
                    }
                } catch {
                    pair.continuation.finish()
                    throw error
                }

                let processingTask = Task { [weak self] () -> Error? in
                    do {
                        try await session.start()
                        self?.engineDidBecomeReady(requestID)
                        for await buffer in pair.stream {
                            try Task.checkCancellation()
                            try await session.ingest(buffer)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }

                resources = ActiveResources(
                    id: requestID,
                    microphone: microphone,
                    continuation: pair.continuation,
                    processingTask: processingTask,
                    session: session,
                    target: target
                )
                setupTask = nil
                monitorProcessingFailure(processingTask, requestID: requestID)

                if finishRequested || !isShortcutHeld {
                    finishRequested = true
                    phase = .transcribing
                    publish()
                    finishDictation()
                } else {
                    monitorForMeetingStart()
                }
            } catch is CancellationError {
                if generation == requestID, phase == .loading {
                    phase = .idle
                    targetApplicationName = nil
                    publish()
                }
            } catch {
                if generation == requestID {
                    isShortcutHeld = false
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func engineDidBecomeReady(_ requestID: UUID) {
        guard generation == requestID, resources?.id == requestID else { return }
        Log.dictation.notice("Local dictation engine is ready.")
        if isShortcutHeld, !finishRequested {
            phase = .listening
            publish()
            monitorForMeetingStart()
        }
    }

    private func monitorProcessingFailure(_ task: Task<Error?, Never>, requestID: UUID) {
        Task { [weak self] in
            guard let error = await task.value else { return }
            guard let self, generation == requestID, resources?.id == requestID else { return }
            if phase != .transcribing {
                isShortcutHeld = false
                Log.dictation.error("Dictation processing failed: \(error.localizedDescription, privacy: .public)")
                fail(error.localizedDescription)
            }
        }
    }

    private func finishDictation() {
        guard let resources, completionTask == nil else { return }
        meetingGuardTask?.cancel()
        meetingGuardTask = nil
        self.resources = nil
        resources.microphone.stop()
        resources.continuation.finish()
        phase = .transcribing
        publish()

        completionTask = Task { [weak self] in
            guard let self else { return }
            if let processingError = await resources.processingTask.value {
                _ = try? await resources.session.finish()
                completionTask = nil
                fail(processingError.localizedDescription)
                return
            }
            do {
                let text = try await resources.session.finish()
                try Task.checkCancellation()
                guard !text.isEmpty else {
                    completionTask = nil
                    Log.dictation.notice("Dictation finished without recognized speech.")
                    fail(AppLanguage.current.text("No speech was detected.", spanish: "No se detectó voz."))
                    return
                }
                guard let insertionMethod = Self.insert(text, into: resources.target) else {
                    completionTask = nil
                    Log.dictation.error("The target app rejected every dictation insertion method.")
                    fail(AppLanguage.current.text(
                        "The selected app did not accept the dictated text.",
                        spanish: "La app seleccionada no aceptó el texto dictado."
                    ))
                    return
                }
                completionTask = nil
                finishRequested = false
                phase = .inserted
                errorMessage = nil
                Log.dictation.notice("Dictation inserted using \(insertionMethod.rawValue, privacy: .public).")
                publish()
                scheduleIdleReset(after: 1.4)
            } catch is CancellationError {
                completionTask = nil
                phase = .idle
                publish()
            } catch {
                completionTask = nil
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelCurrentDictation() {
        generation = UUID()
        isShortcutHeld = false
        finishRequested = false
        setupTask?.cancel()
        setupTask = nil
        completionTask?.cancel()
        completionTask = nil
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
        setupTask = nil
        meetingGuardTask?.cancel()
        meetingGuardTask = nil
        if let resources {
            resources.microphone.stop()
            resources.continuation.finish()
            resources.processingTask.cancel()
            Task { _ = try? await resources.session.finish() }
        }
        resources = nil
        finishRequested = false
        phase = .failed
        errorMessage = message
        Log.dictation.error("Dictation stopped: \(message, privacy: .public)")
        publish()
        scheduleIdleReset(after: 3)
    }

    private func monitorForMeetingStart() {
        meetingGuardTask?.cancel()
        meetingGuardTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, phase == .loading || phase == .listening {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, phase == .loading || phase == .listening else { return }
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
            errorMessage: errorMessage,
            shortcut: shortcut
        ))
    }

    private func registerHotKey(for shortcut: DictationShortcut) throws {
        let hotKey = GlobalHotKey(
            keyCode: shortcut.keyCode,
            modifiers: Self.carbonModifiers(shortcut.modifiers),
            displayName: shortcut.displayName,
            pressed: { [weak self] in self?.shortcutPressed() },
            released: { [weak self] in self?.shortcutReleased() }
        )
        try hotKey.register()
        self.hotKey = hotKey
    }

    private static func carbonModifiers(_ modifiers: DictationShortcutModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private static func loadShortcut() -> DictationShortcut {
        guard let data = UserDefaults.standard.data(forKey: shortcutDefaultsKey),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              value.isValid else { return .defaultValue }
        return value
    }

    private static func persistShortcut(_ shortcut: DictationShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: shortcutDefaultsKey)
    }

    private static func accessibilityGranted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func captureFocusedTextTarget() -> TextTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue else { return nil }
        let focused = focusedValue as! AXUIElement
        guard isWritable(focused) else { return nil }
        return TextTarget(
            pid: application.processIdentifier,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "app",
            element: focused
        )
    }

    private static func isWritable(_ element: AXUIElement) -> Bool {
        for attribute in [kAXSelectedTextAttribute, kAXValueAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue { return true }
        }
        return false
    }

    private static func insert(_ text: String, into target: TextTarget) -> InsertionMethod? {
        if AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return .selectedText
        }
        if replaceSelectedRange(in: target.element, with: text) { return .valueAndRange }

        _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return nil }
        for start in stride(from: 0, to: utf16.count, by: 32) {
            let end = min(start + 32, utf16.count)
            let chunk = Array(utf16[start..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            down.postToPid(target.pid)
            up.postToPid(target.pid)
        }
        return .unicodeEvents
    }

    private static func replaceSelectedRange(in element: AXUIElement, with text: String) -> Bool {
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return false }

        let axRange = rangeRef as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location + range.length <= (value as NSString).length else { return false }

        let updatedValue = (value as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: text
        )
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success else {
            return false
        }
        var updatedRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let updatedRangeValue = AXValueCreate(.cfRange, &updatedRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, updatedRangeValue)
        }
        return true
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case let .eventHandler(status):
            return "Could not install the global shortcut handler (\(status))."
        case let .registration(status, displayName):
            return "\(displayName) is already reserved by another global shortcut (\(status))."
        }
    }
}

@MainActor
private final class GlobalHotKey: @unchecked Sendable {
    private static let signature: OSType = 0x57544444 // WTDD
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let displayName: String
    private let pressed: @MainActor () -> Void
    private let released: @MainActor () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        displayName: String,
        pressed: @escaping @MainActor () -> Void,
        released: @escaping @MainActor () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
        self.pressed = pressed
        self.released = released
    }

    func register() throws {
        guard hotKey == nil else { return }
        if eventHandler == nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    let kind = GetEventKind(event)
                    Task { @MainActor in owner.fire(kind: kind) }
                    return noErr
                },
                types.count,
                &types,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
            guard status == noErr else { throw GlobalHotKeyError.eventHandler(status) }
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw GlobalHotKeyError.registration(status, displayName) }
        hotKey = reference
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func fire(kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) { pressed() }
        else if kind == UInt32(kEventHotKeyReleased) { released() }
    }
}
