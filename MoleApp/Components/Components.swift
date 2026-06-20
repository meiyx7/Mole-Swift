import SwiftUI

/// Centralised palette and gradients so every screen shares Mole's identity.
enum Theme {
    static let accent = Color("AccentColor")

    static let good = Color.green
    static let warn = Color.orange
    static let critical = Color.red
    static let neutral = Color.secondary

    static func color(for tone: StatusTone) -> Color {
        switch tone {
        case .good: return good
        case .warn: return warn
        case .critical: return critical
        case .neutral: return neutral
        }
    }

    static func gradient(for tone: StatusTone) -> LinearGradient {
        let base = color(for: tone)
        return LinearGradient(
            colors: [base.opacity(0.9), base.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Brand gradient used on hero headers and primary buttons.
    static let brand = LinearGradient(
        colors: [Color(red: 0.247, green: 0.686, blue: 0.388),
                 Color(red: 0.18, green: 0.55, blue: 0.30)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// A rounded, material-backed card used to group content.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

/// Page header with an icon, title, subtitle, and an optional trailing slot.
struct FeatureHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.brand)
                    .frame(width: 44, height: 44)
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.bottom, 4)
    }
}

/// A compact key/value stat tile.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String? = nil
    var tone: StatusTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.color(for: tone))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A single step indicator dot with a number or checkmark, plus a label.
/// Shared by CleanupScreen and InstallerView step guides.
struct StepDot: View {
    let n: Int
    let label: String
    var active: Bool = false
    var done: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? Theme.color(for: .good) : (active ? Theme.accent : Color.secondary.opacity(0.3)))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                }
            }
            Text(label).font(.system(size: 11, weight: done || active ? .semibold : .regular))
                .foregroundColor(done || active ? .primary : .secondary)
        }
    }
}

/// A connector line between step dots, coloured by completion.
struct StepConnector: View {
    var active: Bool = false

    var body: some View {
        Rectangle()
            .fill(active ? Theme.color(for: .good) : Color.secondary.opacity(0.25))
            .frame(height: 2)
            .frame(maxWidth: 60)
    }
}

/// A linear progress bar with a tone-coloured fill.
struct ProgressBar: View {
    let value: Double
    var tone: StatusTone = .neutral
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Theme.color(for: tone))
                    .frame(width: max(0, min(1, value / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// A circular gauge showing a percentage with a label.
struct RingGauge: View {
    let value: Double
    let label: String
    var tone: StatusTone = .neutral
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value / 100)))
                .stroke(Theme.color(for: tone), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            VStack(spacing: 0) {
                Text(ByteFormatter.percentInt(value) == 0 && value > 0 ? "<1" : "\(ByteFormatter.percentInt(value))")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                Text("%")
                    .font(.system(size: size * 0.13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(label): \(ByteFormatter.percent(value))")
    }
}

/// Empty-state placeholder used when there is nothing to show yet.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var action: (label: String, perform: (() -> Void))? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Color.gray.opacity(0.5))
            VStack(spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.label, action: action.perform)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Centered loading indicator with a label.
struct LoadingView: View {
    var title: String = "Working…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the Mole CLI is not installed.
struct CLIUnavailableView: View {
    @EnvironmentObject private var loc: Localization
    @State private var copied = false

    var body: some View {
        EmptyStateView(
            systemImage: "terminal",
            title: loc.t("未找到 Mole CLI", "Mole CLI not found"),
            message: loc.t(
                "安装 Mole 以解锁此功能：\nbrew install mole",
                "Install Mole to unlock this feature:\nbrew install mole"
            ),
            action: (copied
                ? loc.t("已复制 ✓", "Copied ✓")
                : loc.t("复制安装命令", "Copy install command"), {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install mole", forType: .string)
                copied = true
                // Reset the label after 1.5s so the user can copy again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            })
        )
    }
}

/// A monospaced, scrollable log viewer for streamed command output.
///
/// Limits the rendered lines to the most recent `maxLines` to keep
/// performance stable during long-running commands that produce
/// thousands of lines. Older lines are silently dropped.
struct ConsoleOutputView: View {
    let lines: [CLIOutputLine]
    var autoScroll: Bool = true
    /// Maximum number of lines retained for rendering. Excess lines are
    /// dropped from the head to bound memory and diff cost.
    var maxLines: Int = 2000

    /// The slice of lines actually rendered, capped to `maxLines`.
    private var displayedLines: [CLIOutputLine] {
        guard lines.count > maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(displayedLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(line.isError ? Color.red.opacity(0.9) : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("__end__")
                }
                .padding(10)
            }
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: lines.count) { _ in
                if autoScroll {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__end__", anchor: .bottom)
                    }
                }
            }
        }
    }
}
