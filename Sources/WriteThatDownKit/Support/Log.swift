import Foundation
import OSLog

/// Lightweight logging facade over `os.Logger`. Centralizes subsystem/category
/// so every component logs consistently. No data leaves the device (§12).
public enum Log {
    public static let subsystem = "com.writethatdown.app"

    public static let detection = Logger(subsystem: subsystem, category: "detection")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let metrics = Logger(subsystem: subsystem, category: "metrics")
    public static let orchestrator = Logger(subsystem: subsystem, category: "orchestrator")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let presentation = Logger(subsystem: subsystem, category: "presentation")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
