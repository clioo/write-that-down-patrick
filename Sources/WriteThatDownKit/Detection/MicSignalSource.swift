import Foundation

/// Contract for the Call Detector's microphone-in-use signal source (§3.1.1, §5.1).
///
/// The source polls the OS "microphone in use by any process" signal on a fixed
/// cadence (`poll_interval_ms`) and reports a rich activity sample on every tick
/// via `onSample`. Reporting every tick (not just on edges) lets the orchestrator
/// use the poll cadence to also drive inactivity checks, with no separate timer.
public protocol MicSignalSource: AnyObject, Sendable {
    /// Begins polling. The closure may run on a background queue.
    func start(onSample: @escaping @Sendable (MicActivitySample) -> Void)

    /// Stops polling. Safe to call multiple times.
    func stop()
}
