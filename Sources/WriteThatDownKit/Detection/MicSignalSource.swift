import Foundation

/// Contract for the Call Detector's microphone-in-use signal source (§3.1.1, §5.1).
///
/// The source polls the OS "microphone in use by any process" signal on a fixed
/// cadence (`poll_interval_ms`) and reports the current boolean on every tick via
/// `onSample`. Reporting every tick (not just on edges) lets the orchestrator use
/// the poll cadence to also drive inactivity checks, with no separate timer.
///
/// Detection MUST NOT depend on identifying a specific application (§5.1).
public protocol MicSignalSource: AnyObject, Sendable {
    /// Begins polling. `onSample` is called once per poll with the current
    /// mic-in-use boolean. The closure may run on a background queue.
    func start(onSample: @escaping @Sendable (Bool) -> Void)

    /// Stops polling. Safe to call multiple times.
    func stop()
}
