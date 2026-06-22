import SwiftUI

struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    let onDrill: (AnalyzeEntry) -> Void
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?

    var body: some View {
        GeometryReader { geo in
            let blocks = layout(entries: entries, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(blocks, id: \.entry.path) { block in
                    blockView(block)
                }
                if let path = hoveredPath,
                   let block = blocks.first(where: { $0.entry.path == path }) {
                    tooltip(for: block, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func blockView(_ block: Block) -> some View {
        let r = block.rect
        let isHovered = block.entry.path == hoveredPath
        let color = blockColor(for: block.tone)

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [isHovered ? color : color.opacity(0.8),
                             isHovered ? color.opacity(0.8) : color.opacity(0.5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 5)
                .stroke(color.opacity(isHovered ? 0.9 : 0.3), lineWidth: isHovered ? 1.5 : 0.5)
            if r.width > 40 && r.height > 32 {
                label(for: block, in: r)
            }
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredPath = hovering ? block.entry.path : nil
            }
        }
        .onTapGesture { if block.entry.isDir { onDrill(block.entry) } }
        .contextMenu { contextMenu(block.entry) }
    }

    private func label(for block: Block, in r: CGRect) -> some View {
        let fs = r.width > 120 ? 13.0 : r.width > 70 ? 11.0 : 10.0
        let showMeta = r.height > 48 && r.width > 60
        return VStack(spacing: 2) {
            Text(block.entry.name)
                .font(.system(size: fs, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1).truncationMode(.middle)
            if showMeta {
                Text("\(ByteFormatter.bytes(block.entry.size)) · \(String(format: "%.1f%%", block.fraction))")
                    .font(.system(size: fs - 2, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }.padding(.horizontal, 6)
    }

    private func tooltip(for block: Block, in size: CGSize) -> some View {
        let r = block.rect
        let tipW: CGFloat = 200
        let x = min(max(r.midX - tipW / 2, 8), size.width - tipW - 8)
        let y = r.maxY + 6
        return VStack(alignment: .leading, spacing: 3) {
            Text(block.entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text(ByteFormatter.bytes(block.entry.size)).font(.system(size: 11, weight: .bold, design: .rounded))
                Text(String(format: "%.1f%%", block.fraction)).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(blockColor(for: block.tone).opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(width: tipW)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func blockColor(for tone: StatusTone) -> Color {
        switch tone {
        case .good:     return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .warn:     return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .neutral:  return Color(red: 0.42, green: 0.52, blue: 0.68)
        case .critical: return Color(red: 0.90, green: 0.30, blue: 0.30)
        }
    }

    // MARK: - Layout

    struct Block {
        let entry: AnalyzeEntry
        let rect: CGRect
        let tone: StatusTone
        let fraction: Double
    }

    private func layout(entries: [AnalyzeEntry], in size: CGSize) -> [Block] {
        guard !entries.isEmpty, totalSize > 0, size.width > 0, size.height > 0 else { return [] }
        let sorted = entries.sorted { $0.size > $1.size }
        let visible = sorted.count > 10 ? Array(sorted.prefix(10)) : sorted
        let otherSize = sorted.count > 10 ? sorted.dropFirst(10).reduce(Int64(0)) { $0 + $1.size } : Int64(0)

        var items: [(entry: AnalyzeEntry, area: CGFloat)] = []
        let scale = (size.width * size.height) / CGFloat(totalSize)
        for e in visible { items.append((e, CGFloat(e.size) * scale)) }
        if otherSize > 0 {
            items.append((AnalyzeEntry(name: "Other", path: "__other__", size: otherSize, isDir: false,
                                       insight: nil, cleanable: nil, lastAccess: nil),
                          CGFloat(otherSize) * scale))
        }

        var blocks: [Block] = []
        var remaining = items
        var rect = CGRect(origin: .zero, size: size)

        while !remaining.isEmpty {
            let short = min(rect.width, rect.height)
            var row: [(entry: AnalyzeEntry, area: CGFloat)] = []
            var rowArea: CGFloat = 0
            var best = CGFloat.infinity

            for item in remaining {
                let w = worstRatio(row: row + [item], total: rowArea + item.area, short: short)
                if w > best { break }
                row.append(item)
                rowArea += item.area
                best = w
            }

            if rect.width > rect.height {
                let rw = rowArea / rect.height
                var y = rect.minY
                for item in row {
                    let h = item.area / rw
                    let b = Block(entry: item.entry, rect: CGRect(x: rect.minX, y: y, width: rw, height: h),
                                  tone: toneFor(item.entry),
                                  fraction: totalSize > 0 ? Double(item.entry.size) / Double(totalSize) * 100 : 0)
                    blocks.append(b)
                    y += h
                }
                rect = CGRect(x: rect.minX + rw, y: rect.minY, width: rect.width - rw, height: rect.height)
            } else {
                let rh = rowArea / rect.width
                var x = rect.minX
                for item in row {
                    let w = item.area / rh
                    let b = Block(entry: item.entry, rect: CGRect(x: x, y: rect.minY, width: w, height: rh),
                                  tone: toneFor(item.entry),
                                  fraction: totalSize > 0 ? Double(item.entry.size) / Double(totalSize) * 100 : 0)
                    blocks.append(b)
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + rh, width: rect.width, height: rect.height - rh)
            }
            remaining.removeFirst(row.count)
        }
        return blocks
    }

    private func worstRatio(row: [(entry: AnalyzeEntry, area: CGFloat)], total: CGFloat, short: CGFloat) -> CGFloat {
        guard total > 0, short > 0, !row.isEmpty else { return .infinity }
        let areas = row.map(\.area)
        let (mx, mn) = (areas.max() ?? 0, areas.min() ?? 0)
        guard mn > 0 else { return .infinity }
        return max(short * short * mx / (total * total), total * total / (short * short * mn))
    }

    private func toneFor(_ e: AnalyzeEntry) -> StatusTone {
        if e.cleanable ?? false { return .good }
        if e.insight ?? false { return .warn }
        return .neutral
    }
}
