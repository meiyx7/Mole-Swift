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

    private var task: Task<Void, Never>?

    var succeeded: Bool { exitCode == 0 }
    var hasOutput: Bool { !lines.isEmpty }

    func run(_ work: @escaping (@escaping (CLIOutputLine) -> Void) async throws -> Int32) {
        cancel()
        lines.removeAll()
        exitCode = nil
        error = nil
        isRunning = true
        task = Task { @MainActor in
            do {
                let code = try await work { [weak self] line in
                    Task { @MainActor in self?.lines.append(line) }
                }
                self.exitCode = code
            } catch {
                self.error = error.localizedDescription
                self.exitCode = -1
            }
            self.isRunning = false
        }
    }

    /// Awaits the full run to completion and returns the exit code, while still
    /// streaming lines to `lines` so the console view updates live. Use this
    /// when a caller needs to react to the result (e.g. a success/failure
    /// banner) instead of the fire-and-forget `run`.
    @discardableResult
    func runAwaited(_ work: @escaping (@escaping (CLIOutputLine) -> Void) async throws -> Int32) async -> Int32 {
        cancel()
        lines.removeAll()
        exitCode = nil
        error = nil
        isRunning = true
        do {
            let code = try await work { [weak self] line in
                Task { @MainActor in self?.lines.append(line) }
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
            exitCode = -1
        }
    }
}

/// Prominent gradient button used for primary actions (Run, Clean, etc.).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundColor(.white)
            .background(
                (tint.map { LinearGradient(colors: [$0, $0.opacity(0.75)],
                                           startPoint: .top, endPoint: .bottom) } ?? Theme.brand)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Standard content padding shared by every feature screen.
    func featurePadding() -> some View {
        padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 22)
    }
}
