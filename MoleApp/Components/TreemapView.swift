import SwiftUI

struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    let onDrill: (AnalyzeEntry) -> Void
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?
    @State private var blocks: [Block] = []
    @State private var lastSize: CGSize = .zero

    private let gap: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            recomputBlocks(size: geo.size)

            Canvas { ctx, _ in
                for block in blocks {
                    drawBlock(ctx: ctx, block: block)
                }
            }
            .overlay(
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            withAnimation(.easeInOut(duration: 0.1)) {
                                hoveredPath = hitBlock(point: loc)?.entry.path
                            }
                        case .ended:
                            withAnimation { hoveredPath = nil }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                if let block = hitBlock(point: value.location), block.entry.isDir {
                                    onDrill(block.entry)
                                }
                            }
                    )
            )
            .overlay(alignment: .topLeading) {
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

    private func hitBlock(point: CGPoint) -> Block? {
        for block in blocks {
            let r = block.rect
            if point.x >= r.minX, point.x <= r.maxX,
               point.y >= r.minY, point.y <= r.maxY {
                return block
            }
        }
        return nil
    }

    private func recomputBlocks(size: CGSize) {
        guard size != lastSize else { return }
        lastSize = size
        blocks = layout(entries: entries, in: size)
    }

    private func drawBlock(ctx: GraphicsContext, block: Block) {
        let drawRect = block.rect.insetBy(dx: gap / 2, dy: gap / 2)
        let isHovered = block.entry.path == hoveredPath
        let baseColor = blockColor(for: block.tone)

        let gradient = Gradient(colors: [
            isHovered ? baseColor : baseColor.opacity(0.82),
            isHovered ? baseColor.opacity(0.85) : baseColor.opacity(0.58)
        ])
        ctx.fill(
            Path(roundedRect: drawRect, cornerRadius: cornerRadius),
            with: .linearGradient(gradient,
                startPoint: CGPoint(x: drawRect.minX, y: drawRect.minY),
                endPoint: CGPoint(x: drawRect.maxX, y: drawRect.maxY))
        )
        ctx.stroke(
            Path(roundedRect: drawRect, cornerRadius: cornerRadius),
            with: .color(baseColor.opacity(isHovered ? 0.9 : 0.35)),
            lineWidth: isHovered ? 1.5 : 0.5
        )

        if min(drawRect.width, drawRect.height) >= 32 {
            drawLabel(ctx: ctx, block: block, rect: drawRect)
        }
    }

    private func drawLabel(ctx: GraphicsContext, block: Block, rect: CGRect) {
        let fs = fontSize(for: rect)
        let showMeta = rect.height > 50 && rect.width > 50

        let nameText = Text(block.entry.name)
            .font(.system(size: fs, weight: .semibold))
            .foregroundColor(.white)

        let nameLineH = fs * 1.25
        let metaLineH = max(9, fs - 2) * 1.25
        let totalH = nameLineH + metaLineH + 2
        let textH = showMeta ? totalH : nameLineH
        let startY = rect.midY - textH / 2

        ctx.draw(nameText, at: CGPoint(x: rect.midX, y: startY), anchor: .top)

        if showMeta {
            let metaText = Text("\(ByteFormatter.bytes(block.entry.size))  ·  \(String(format: "%.1f%%", block.fraction))")
                .font(.system(size: max(9, fs - 2), weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
            ctx.draw(metaText, at: CGPoint(x: rect.midX, y: startY + nameLineH + 2), anchor: .top)
        }
    }

    private func fontSize(for rect: CGRect) -> CGFloat {
        switch min(rect.width, rect.height) {
        case 140...: return 14
        case 100..<140: return 13
        case 70..<100: return 12
        case 45..<70: return 11
        default: return 10
        }
    }

    private func blockColor(for tone: StatusTone) -> Color {
        switch tone {
        case .good:     return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .warn:     return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .neutral:  return Color(red: 0.42, green: 0.52, blue: 0.68)
        case .critical: return Color(red: 0.90, green: 0.30, blue: 0.30)
        }
    }

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
            toLayout.append((entry: AnalyzeEntry(
                name: "Other", path: "__other__", size: otherSize, isDir: false,
                insight: nil, cleanable: nil, lastAccess: nil
            ), area: CGFloat(otherSize) * scale))
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
                let rw = rowArea / container.height
                container = CGRect(x: container.minX + rw, y: container.minY,
                                   width: container.width - rw, height: container.height)
            } else {
                let rh = rowArea / container.width
                container = CGRect(x: container.minX, y: container.minY + rh,
                                   width: container.width, height: container.height - rh)
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
        return max(shortSide * shortSide * maxArea / (total * total),
                   total * total / (shortSide * shortSide * minArea))
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
                result.append((item.entry, CGRect(x: container.minX, y: y, width: rowWidth, height: h)))
                y += h
            }
        } else {
            let rowHeight = total / container.width
            var x = container.minX
            for item in row {
                let w = item.area / rowHeight
                result.append((item.entry, CGRect(x: x, y: container.minY, width: w, height: rowHeight)))
                x += w
            }
        }
        return result
    }

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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(blockColor(for: block.tone).opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(width: tipW)
        .position(x: tipX + tipW / 2, y: tipY)
        .allowsHitTesting(false)
    }

    private func toneFor(_ entry: AnalyzeEntry) -> StatusTone {
        if entry.cleanable ?? false { return .good }
        if entry.insight ?? false { return .warn }
        return .neutral
    }
}
