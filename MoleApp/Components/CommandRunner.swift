import SwiftUI

/// Drives a streaming CLI command, exposing its live output to SwiftUI.
///
/// The cleanup-style screens (Clean, Optimize, Purge, Installer, Uninstall,
/// Update) all share the same shape: preview → confirm → run with streaming
/// output. This object encapsulates that lifecycle.
@MainActor
final class CommandRunner: ObservableObject {
    @Published var lines: [CLIOutputLine] = []
    @Published var isRunning = false
    @Published var exitCode: Int32? = nil
    @Published var error: String? = nil
    @Published var wasCancelled = false

    /// Maximum lines retained in memory. Excess lines are dropped from the
    /// head to prevent unbounded growth during long-running commands.
    let maxLines = 3000

    private var task: Task<Void, Never>?

    var succeeded: Bool { exitCode == 0 && !wasCancelled }
    var hasOutput: Bool { !lines.isEmpty }

    func run(_ work: @escaping (@escaping (CLIOutputLine) -> Void) async throws -> Int32) {
        cancel()
        lines.removeAll()
        exitCode = nil
        error = nil
        wasCancelled = false
        isRunning = true
        task = Task { @MainActor in
            do {
                let code = try await work { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        self.lines.append(line)
                        // Bound memory: drop old lines beyond the cap.
                        if self.lines.count > self.maxLines {
                            self.lines.removeFirst(self.lines.count - self.maxLines)
                        }
                    }
                }
                self.exitCode = code
            } catch {
                self.error = error.localizedDescription
                self.exitCode = -1
            }
            self.isRunning = false
        }
    }

    /// Awaitable variant of `run` for callers that need to react to the
    /// exit code after completion (e.g. showing a success/failure banner).
    @discardableResult
    func runAwaited(_ work: @escaping (@escaping (CLIOutputLine) -> Void) async throws -> Int32) async -> Int32 {
        cancel()
        lines.removeAll()
        exitCode = nil
        error = nil
        wasCancelled = false
        isRunning = true
        do {
            let code = try await work { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.lines.append(line)
                    if self.lines.count > self.maxLines {
                        self.lines.removeFirst(self.lines.count - self.maxLines)
                    }
                }
            }
            self.exitCode = code
        } catch {
            self.error = error.localizedDescription
            self.exitCode = -1
        }
        self.isRunning = false
        return self.exitCode ?? -1
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning {
            isRunning = false
            wasCancelled = true
            exitCode = -1
            // Clear stale error so the UI shows "cancelled" not a prior error.
            error = nil
        }
    }
}

/// Prominent button used for primary actions (Run, Clean, etc.).
///
/// Pass `disabled: true` to render a visibly deactivated state (flat gray,
/// reduced opacity) instead of the brand gradient. This is used by the
/// preview-gated cleanup screens so users can clearly see when the action
/// is unavailable.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundColor(.white)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(disabled ? 0.6 : (configuration.isPressed ? 0.8 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var background: some View {
        if disabled {
            return AnyView(Color.gray.opacity(0.45))
        }
        if let tint {
            return AnyView(LinearGradient(colors: [tint, tint.opacity(0.75)],
                                          startPoint: .top, endPoint: .bottom))
        }
        return AnyView(Theme.brand)
    }
}

extension View {
    /// Standard content padding shared by every feature screen.
    func featurePadding() -> some View {
        padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 22)
    }
}
