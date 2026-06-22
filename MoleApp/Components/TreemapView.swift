import SwiftUI

struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let totalSize: Int64
    let onDrill: (AnalyzeEntry) -> Void
    let contextMenu: (AnalyzeEntry) -> AnyView

    @State private var hoveredPath: String?
    @State private var blocks: [Block] = []
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let _ = recomput(geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(blocks, id: \.entry.path) { b in
                    blockView(b)
                }
                if let path = hoveredPath,
                   let b = blocks.first(where: { $0.entry.path == path }) {
                    tip(b, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = v.location
                    let newPath = blocks.first(where: {
                        p.x >= $0.rect.minX && p.x <= $0.rect.maxX &&
                        p.y >= $0.rect.minY && p.y <= $0.rect.maxY
                    })?.entry.path
                    if newPath != hoveredPath {
                        withAnimation(.easeOut(duration: 0.08)) { hoveredPath = newPath }
                    }
                }
                .onEnded { v in
                    let p = v.location
                    if let b = blocks.first(where: {
                        p.x >= $0.rect.minX && p.x <= $0.rect.maxX &&
                        p.y >= $0.rect.minY && p.y <= $0.rect.maxY
                    }), b.entry.isDir {
                        onDrill(b.entry)
                    }
                })
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func recomput(_ s: CGSize) {
        guard s != size else { return }
        size = s
        blocks = layout(entries: entries, in: s)
    }

    private func blockView(_ b: Block) -> some View {
        let r = b.rect
        let h = b.entry.path == hoveredPath
        let c = color(b.tone)
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [h ? c : c.opacity(0.75), h ? c.opacity(0.75) : c.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 5)
                .stroke(c.opacity(h ? 0.9 : 0.25), lineWidth: h ? 1.5 : 0.5)
            if r.width > 36 && r.height > 28 { lbl(b, r) }
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
    }

    private func lbl(_ b: Block, _ r: CGRect) -> some View {
        let fs: CGFloat = r.width > 120 ? 13 : r.width > 70 ? 11 : 10
        let show = r.height > 46 && r.width > 55
        return VStack(spacing: 2) {
            Text(b.entry.name).font(.system(size: fs, weight: .semibold)).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
            if show {
                Text("\(ByteFormatter.bytes(b.entry.size)) · \(String(format: "%.1f%%", b.fraction))")
                    .font(.system(size: fs - 2, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8)).lineLimit(1)
            }
        }.padding(.horizontal, 6)
    }

    private func tip(_ b: Block, in s: CGSize) -> some View {
        let r = b.rect, w: CGFloat = 200
        let x = min(max(r.midX - w / 2, 8), s.width - w - 8)
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

    private func layout(entries: [AnalyzeEntry], in sz: CGSize) -> [Block] {
        guard !entries.isEmpty, totalSize > 0, sz.width > 0, sz.height > 0 else { return [] }
        let sorted = entries.sorted { $0.size > $1.size }
        let vis = sorted.count > 10 ? Array(sorted.prefix(10)) : sorted
        let other = sorted.count > 10 ? sorted.dropFirst(10).reduce(Int64(0)) { $0 + $1.size } : Int64(0)
        var items: [(AnalyzeEntry, CGFloat)] = []
        let sc = (sz.width * sz.height) / CGFloat(totalSize)
        for e in vis { items.append((e, CGFloat(e.size) * sc)) }
        if other > 0 { items.append((AnalyzeEntry(name: "Other", path: "__other__", size: other, isDir: false, insight: nil, cleanable: nil, lastAccess: nil), CGFloat(other) * sc)) }

        var blocks: [Block] = [], rem = items, c = CGRect(origin: .zero, size: sz)
        while !rem.isEmpty {
            let sh = min(c.width, c.height)
            var row: [(AnalyzeEntry, CGFloat)] = [], ra: CGFloat = 0, best = CGFloat.infinity
            for it in rem {
                let w = wrt(row: row + [it], t: ra + it.1, s: sh)
                if w > best { break }; row.append(it); ra += it.1; best = w
            }
            if c.width > c.height {
                let rw = ra / c.height; var y = c.minY
                for (e, a) in row { let h = a / rw; blocks.append(Block(entry: e, rect: .init(x: c.minX, y: y, width: rw, height: h), tone: tn(e), fraction: totalSize > 0 ? Double(e.size) / Double(totalSize) * 100 : 0)); y += h }
                c = .init(x: c.minX + rw, y: c.minY, width: c.width - rw, height: c.height)
            } else {
                let rh = ra / c.width; var x = c.minX
                for (e, a) in row { let w = a / rh; blocks.append(Block(entry: e, rect: .init(x: x, y: c.minY, width: w, height: rh), tone: tn(e), fraction: totalSize > 0 ? Double(e.size) / Double(totalSize) * 100 : 0)); x += w }
                c = .init(x: c.minX, y: c.minY + rh, width: c.width, height: c.height - rh)
            }
            rem.removeFirst(row.count)
        }
        return blocks
    }

    private func wrt(row: [(AnalyzeEntry, CGFloat)], t: CGFloat, s: CGFloat) -> CGFloat {
        guard t > 0, s > 0, !row.isEmpty else { return .infinity }
        let a = row.map(\.1), mx = a.max() ?? 0, mn = a.min() ?? 0
        guard mn > 0 else { return .infinity }
        return max(s * s * mx / (t * t), t * t / (s * s * mn))
    }

    private func tn(_ e: AnalyzeEntry) -> StatusTone {
        if e.cleanable ?? false { return .good }; if e.insight ?? false { return .warn }; return .neutral
    }
}
