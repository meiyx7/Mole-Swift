import SwiftUI

/// Squarified treemap layout for disk-usage visualisation.
///
/// Implements the Bruls-Huijsen-van Wijk squarified algorithm (2000),
/// used by GrandPerspective, DaisyDisk, and SpaceSniffer. Rectangles
/// with aspect ratios close to 1 make relative sizes immediately
/// readable — a 12 GB block is visually 200× the area of a 60 MB one.
///
/// Architecture: pure SwiftUI views (no Canvas). Each block is a
/// standalone view with background, text, and gesture handling. This
/// avoids coordinate-system mismatches between Canvas and SwiftUI.
struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    let onDrill: (AnalyzeEntry) -> Void
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?

    private let gap: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let blocks = layout(entries: entries, in: geo.size)
            ZStack {
                ForEach(blocks, id: \.entry.path) { block in
                    blockView(block)
                }

                if let path = hoveredPath,
                   let block = blocks.first(where: { $0.entry.path == path }) {
                    tooltip(for: block, in: geo.size)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Block view

    private func blockView(_ block: Block) -> some View {
        let rect = block.rect
        let drawRect = rect.insetBy(dx: gap / 2, dy: gap / 2)
        let isHovered = block.entry.path == hoveredPath
        let baseColor = blockColor(for: block.tone)

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            isHovered ? baseColor : baseColor.opacity(0.82),
                            isHovered ? baseColor.opacity(0.85) : baseColor.opacity(0.58)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(baseColor.opacity(isHovered ? 0.9 : 0.35),
                        lineWidth: isHovered ? 1.5 : 0.5)

            if drawRect.width >= 32 && drawRect.height >= 32 {
                blockLabel(block: block, rect: drawRect)
            }
        }
        .frame(width: drawRect.width, height: drawRect.height)
        .offset(x: drawRect.minX, y: drawRect.minY)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredPath = hovering ? block.entry.path : nil
            }
        }
        .onTapGesture {
            if block.entry.isDir {
                onDrill(block.entry)
            }
        }
        .contextMenu {
            contextMenu(block.entry)
        }
    }

    private func blockLabel(block: Block, rect: CGRect) -> some View {
        let fs = fontSize(for: rect)
        let showMeta = rect.height > 50 && rect.width > 50

        return VStack(spacing: 2) {
            Text(block.entry.name)
                .font(.system(size: fs, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            if showMeta {
                Text("\(ByteFormatter.bytes(block.entry.size))  ·  \(String(format: "%.1f%%", block.fraction))")
                    .font(.system(size: max(9, fs - 2), weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
    }

    private func fontSize(for rect: CGRect) -> CGFloat {
        let minDim = min(rect.width, rect.height)
        switch minDim {
        case 140...: return 14
        case 100..<140: return 13
        case 70..<100: return 12
        case 45..<70: return 11
        default: return 10
        }
    }

    private func blockColor(for tone: StatusTone) -> Color {
        switch tone {
        case .good:
            return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .warn:
            return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .neutral:
            return Color(red: 0.42, green: 0.52, blue: 0.68)
        case .critical:
            return Color(red: 0.90, green: 0.30, blue: 0.30)
        }
    }

    // MARK: - Layout (squarified algorithm)

    struct Block {
        let entry: AnalyzeEntry
        let rect: CGRect
        let tone: StatusTone
        let fraction: Double
    }

    private func layout(entries: [AnalyzeEntry], in size: CGSize) -> [Block] {
        guard !entries.isEmpty, totalSize > 0, size.width > 0, size.height > 0 else { return [] }

        let maxVisible = 10
        let sorted = entries.sorted { $0.size > $1.size }
        let visible: [AnalyzeEntry]
        let otherSize: Int64

        if sorted.count > maxVisible {
            visible = Array(sorted.prefix(maxVisible))
            otherSize = sorted.dropFirst(maxVisible).reduce(Int64(0)) { $0 + $1.size }
        } else {
            visible = sorted
            otherSize = 0
        }

        var toLayout: [(entry: AnalyzeEntry, area: CGFloat)] = []
        let area = size.width * size.height
        let scale = area / CGFloat(totalSize)
        for e in visible {
            toLayout.append((entry: e, area: CGFloat(e.size) * scale))
        }
        if otherSize > 0 {
            let otherEntry = AnalyzeEntry(
                name: "Other", path: "__other__", size: otherSize, isDir: false,
                insight: nil, cleanable: nil, lastAccess: nil
            )
            toLayout.append((entry: otherEntry, area: CGFloat(otherSize) * scale))
        }

        var blocks: [Block] = []
        var remaining = toLayout
        var container = CGRect(origin: .zero, size: size)

        while !remaining.isEmpty {
            let shortSide = min(container.width, container.height)
            var row: [(entry: AnalyzeEntry, area: CGFloat)] = []
            var rowArea: CGFloat = 0
            var bestWorst = CGFloat.infinity

            for item in remaining {
                let candidate = row + [item]
                let candidateArea = rowArea + item.area
                let worst = worstAspectRatio(row: candidate, total: candidateArea, shortSide: shortSide)
                if worst > bestWorst { break }
                row = candidate
                rowArea = candidateArea
                bestWorst = worst
            }

            let laidOut = layoutRow(row: row, total: rowArea, in: container)
            for (entry, rect) in laidOut {
                let tone = toneFor(entry)
                let fraction = totalSize > 0 ? Double(entry.size) / Double(totalSize) * 100 : 0
                blocks.append(Block(entry: entry, rect: rect, tone: tone, fraction: fraction))
            }

            if container.width > container.height {
                let rowWidth = rowArea / container.height
                container = CGRect(
                    x: container.minX + rowWidth, y: container.minY,
                    width: container.width - rowWidth, height: container.height
                )
            } else {
                let rowHeight = rowArea / container.width
                container = CGRect(
                    x: container.minX, y: container.minY + rowHeight,
                    width: container.width, height: container.height - rowHeight
                )
            }
            remaining.removeFirst(row.count)
        }
        return blocks
    }

    private func worstAspectRatio(row: [(entry: AnalyzeEntry, area: CGFloat)],
                                  total: CGFloat, shortSide: CGFloat) -> CGFloat {
        guard total > 0, shortSide > 0, !row.isEmpty else { return .infinity }
        let areas = row.map { $0.area }
        let maxArea = areas.max() ?? 0
        let minArea = areas.min() ?? 0
        guard minArea > 0 else { return .infinity }
        let s2 = shortSide * shortSide
        let t2 = total * total
        return max(s2 * maxArea / t2, t2 / (s2 * minArea))
    }

    private func layoutRow(row: [(entry: AnalyzeEntry, area: CGFloat)],
                           total: CGFloat, in container: CGRect) -> [(entry: AnalyzeEntry, rect: CGRect)] {
        guard total > 0 else { return [] }
        var result: [(entry: AnalyzeEntry, rect: CGRect)] = []

        if container.width > container.height {
            let rowWidth = total / container.height
            var y = container.minY
            for item in row {
                let h = item.area / rowWidth
                result.append((item.entry, CGRect(x: container.minX, y: y,
                                                  width: rowWidth, height: h)))
                y += h
            }
        } else {
            let rowHeight = total / container.width
            var x = container.minX
            for item in row {
                let w = item.area / rowHeight
                result.append((item.entry, CGRect(x: x, y: container.minY,
                                                  width: w, height: rowHeight)))
                x += w
            }
        }
        return result
    }

    // MARK: - Tooltip

    private func tooltip(for block: Block, in size: CGSize) -> some View {
        let rect = block.rect
        let tipW: CGFloat = 200
        let tipX = min(rect.midX - tipW / 2, max(0, size.width - tipW - 8))
        let tipY = rect.maxY + 6
        return VStack(alignment: .leading, spacing: 3) {
            Text(block.entry.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(ByteFormatter.bytes(block.entry.size))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text(String(format: "%.1f%%", block.fraction))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(blockColor(for: block.tone).opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(width: tipW)
        .position(x: tipX + tipW / 2, y: tipY)
        .allowsHitTesting(false)
    }

    // MARK: - Tone mapping

    private func toneFor(_ entry: AnalyzeEntry) -> StatusTone {
        if entry.cleanable ?? false { return .good }
        if entry.insight ?? false { return .warn }
        return .neutral
    }
}
