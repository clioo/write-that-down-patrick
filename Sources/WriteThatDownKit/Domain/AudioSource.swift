import Foundation

/// Origin of captured audio (§4.1.4).
public struct AudioSource: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case system
        case microphone
    }

    public var kind: Kind
    public var active: Bool

    public init(kind: Kind, active: Bool) {
        self.kind = kind
        self.active = active
    }
}
