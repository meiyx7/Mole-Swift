import Foundation

/// 解析 Mole CLI 交互式选择 TUI 的重绘帧。
///
/// Mole 的 `mo purge` / `mo installer` 是一个全屏选择 TUI：每次按键都
/// 重绘整个列表，每帧以 "N selected" 头开始。本类型把原始 PTY 输出
/// （含 ANSI 转义）解析成结构化的条目列表，供原生 UI 渲染。
///
/// 参照 Burrow 的 MoTUI 实现，适配 MoleApp 的 ANSIStripper。
struct MoTUIItem: Equatable {
    let name: String
    let size: String        // Mole 打印的原始大小，如 "1.26GB"
    let location: String    // 如 "Desktop"
    let selected: Bool      // ● vs ○
}

struct MoTUIScreen: Equatable {
    let items: [MoTUIItem]
    let cursor: Int          // 带 ➤ 标记的行索引
    let selectedCount: Int?  // 从 "N selected" 头解析
}

enum MoTUI {
    // Mole TUI 使用的字形标记
    private static let unchecked: Character = "\u{25CB}"  // ○
    private static let checked: Character = "\u{25CF}"    // ●
    private static let cursorMark: Character = "\u{27A4}" // ➤

    /// 解析 Mole 选择 TUI 的最后一帧重绘。TUI 每次按键都重绘整个列表，
    /// 每帧以 "N selected" 头开始，遇到头就重置，最终留下最近一帧。
    static func parse(_ raw: String) -> MoTUIScreen {
        let text = ANSIStripper.strip(raw)
        var items: [MoTUIItem] = []
        var cursor = 0
        var selectedCount: Int?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if let n = selectedCountIn(line) {       // 头 → 新帧
                selectedCount = n
                items = []
                cursor = 0
                continue
            }
            guard let (item, isCursor) = parseItem(line) else { continue }
            if isCursor { cursor = items.count }
            items.append(item)
        }
        return MoTUIScreen(items: items, cursor: cursor, selectedCount: selectedCount)
    }

    /// 屏幕上当前被勾选（●）的行索引集合。
    static func selectedIndices(_ screen: MoTUIScreen) -> Set<Int> {
        Set(screen.items.enumerated().filter { $0.element.selected }.map { $0.offset })
    }

    /// 从一个全新列表（光标在第 0 项，全部 ○）到恰好 `wanted` 被勾选所需
    /// 的按键序列。从顶到底走一遍，遇到 wanted 就按 Space，行间按 ↓。
    /// 确定性、无需光标计算。`confirm` 追加 Enter，空选择不确认。
    static func keystrokesToSelect(_ wanted: Set<Int>, count: Int, confirm: Bool) -> [UInt8] {
        let down: [UInt8] = [0x1b, 0x5b, 0x42]   // ESC [ B
        let space: UInt8 = 0x20
        let enter: UInt8 = 0x0d
        var out: [UInt8] = []
        guard count > 0 else { return out }
        for i in 0..<count {
            if wanted.contains(i) { out.append(space) }
            if i < count - 1 { out.append(contentsOf: down) }
        }
        if confirm && !wanted.isEmpty { out.append(enter) }
        return out
    }

    static let quit: [UInt8] = [0x71]              // 'q'
    static let down: [UInt8] = [0x1b, 0x5b, 0x42]  // ESC [ B
    static let up: [UInt8] = [0x1b, 0x5b, 0x41]    // ESC [ A

    /// 把新解析的视口合并到已累积的有序列表，只追加未见过的行（身份 =
    /// name+size+location）。Mole 选择 TUI 渲染固定高度的滚动窗口
    /// （约 50 行上限），长列表需要滚动并拼接重叠帧。
    static func mergeItems(_ acc: [MoTUIItem], _ viewport: [MoTUIItem]) -> [MoTUIItem] {
        var out = acc
        var seen = Set(acc.map(identity))
        for item in viewport where seen.insert(identity(item)).inserted {
            out.append(item)
        }
        return out
    }

    private static func identity(_ i: MoTUIItem) -> String {
        "\(i.name)\u{1}\(i.size)\u{1}\(i.location)"
    }

    /// 从 "[current/total]" 头解析总条目数。Mole 限制单帧渲染行数（约 50），
    /// 长列表时头的 total 会超过可解析行数，UI 据此显示 "共 N 项"。
    static func totalCount(_ raw: String) -> Int? {
        let text = ANSIStripper.strip(raw)
        guard let r = text.range(of: #"\[\d+/(\d+)\]"#, options: .regularExpression) else { return nil }
        let inside = text[r].dropFirst().dropLast()      // "1/53"
        return Int(inside.split(separator: "/").last.map(String.init) ?? "")
    }

    /// 从 Mole 最终确认屏解析删除数量。Mole 措辞因工具和版本而异：
    /// `purge` 说 "Remove 3 artifacts"，`installer` 说 "Delete 1 installers"。
    /// 接受 Mole 使用的所有动词，取紧随其后的整数。
    static func removalCount(_ raw: String) -> Int? {
        let text = ANSIStripper.strip(raw)
        guard let r = text.range(of: #"(?:Remove|Delete|Clean|Trash|Free)\s+(\d+)"#,
                                 options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }

    // MARK: - 解析辅助

    private static func selectedCountIn(_ line: String) -> Int? {
        guard let r = line.range(of: #"(\d+)\s+selected"#, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: " ").first ?? "")
    }

    /// 解析一行条目 → (item, 是否光标行)。非条目行返回 nil。
    private static func parseItem(_ line: String) -> (MoTUIItem, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerIdx = trimmed.firstIndex(where: { $0 == checked || $0 == unchecked }) else { return nil }
        let isCursor = trimmed.first == cursorMark
        let selected = trimmed[markerIdx] == checked
        let rest = trimmed[trimmed.index(after: markerIdx)...].trimmingCharacters(in: .whitespaces)
        // rest: "Inkling-0.0.1.dmg                 771KB | Desktop"
        let pipeParts = rest.components(separatedBy: "|")
        let location = pipeParts.count > 1 ? pipeParts[1].trimmingCharacters(in: .whitespaces) : ""
        let left = pipeParts[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard left.count >= 2 else { return nil }
        let size = left.last!
        let name = left.dropLast().joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (MoTUIItem(name: name, size: size, location: location, selected: selected), isCursor)
    }
}
