import SwiftUI

/// Squarified treemap layout for disk-usage visualisation.
///
/// Implements the Bruls-Huijsen-van Wijk squarified algorithm (2000),
/// the de-facto standard used by GrandPerspective, DaisyDisk, and
/// SpaceSniffer. The algorithm produces rectangles whose aspect ratios
/// stay close to 1, making relative sizes immediately readable — a
/// 12 GB node_modules block is visually 200× the area of a 60 MB config
/// dir, which a flat list can never convey.
///
/// Colour mapping mirrors the list view's `StatusTone`:
///   - cleanable → green (reclaimable space)
///   - insight   → orange (worth looking at)
///   - neutral   → muted blue/grey
///
/// Interaction:
///   - click a dir block → drill into it (same as list row click)
///   - right-click       → context menu (Finder / preview / copy / trash)
///   - hover             → tooltip with name + size + percentage
///
/// Architecture: Canvas renders the visual layer (fast for many rects),
/// while a ZStack of transparent hit-test rectangles handles hover, click,
/// and context menu. This split keeps large maps (100+ entries) smooth
/// while preserving full SwiftUI gesture support.
struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    /// Called when a dir block is clicked (drill-in). File blocks are
    /// ignored — only dirs are drillable, matching the list view.
    let onDrill: (AnalyzeEntry) -> Void
    /// Builds the context menu for a block. Reuses the list view's row
    /// actions (Finder / preview / copy / trash).
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?

    var body: some View {
        // GeometryReader as root, with an explicit frame from the parent.
        // The parent (treemapSection) sets .frame(maxWidth: .infinity) and
        // .frame(height: 420), so geo.size is the full available width and
        // the fixed height. This matches the pattern used by ProgressBar
        // in Components.swift and is reliable inside ScrollView/VStack.
        GeometryReader { geo in
            let blocks = layout(entries: entries, in: geo.size)
            ZStack(alignment: .topLeading) {
                // Visual layer: Canvas for fast rect rendering.
                Canvas { ctx, _ in
                    for block in blocks {
                        drawBlock(ctx: ctx, block: block)
                    }
                }

                // Interaction layer: one transparent rect per block.
                ForEach(blocks, id: \.entry.path) { block in
                    hitTestRect(for: block)
                }

                // Tooltip overlay (non-hit-testing).
                if let path = hoveredPath,
                   let block = blocks.first(where: { $0.entry.path == path }) {
                    tooltip(for: block, in: geo.size)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Hit-test layer

    private func hitTestRect(for block: Block) -> some View {
        // opacity 0 would make the view skip hit-testing entirely; use a
        // near-zero opacity so the rect stays interactive while remaining
        // visually transparent (the visual layer is drawn by Canvas below).
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: block.rect.width, height: block.rect.height)
            .offset(x: block.rect.minX, y: block.rect.minY)
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredPath = hovering ? block.entry.path : nil
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

    // MARK: - Layout (squarified algorithm)

    struct Block {
        let entry: AnalyzeEntry
        let rect: CGRect
        let tone: StatusTone
        let fraction: Double
    }

    /// Runs the squarified treemap algorithm over `entries` within `size`.
    ///
    /// To keep the map readable, entries beyond `maxVisible` (default 10)
    /// are merged into a single "Other" block. Without this, a 800×340
    /// container with 15 entries compresses the smallest ones to <5px
    /// strips that are invisible and unclickable. DaisyDisk / GrandPerspective
    /// apply the same merging.
    private func layout(entries: [AnalyzeEntry], in size: CGSize) -> [Block] {
        guard !entries.isEmpty, totalSize > 0, size.width > 0, size.height > 0 else { return [] }

        // Merge small entries into "Other" so the map stays readable.
        // Keep at most 10 visible blocks; everything smaller becomes "Other".
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

        // Build the list to lay out, appending "Other" if needed.
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
                if worst > bestWorst {
                    break
                }
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

            // Shrink the container by the row we just laid out. Direction
            // must match layoutRow: if width > height the row was a vertical
            // strip on the left, so shrink from the left; otherwise the row
            // was a horizontal strip on top, so shrink from the top.
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

        // Squarified: the row is laid out along the SHORT side of the
        // container. If width > height, the short side is height, so the
        // row occupies a vertical strip on the left edge and items stack
        // vertically within it. If height >= width, the row occupies a
        // horizontal strip on the top edge and items line up horizontally.
        //
        // The previous version had this inverted, which made wide
        // containers (800×420) lay big items out as full-width horizontal
        // bars instead of vertical strips — producing the "two long bars"
        // effect.
        if container.width > container.height {
            // Short side is height: vertical strip on the left edge.
            let rowWidth = total / container.height
            var y = container.minY
            for item in row {
                let h = item.area / rowWidth
                result.append((item.entry, CGRect(x: container.minX, y: y,
                                                  width: rowWidth, height: h)))
                y += h
            }
        } else {
            // Short side is width: horizontal strip on the top edge.
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

    // MARK: - Drawing

    private func drawBlock(ctx: GraphicsContext, block: Block) {
        let rect = block.rect
        let insetRect = rect.insetBy(dx: 1, dy: 1)
        let isHovered = block.entry.path == hoveredPath
        let baseColor = Theme.color(for: block.tone)

        // Use GraphicsContext.Shading.linearGradient which takes a Gradient
        // plus explicit CGPoint endpoints. LinearGradient itself is not a
        // Shading. Pure colour would also work but the subtle gradient adds
        // depth without obscuring relative sizes.
        let gradient = Gradient(colors: [
            baseColor.opacity(isHovered ? 0.85 : 0.55),
            baseColor.opacity(isHovered ? 0.65 : 0.35)
        ])
        ctx.fill(
            Path(roundedRect: insetRect, cornerRadius: 3),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: insetRect.minX, y: insetRect.minY),
                endPoint: CGPoint(x: insetRect.maxX, y: insetRect.maxY)
            )
        )

        let borderColor = isHovered ? baseColor : baseColor.opacity(0.4)
        ctx.stroke(Path(roundedRect: insetRect, cornerRadius: 3),
                   with: .color(borderColor), lineWidth: isHovered ? 1.5 : 0.5)

        let minDim = min(rect.width, rect.height)
        if minDim >= 36 {
            drawLabel(ctx: ctx, block: block, rect: rect)
        }
    }

    private func drawLabel(ctx: GraphicsContext, block: Block, rect: CGRect) {
        let name = block.entry.name
        let sizeStr = ByteFormatter.bytes(block.entry.size)
        let pctStr = String(format: "%.1f%%", block.fraction)

        let nameFont = Font.system(size: fontSize(for: rect), weight: .semibold)
        let metaFont = Font.system(size: max(9, fontSize(for: rect) - 2), weight: .regular, design: .rounded)

        let nameText = Text(name).font(nameFont).foregroundColor(.primary)
        let metaText = Text("\(sizeStr) · \(pctStr)").font(metaFont).foregroundColor(.secondary)

        let inset = rect.insetBy(dx: 6, dy: 4)
        // Estimate line heights from font size (no reliable Text.measure
        // in Canvas; line height ≈ 1.2 × font size is a safe approximation).
        let nameLineHeight = fontSize(for: rect) * 1.2
        let metaLineHeight = max(9, fontSize(for: rect) - 2) * 1.2

        ctx.draw(nameText, at: CGPoint(x: inset.minX, y: inset.minY))
        // Only draw the meta line if there's room below the name.
        if inset.height > nameLineHeight + metaLineHeight + 4 {
            ctx.draw(metaText, at: CGPoint(x: inset.minX, y: inset.minY + nameLineHeight + 2))
        }
    }

    private func fontSize(for rect: CGRect) -> CGFloat {
        let minDim = min(rect.width, rect.height)
        switch minDim {
        case 120...: return 13
        case 80..<120: return 12
        case 50..<80: return 11
        default: return 10
        }
    }

    // MARK: - Tooltip

    private func tooltip(for block: Block, in size: CGSize) -> some View {
        let rect = block.rect
        let tipX = min(rect.minX + 8, max(0, size.width - 220))
        let tipY = min(rect.minY + 8, max(0, size.height - 60))
        return VStack(alignment: .leading, spacing: 2) {
            Text(block.entry.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(ByteFormatter.bytes(block.entry.size))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(String(format: "%.1f%%", block.fraction))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Theme.color(for: block.tone).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, tipX).padding(.top, tipY)
        .allowsHitTesting(false)
    }

    // MARK: - Tone mapping

    private func toneFor(_ entry: AnalyzeEntry) -> StatusTone {
        if entry.cleanable ?? false { return .good }
        if entry.insight ?? false { return .warn }
        return .neutral
    }
}
