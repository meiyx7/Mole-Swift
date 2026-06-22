import SwiftUI

/// Shared phase enum for all cleanup-style screens (Clean, Optimize, Purge,
/// Installer). Previously each view defined its own private Phase enum with
/// slightly different names (`previewing`/`previewed` vs `scanning`/`scanned`),
/// which made the step guides, status pills, and action bars inconsistent.
/// This shared enum aligns all cleanup screens on the same vocabulary.
enum CleanupPhase: Equatable {
    /// Initial state, before any scan has been started.
    case idle
    /// Scan / dry-run preview in progress.
    case scanning
    /// Scan complete, results are shown for review.
    case scanned
    /// Execution (real cleanup) in progress.
    case running
    /// Execution completed successfully.
    case done
    /// Scan or execution failed.
    case error

    /// True for all phases that come after the scan completes (scanned,
    /// running, done, error). Used by step guides to mark step 1 as done.
    var isAfterScan: Bool {
        self == .scanned || self == .running || self == .done || self == .error
    }

    /// True when the phase represents an active operation (scanning or
    /// running). Used by status pills and to disable interactive controls.
    var isBusy: Bool {
        self == .scanning || self == .running
    }

    /// True when the phase represents a terminal state (done or error).
    var isTerminal: Bool {
        self == .done || self == .error
    }
}

/// Shared ObservableObject that encapsulates the common state and transitions
/// for all cleanup-style screens. Each screen (CleanupScreen, PurgeView,
/// PurgeInteractiveView) previously managed its own `@State private var phase`
/// plus scattered progress/error/result state. This model centralizes:
///
/// - `phase`: the current lifecycle phase
/// - `progressDone` / `progressTotal`: per-item progress for running state
/// - `error`: error message for the error state
/// - `resultMessage`: success/partial-failure message for the done state
///
/// Screens that need additional state (e.g. CleanupScreen's `previewSnapshot`
/// or PurgeView's `selectedIDs`) keep that in their own `@State`; only the
/// common phase/progress/result state lives here.
@MainActor
final class CleanupPhaseModel: ObservableObject {
    @Published var phase: CleanupPhase = .idle
    @Published var progressDone: Int = 0
    @Published var progressTotal: Int = 0
    @Published var error: String?
    @Published var resultMessage: String?

    /// Reset to the initial idle state, clearing all progress and results.
    func resetToIdle() {
        phase = .idle
        progressDone = 0
        progressTotal = 0
        error = nil
        resultMessage = nil
    }

    /// Transition to the scanning phase, clearing any prior error/result.
    func startScanning() {
        phase = .scanning
        error = nil
        resultMessage = nil
    }

    /// Transition to the scanned phase after a successful scan.
    func finishScanning() {
        phase = .scanned
    }

    /// Transition to the error phase with an optional error message.
    func fail(_ message: String?) {
        phase = .error
        error = message
    }

    /// Transition to the running phase, setting up progress tracking.
    func startRunning(total: Int) {
        phase = .running
        progressDone = 0
        progressTotal = total
    }

    /// Update progress during the running phase.
    func updateProgress(done: Int) {
        progressDone = done
    }

    /// Transition to the done phase with a result message.
    func finish(message: String?) {
        phase = .done
        resultMessage = message
    }
}
