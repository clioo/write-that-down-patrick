import Foundation
import WriteThatDownKit

final class EngineSelectionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedOption: TranscriptionEngineOption

    init(selected: TranscriptionEngineOption) {
        self.selectedOption = selected
    }

    var current: TranscriptionEngineOption {
        get {
            lock.lock()
            defer { lock.unlock() }
            return selectedOption
        }
        set {
            lock.lock()
            selectedOption = newValue
            lock.unlock()
        }
    }
}
