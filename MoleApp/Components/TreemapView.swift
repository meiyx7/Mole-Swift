import SwiftUI

struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    let onDrill: (AnalyzeEntry) -> Void
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?
    @State private var blocks: [Block] = []
    @State private var containerSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            recomput(geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for b in blocks { draw(ctx: ctx, b: b) }
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in updateHover(at: v.location) }
                        .onEnded { v in
                            if let b = hit(v.location), b.entry.isDir { onDrill(b.entry) }
                        })
                if let path = hoveredPath,
                   let b = blocks.first(where: { $0.entry.path == path }) {
                    tip(b, size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func updateHover(at p: CGPoint) {
        let newPath = hit(p)?.entry.path
        if newPath != hoveredPath {
            withAnimation(.easeOut(duration: 0.08)) { hoveredPath = newPath }
        }
    }

    private func hit(_ p: CGPoint) -> Block? {
        blocks.first { p.x >= $0.rect.minX && p.x <= $0.rect.maxX && p.y >= $0.rect.minY && p.y <= $0.rect.maxY }
    }

    private func recomput(_ size: CGSize) {
        guard size != containerSize else { return }
        containerSize = size
        blocks = layout(entries: entries, in: size)
    }

    // MARK: - Canvas drawing

    private func draw(ctx: GraphicsContext, b: Block) {
        let r = b.rect
        let h = b.entry.path == hoveredPath
        let c = color(b.tone)
        let g = Gradient(colors: [h ? c : c.opacity(0.75), h ? c.opacity(0.75) : c.opacity(0.45)])
        ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .linearGradient(g, startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(c.opacity(h ? 0.9 : 0.25)), lineWidth: h ? 1.5 : 0.5)
        guard r.width > 36 && r.height > 28 else { return }
        let fs: CGFloat = r.width > 120 ? 13 : r.width > 70 ? 11 : 10
        let name = Text(b.entry.name).font(.system(size: fs, weight: .semibold)).foregroundColor(.white)
        let showMeta = r.height > 46 && r.width > 55
        let meta = showMeta ? Text("\(ByteFormatter.bytes(b.entry.size)) · \(String(format: "%.1f%%", b.fraction))").font(.system(size: fs - 2, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.8)) : nil
        let nameH = fs * 1.25
        let metaH = showMeta ? (fs - 2) * 1.25 : 0 as CGFloat
        let totalH = nameH + (showMeta ? 2 + metaH : 0)
        let y0 = r.midY - totalH / 2
        ctx.draw(name, at: CGPoint(x: r.midX, y: y0), anchor: .top)
        if let m = meta { ctx.draw(m, at: CGPoint(x: r.midX, y: y0 + nameH + 2), anchor: .top) }
    }

    private func tip(_ b: Block, size: CGSize) -> some View {
        let r = b.rect, w: CGFloat = 200
        let x = min(max(r.midX - w / 2, 8), size.width - w - 8)
        return VStack(alignment: .leading, spacing: 3) {
            Text(b.entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text(ByteFormatter.bytes(b.entry.size)).font(.system(size: 11, weight: .bold, design: .rounded))
                Text(String(format: "%.1f%%", b.fraction)).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color(b.tone).opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(width: w)
        .position(x: x + w / 2, y: r.maxY + 30)
        .allowsHitTesting(false)
    }

    private func color(_ t: StatusTone) -> Color {
        switch t {
        case .good:     return Color(red: 0.22, green: 0.72, blue: 0.45)
        case .warn:     return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .neutral:  return Color(red: 0.42, green: 0.52, blue: 0.68)
        case .critical: return Color(red: 0.90, green: 0.30, blue: 0.30)
        }
    }

    // MARK: - Layout

    struct Block { let entry: AnalyzeEntry; let rect: CGRect; let tone: StatusTone; let fraction: Double }

    private func layout(entries: [AnalyzeEntry], in size: CGSize) -> [Block] {
        guard !entries.isEmpty, totalSize > 0, size.width > 0, size.height > 0 else { return [] }
        let sorted = entries.sorted { $0.size > $1.size }
        let vis = sorted.count > 10 ? Array(sorted.prefix(10)) : sorted
        let other = sorted.count > 10 ? sorted.dropFirst(10).reduce(Int64(0)) { $0 + $1.size } : Int64(0)
        var items: [(AnalyzeEntry, CGFloat)] = []
        let s = (size.width * size.height) / CGFloat(totalSize)
        for e in vis { items.append((e, CGFloat(e.size) * s)) }
        if other > 0 { items.append((AnalyzeEntry(name: "Other", path: "__other__", size: other, isDir: false, insight: nil, cleanable: nil, lastAccess: nil), CGFloat(other) * s)) }

        var blocks: [Block] = [], rem = items, c = CGRect(origin: .zero, size: size)
        while !rem.isEmpty {
            let sh = min(c.width, c.height)
            var row: [(AnalyzeEntry, CGFloat)] = [], ra: CGFloat = 0, best = CGFloat.infinity
            for it in rem {
                let w = worst(row: row + [it], t: ra + it.1, s: sh)
                if w > best { break }; row.append(it); ra += it.1; best = w
            }
            if c.width > c.height {
                let rw = ra / c.height; var y = c.minY
                for (e, a) in row { let h = a / rw; blocks.append(Block(entry: e, rect: .init(x: c.minX, y: y, width: rw, height: h), tone: tone(e), fraction: totalSize > 0 ? Double(e.size) / Double(totalSize) * 100 : 0)); y += h }
                c = .init(x: c.minX + rw, y: c.minY, width: c.width - rw, height: c.height)
            } else {
                let rh = ra / c.width; var x = c.minX
                for (e, a) in row { let w = a / rh; blocks.append(Block(entry: e, rect: .init(x: x, y: c.minY, width: w, height: rh), tone: tone(e), fraction: totalSize > 0 ? Double(e.size) / Double(totalSize) * 100 : 0)); x += w }
                c = .init(x: c.minX, y: c.minY + rh, width: c.width, height: c.height - rh)
            }
            rem.removeFirst(row.count)
        }
        return blocks
    }

    private func worst(row: [(AnalyzeEntry, CGFloat)], t: CGFloat, s: CGFloat) -> CGFloat {
        guard t > 0, s > 0, !row.isEmpty else { return .infinity }
        let a = row.map(\.1), mx = a.max() ?? 0, mn = a.min() ?? 0
        guard mn > 0 else { return .infinity }
        return max(s * s * mx / (t * t), t * t / (s * s * mn))
    }

    private func tone(_ e: AnalyzeEntry) -> StatusTone {
        if e.cleanable ?? false { return .good }; if e.insight ?? false { return .warn }; return .neutral
    }
}
